import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'video_card.dart';

/// 重复视频（影片查重）。
///
/// 服务端判据是**四把钥匙的并查集**（豆瓣 id / IMDB id / 番号 / 归一化标题+年份），
/// 页面展示口径：
///   * 每组用缩略图（刮削的横版剧照，3:2）平铺，图下就是文件名 / 分辨率 / 体积；
///   * 缩略图左上角是勾选框，右上角是「中 / 字 / 无码 / 4K」角标；
///   * **默认一条都不勾**，点「自动勾选」才按日本片的保留规则批量预勾；
///   * 依然不自动删除任何文件：查重是启发式的，误判代价是丢片子。
class VideoDuplicatesPage extends StatefulWidget {
  const VideoDuplicatesPage({super.key});

  @override
  State<VideoDuplicatesPage> createState() => _VideoDuplicatesPageState();
}

class _VideoDuplicatesPageState extends State<VideoDuplicatesPage> {
  bool _loading = true;
  String? _error;
  List<VideoLibraryItem> _libraries = const [];
  String? _libraryId;
  VideoDuplicatesResponse? _data;

  /// 已勾选待删除的条目。默认空：查重是启发式的，自动勾错一条就是丢一部片。
  final Set<String> _selected = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final res = await ApiSession.instance.client.videoLibraryList();
      if (!mounted) return;
      setState(() => _libraries = res.items);
    } catch (_) {
      // 库列表失败不影响「全部库」查询
    }
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoDuplicates(
        libraryId: _libraryId,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _data = res;
        // 每次重新扫描都回到「默认不勾」的状态
        _selected.clear();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 删除勾选的条目：服务端把文件移进回收站，并清掉索引 / 观看进度 / 收藏。
  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty || _busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Text(tr('video.dup.deleteConfirm', {'count': '${ids.length}'})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.videoItemsDelete(
        body: VideoDeleteItemsBody(ids: ids),
      );
      if (!mounted) return;
      final failedCount = res.failed.length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failedCount == 0
                ? tr('video.dup.deleteDone', {'count': '${res.done.length}'})
                : tr('video.dup.deletePartial', {
                    'done': '${res.done.length}',
                    'failed': '$failedCount',
                  }),
          ),
        ),
      );
      _selected.clear();
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 日本片默认勾选规则（2026-10-26 口径）：
  ///   ① 破解版里留「分辨率最高、同分辨率体积最大」的一个；
  ///   ② 非破解版里也留一个，但只有分辨率**严格高于**①时才留；
  ///   ③ 一条破解版都没有时，留非破解版里分辨率最高的一个。
  /// 非日本片组不预勾，避免把普通电影误删。
  Set<String> _computeDefaultSelection(VideoDuplicatesResponse res) {
    final out = <String>{};

    VideoDuplicateItem best(List<VideoDuplicateItem> list) {
      var pick = list.first;
      for (final it in list) {
        final h = it.height ?? 0;
        final ph = pick.height ?? 0;
        if (h != ph) {
          if (h > ph) pick = it;
          continue;
        }
        final w = it.width ?? 0;
        final pw = pick.width ?? 0;
        if (w != pw) {
          if (w > pw) pick = it;
          continue;
        }
        if (it.size > pick.size) pick = it;
      }
      return pick;
    }

    for (final g in res.groups) {
      final items = g.items.where((e) => e.id.isNotEmpty).toList();
      if (items.length < 2) continue;
      final jp = items.where((e) => e.isJp).toList();
      if (jp.isEmpty) continue;

      bool crackedOf(VideoDuplicateItem it) => it.uncensored || it.ltx;
      final cracked = jp.where(crackedOf).toList();
      final plain = jp.where((e) => !crackedOf(e)).toList();
      final keep = <String>{};

      if (cracked.isNotEmpty) {
        final bc = best(cracked);
        keep.add(bc.id);
        if (plain.isNotEmpty) {
          final bp = best(plain);
          if ((bp.height ?? 0) > (bc.height ?? 0) ||
              ((bp.height ?? 0) == (bc.height ?? 0) &&
                  (bp.width ?? 0) > (bc.width ?? 0))) {
            keep.add(bp.id);
          }
        }
      } else if (plain.isNotEmpty) {
        keep.add(best(plain).id);
      }

      for (final it in items) {
        if (!keep.contains(it.id)) out.add(it.id);
      }
    }
    return out;
  }

  void _autoSelect() {
    final data = _data;
    if (data == null) return;
    final next = _computeDefaultSelection(data);
    setState(() {
      _selected
        ..clear()
        ..addAll(next);
    });
    if (next.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('video.dup.autoSelectEmpty'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('video.duplicate.title')),
        actions: [
          if (_libraries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: NasTokens.spaceSm),
              child: DropdownButton<String?>(
                value: _libraryId,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(tr('video.duplicate.allLibraries')),
                  ),
                  for (final lib in _libraries)
                    DropdownMenuItem<String?>(value: lib.id, child: Text(lib.name)),
                ],
                onChanged: (v) {
                  setState(() => _libraryId = v);
                  _load();
                },
              ),
            ),
          IconButton(
            tooltip: tr('common.refresh'),
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          if (_selected.isNotEmpty) ...[
            TextButton(
              onPressed: _busy ? null : () => setState(_selected.clear),
              child: Text(tr('video.dup.clearSelection')),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _deleteSelected,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(
                tr('video.dup.deleteSelected', {'count': '${_selected.length}'}),
              ),
            ),
            const SizedBox(width: NasTokens.spaceSm),
          ],
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
              ? NasErrorState(message: _error!, onRetry: _load)
              : _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final data = _data;
    if (data == null || data.groups.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.duplicate.empty'),
            message: tr('video.duplicate.hint2'),
            icon: Icons.content_copy_outlined,
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceMd,
        96,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('video.duplicate.hint2'),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('video.dup.total', {
                      'groups': '${data.totalGroups}',
                      'scanned': '${data.scanned}',
                      'ms': '${data.tookMs}',
                    }),
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: NasTokens.spaceSm),
            OutlinedButton.icon(
              onPressed: _busy ? null : _autoSelect,
              icon: const Icon(Icons.checklist_rtl, size: 18),
              label: Text(tr('video.dup.autoSelect')),
            ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceMd),
        for (var i = 0; i < data.groups.length; i += 1) ...[
          _groupHeader(context, data.groups[i], i + 1),
          const SizedBox(height: NasTokens.spaceXs),
          _groupGrid(context, data.groups[i]),
          const SizedBox(height: NasTokens.spaceMd),
        ],
      ],
    );
  }

  Widget _groupHeader(
    BuildContext context,
    VideoDuplicateGroup group,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final totalBytes = group.items.fold<int>(0, (s, it) => s + it.size);
    return Row(
      children: [
        Text(
          '#$index · ${tr('video.duplicate.groupCount', {'count': '${group.count}'})}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: NasTokens.spaceSm),
        for (final k in group.keys)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(k, style: const TextStyle(fontSize: 9)),
            ),
          ),
        const Spacer(),
        if (totalBytes > 0)
          Text(
            formatBytes(totalBytes),
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
      ],
    );
  }

  Widget _groupGrid(BuildContext context, VideoDuplicateGroup group) {
    return LayoutBuilder(
      builder: (context, cons) {
        const spacing = 12.0;
        final compact = cons.maxWidth < 600;
        final base = compact ? 120.0 : 176.0;
        final target = base * 1.5;
        final cols = ((cons.maxWidth - spacing * 2) / (target + spacing))
            .floor()
            .clamp(1, 12);
        final cellW = (cons.maxWidth - spacing * (cols + 1)) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final item in group.items)
              SizedBox(
                width: cellW,
                child: _dupCard(context, item, cellW),
              ),
          ],
        );
      },
    );
  }

  Widget _dupCard(BuildContext context, VideoDuplicateItem item, double width) {
    final scheme = Theme.of(context).colorScheme;
    final picked = _selected.contains(item.id);
    final url = _artUrl(item);
    final resolution = (item.width != null && item.height != null)
        ? '${item.width}×${item.height}'
        : tr('ui.book.hd9c32a');
    final meta = [
      formatBytes(item.size),
      resolution,
      if ((item.code ?? '').isNotEmpty) item.code!,
    ].join(' · ');

    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        final navigator = Navigator.of(context);
        try {
          final detail = await ApiSession.instance.client.videoItem(id: item.id);
          if (!mounted) return;
          unawaited(openVideoDetailOn(navigator, detail));
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('$e')));
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 缩略图按刮削剧照的原始比例 3:2（对齐日本电影库的横版网格）
          AspectRatio(
            aspectRatio: 3 / 2,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NasCoverImage(
                    url: url,
                    fit: BoxFit.contain,
                    headers: videoArtHeaders,
                    fallbackText: item.title,
                    icon: Icons.movie_outlined,
                    cacheWidth: (width * 2).round(),
                  ),
                  // 左上角勾选：默认不勾，点「自动勾选」才按规则批量勾上
                  Positioned(
                    left: 4,
                    top: 4,
                    child: Material(
                      color: scheme.surface.withValues(alpha: 0.86),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => setState(() {
                          if (!_selected.remove(item.id)) _selected.add(item.id);
                        }),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            picked
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 22,
                            color: picked
                                ? scheme.primary
                                : scheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 右上角：中 / 字 / 无码 / 4K
                  if (item.chineseSub ||
                      item.uncensored ||
                      item.is4k ||
                      item.ltx)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: VideoCornerBadges(
                        chineseSub: item.chineseSub,
                        uncensored: item.uncensored,
                        is4k: item.is4k,
                        ltx: item.ltx,
                        scale: 0.9,
                      ),
                    ),
                  if (picked)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(NasTokens.radiusSm),
                            border: Border.all(color: scheme.primary, width: 2.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: NasTokens.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  String? _artUrl(VideoDuplicateItem item) {
    final base = ApiSession.instance.baseUrl;
    final id = Uri.encodeComponent(item.id);
    // 「缩略图」是刮削出来的横版剧照（fanart），和日本电影库网格同一个口径；
    // 服务端按 fanart → poster → thumb 回退，绝不会退成视频抽帧截图。
    if (item.hasArt) return '$base/api/v1/video/art?id=$id&kind=fanart';
    // 完全没刮削过才用首帧兜底，至少还有张图能辨认
    return '$base/api/v1/video/poster?id=$id';
  }
}
