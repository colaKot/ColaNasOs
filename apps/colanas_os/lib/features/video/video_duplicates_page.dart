import 'dart:async';
import 'dart:convert';

import '../../shell/app_widgets.dart';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/client_log.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
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

  /// 演员排除（名字键 → 原始写法）。
  /// 列表层由服务端整组过滤；这里再拦一次，保证「自动勾选」永远不会勾到她们。
  final Map<String, String> _excludedActors = <String, String>{};

  /// 排除名单落盘键：这份名单是长期偏好（「这几位的片我不删」），重进页面不该丢
  static const _keyExcluded = 'video.dup.excludedActors';

  void _restoreExcluded() {
    final raw = SettingsStore.instance.getString(_keyExcluded);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final e in decoded.entries) {
          final key = '${e.key}'.trim();
          final name = '${e.value}'.trim();
          if (key.isNotEmpty && name.isNotEmpty) _excludedActors[key] = name;
        }
      }
    } catch (_) {
      // 存坏了就当没配过，不挡页面
    }
  }

  void _persistExcluded() {
    unawaited(
      SettingsStore.instance.setString(_keyExcluded, jsonEncode(_excludedActors)),
    );
  }

  /// 这条片子是否含被排除的演员（键由服务端 `actorKey` 归一，跨写法也算同一人）
  bool _actorExcluded(VideoDuplicateItem item) {
    if (_excludedActors.isEmpty) return false;
    for (final key in item.actorKeys) {
      if (_excludedActors.containsKey(key)) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    // 先恢复排除名单：首次查询就要把它带给服务端，否则会先闪一堆已屏蔽的片
    _restoreExcluded();
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
        // 排除的演员交给服务端过滤：命中就整组不返回（含没 NFO / 没封面的版本），
        // 前端只做展示，不重复筛一遍
        excludeActors: _excludedActors.isEmpty
            ? null
            : _excludedActors.values.join('|'),
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
  ///
  /// 走**后台任务**（`/video/items/delete-task`）而不是同步接口：查重页一次能勾几十个，
  /// SMB 上移文件要几分钟，HTTP 请求撞 30s 超时（用户看到的
  /// `TimeoutException after 0:00:30`），界面报错但后台其实还在删。
  /// 现在弹一个不可关闭的进度框，靠任务表 `done_count / total_count` 画真实进度，
  /// 删完自动关掉。
  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty || _busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context, rootNavigator: true);
    // 默认走回收站（可恢复）；用户明确勾掉就直接永久删除
    var toTrash = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('common.delete')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('video.dup.deleteConfirm', {'count': '${ids.length}'})),
              const SizedBox(height: NasTokens.spaceSm),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: toTrash,
                onChanged: (v) => setLocal(() => toTrash = v ?? true),
                title: Text(tr('video.dup.toTrash')),
                subtitle: Text(
                  toTrash
                      ? tr('video.dup.toTrashHint')
                      : tr('video.dup.permanentHint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: toTrash
                        ? context.nasTextSecondary
                        : Theme.of(ctx).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
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
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final progress = ValueNotifier<_DeleteProgress>(
      _DeleteProgress(done: 0, total: ids.length, state: 'pending'),
    );
    // 只让弹窗“挂在那”，不 await：下面的代码要拿同一个 context 继续跑
    var dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DeleteProgressDialog(progress: progress),
      ).then((_) => dialogOpen = false),
    );

    String? failure;
    var doneCount = 0;
    var failedCount = 0;
    try {
      final res = await ApiSession.instance.client.videoItemsDeleteTask(
        body: VideoDeleteItemsBody(ids: ids, permanent: !toTrash),
      );
      final taskId = '${res['taskId'] ?? ''}';
      if (taskId.isEmpty) throw StateError('empty taskId');
      final total = (res['total'] as num?)?.toInt() ?? ids.length;
      final task = await _awaitDeleteTask(taskId, total, progress);
      doneCount = (task['done_count'] as num?)?.toInt() ?? 0;
      final state = '${task['state'] ?? ''}';
      if (state == 'failed') {
        failure = '${task['error'] ?? state}';
      } else if (state == 'canceled') {
        failure = tr('video.dup.deleteTaskTimeout');
      }
      failedCount = ids.isEmpty ? 0 : (ids.length - doneCount).clamp(0, ids.length);
    } catch (e) {
      failure = '$e';
      // 客户端异常也要进服务端日志，否则「设置 → 日志」里看不到用户报的错
      ClientLogger.instance.error(failure, route: 'POST /video/items/delete-task');
    } finally {
      // 先关弹窗再收尾；dialogOpen 防止重复 pop 到别的路由
      if (mounted && dialogOpen) nav.pop();
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;
    if (failure != null) {
      NasSnack.showOn(messenger, failure);
      await _load();
      return;
    }
    NasSnack.showOn(messenger, 
          failedCount == 0
              ? tr(
                  toTrash
                      ? 'video.dup.deleteDone'
                      : 'video.dup.deleteDonePermanent',
                  {'count': '$doneCount'},
                )
              : tr('video.dup.deletePartial', {
                  'done': '$doneCount',
                  'failed': '$failedCount',
                }),
        );
    _selected.clear();
    await _load();
  }

  /// 轮询任务直到 done / failed / canceled；超时不抛异常也不影响后台继续删
  Future<Map<String, dynamic>> _awaitDeleteTask(
    String id,
    int fallbackTotal,
    ValueNotifier<_DeleteProgress> progress,
  ) async {
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    while (mounted) {
      if (DateTime.now().isAfter(deadline)) {
        return <String, dynamic>{'state': 'canceled'};
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final t = await ApiSession.instance.client.tasksGet(id: id);
      final state = '${t['state'] ?? ''}';
      final done = (t['done_count'] as num?)?.toInt() ?? 0;
      final total = (t['total_count'] as num?)?.toInt() ?? 0;
      progress.value = _DeleteProgress(
        done: done,
        total: total > 0 ? total : fallbackTotal,
        state: state,
      );
      if (state == 'done' || state == 'failed' || state == 'canceled') return t;
    }
    return <String, dynamic>{'state': 'canceled'};
  }

  /// 日本片默认勾选规则（2026-10-26 口径，2026-11-03 补时间兜底）：
  ///   ① 破解版里留「分辨率最高、同分辨率体积最大」的一个；
  ///      规格完全一样（分辨率 / 体积都相同）时留**修改时间更早**的那份 ——
  ///      后下的那份往往是重下或二压，原始那份更值得留；
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
        if (it.size != pick.size) {
          if (it.size > pick.size) pick = it;
          continue;
        }
        // 同规格：留更早的那个（mtime 拿不到就保持原选择）
        if (it.mtime > 0 && pick.mtime > 0 && it.mtime < pick.mtime) pick = it;
      }
      return pick;
    }

    for (final g in res.groups) {
      final items = g.items.where((e) => e.id.isNotEmpty).toList();
      if (items.length < 2) continue;

      // 按**分片**分桶：`''` = 完整版，`cd1` / `cd2` / `part上` = 分片。
      //
      // 只有「同一个桶里有多份」才算重复 —— CD1 与 CD2 是同一部片的两段，
      // 天生不是重复（2026-11-03 反馈：别再把 CD1/CD2 塞进重复里）。
      // 单份的桶永远不勾，哪怕组里还有别的重复项。
      final byPart = <String, List<VideoDuplicateItem>>{};
      for (final it in items) {
        (byPart[it.part] ??= <VideoDuplicateItem>[]).add(it);
      }

      bool crackedOf(VideoDuplicateItem it) => it.uncensored || it.ltx;

      for (final entry in byPart.entries) {
        final bucket = entry.value;
        if (bucket.length < 2) continue;

        final keep = <String>{};
        if (entry.key.isEmpty) {
          // 完整版桶沿用 ①–③ 的破解版口径；非日本片组整体不预勾
          final jp = bucket.where((e) => e.isJp).toList();
          if (jp.isEmpty) continue;
          final cracked = jp.where(crackedOf).toList();
          final plain = jp.where((e) => !crackedOf(e)).toList();
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
        } else {
          // 分片桶：同一段只留规格最好的一份
          keep.add(best(bucket).id);
        }

        for (final it in bucket) {
          // 喜欢的演员：她要的片一份都不勾（手动点还是能勾，自动勾选不碰）
          if (_actorExcluded(it)) continue;
          if (!keep.contains(it.id)) out.add(it.id);
        }
      }
    }
    return out;
  }

  /// 打开演员排除面板。返回值整体替换当前排除集合（null = 取消）。
  Future<void> _openActorExclude() async {
    final picked = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ActorExcludeDialog(initial: Map.of(_excludedActors)),
    );
    if (picked == null || !mounted) return;
    final changed =
        picked.length != _excludedActors.length ||
        !picked.entries.every((e) => _excludedActors[e.key] == e.value);
    setState(() {
      _excludedActors
        ..clear()
        ..addAll(picked);
    });
    _persistExcluded();
    // 排除名单直接决定「哪些片不显示」，所以必须重查一次
    if (changed) await _load();
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
      NasSnack.show(context, tr('video.dup.autoSelectEmpty'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('video.duplicate.title')),
        actions: [
          // 演员排除放在库下拉**前面**：先定「谁的一律不删」，再看查重结果
          Padding(
            padding: const EdgeInsets.only(right: NasTokens.spaceXs),
            child: TextButton.icon(
              onPressed: _busy ? null : _openActorExclude,
              icon: const Icon(Icons.person_off_outlined, size: 18),
              label: Text(
                _excludedActors.isEmpty
                    ? tr('video.dup.actorExclude')
                    : tr('video.dup.actorExcluded', {
                        'count': '${_excludedActors.length}',
                      }),
              ),
            ),
          ),
          if (_libraries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: NasTokens.spaceSm),
              child: NasDropdown<String?>(
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
          NasRefreshButton(onPressed: _busy ? null : _load),
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
            message: _excludedActors.isEmpty
                ? tr('video.duplicate.hint2')
                : tr('video.dup.actorHidden', {
                    'count': '${_excludedActors.length}',
                  }),
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
                  if (_excludedActors.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr('video.dup.actorHidden', {
                        'count': '${_excludedActors.length}',
                      }),
                      style: TextStyle(
                        fontSize: NasTokens.fontMicro,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
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
    final url = _artUrl(item, size: (width * 2).round());
    final resolution = (item.width != null && item.height != null)
        ? '${item.width}×${item.height}'
        : tr('ui.book.hd9c32a');
    final meta = [
      formatBytes(item.size),
      resolution,
      if ((item.code ?? '').isNotEmpty) item.code!,
      // 分片角标：同一番号的 CD1/CD2 现在和完整版同组，得能一眼看出哪条是分片
      if (item.part.isNotEmpty) item.part.toUpperCase(),
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
          NasSnack.showOn(messenger, '$e');
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
          // 修改时间单独一行：同分辨率同体积的两份只能靠时间判断留哪份
          if (item.mtime > 0)
            Text(
              tr('video.dup.mtime', {
                'date': formatDateSec(item.mtime ~/ 1000),
              }),
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

  String? _artUrl(VideoDuplicateItem item, {int size = 0}) {
    final base = ApiSession.instance.baseUrl;
    final id = Uri.encodeComponent(item.id);
    final sizeQ = size > 0 ? '&size=$size' : '';
    // 「缩略图」是刮削出来的横版剧照（fanart），和日本电影库网格同一个口径；
    // 服务端按 fanart → poster → thumb 回退，绝不会退成视频抽帧截图。
    if (item.hasArt) {
      return '$base/api/v1/video/art?id=$id&kind=fanart$sizeQ';
    }
    // 完全没刮削过才用首帧兜底，至少还有张图能辨认
    return '$base/api/v1/video/poster?id=$id';
  }
}

/// 演员候选项（`/video/actors` 的 items 元素，接口是 inline 结构，这里薄封装一层）
class _ActorOption {
  const _ActorOption({
    required this.name,
    required this.key,
    required this.count,
  });

  final String name;

  /// 归一化键（服务端 `actorKey`）：选中的键与条目的 `actorKeys` 是同一套
  final String key;

  /// 库里有几个条目含这位演员
  final int count;
}

/// 演员排除面板：从 NFO 演员里搜索、多选，命中的人一律不进「自动勾选」。
///
/// 数据源是 `video_items.nfo_actors`（服务端聚合后缓存 5 分钟），不联网、不打 JavDB，
/// 所以打开面板是即时的。
class _ActorExcludeDialog extends StatefulWidget {
  const _ActorExcludeDialog({required this.initial});

  /// 打开时已有的排除集合（键 → 原名）
  final Map<String, String> initial;

  @override
  State<_ActorExcludeDialog> createState() => _ActorExcludeDialogState();
}

class _ActorExcludeDialogState extends State<_ActorExcludeDialog> {
  final _searchCtrl = TextEditingController();
  final Map<String, String> _picked = <String, String>{};
  List<_ActorOption> _items = const [];
  int _total = 0;
  bool _loading = true;
  String? _error;
  Timer? _debounce;

  /// 请求序号：搜索框连打时，只认最后一次的结果
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _picked.addAll(widget.initial);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final q = _searchCtrl.text.trim();
      final res = await ApiSession.instance.client.videoActors(
        q: q.isEmpty ? null : q,
        limit: 200,
      );
      if (!mounted || seq != _seq) return;
      final raw = (res['items'] as List?) ?? const [];
      setState(() {
        _items = raw
            .whereType<Map>()
            .map(
              (e) => _ActorOption(
                name: '${e['name'] ?? ''}'.trim(),
                key: '${e['key'] ?? ''}'.trim(),
                count: (e['count'] as num?)?.toInt() ?? 0,
              ),
            )
            .where((e) => e.name.isNotEmpty && e.key.isNotEmpty)
            .toList();
        _total = (res['total'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), _load);
  }

  void _toggle(String key, String name) {
    setState(() {
      if (_picked.remove(key) == null) _picked[key] = name;
    });
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Text(_error!, style: TextStyle(color: context.nasDanger)),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          tr('video.dup.actorEmpty'),
          textAlign: TextAlign.center,
          style: TextStyle(color: context.nasTextSecondary),
        ),
      );
    }
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final it = _items[i];
        final on = _picked.containsKey(it.key);
        return CheckboxListTile(
          dense: true,
          value: on,
          onChanged: (_) => _toggle(it.key, it.name),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            tr('video.dup.actorCount', {'count': '${it.count}'}),
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.person_off_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('video.dup.actorExclude'))),
          if (_total > 0)
            Text(
              tr('video.dup.actorTotal', {'count': '$_total'}),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 440,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('video.dup.actorExcludeHint'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: tr('video.dup.actorSearch'),
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
              ),
            ),
            if (_picked.isNotEmpty) ...[
              const SizedBox(height: NasTokens.spaceSm),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in _picked.entries.toList())
                    InputChip(
                      label: Text(entry.value),
                      onDeleted: () => _toggle(entry.key, entry.value),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            const SizedBox(height: NasTokens.spaceSm),
            Expanded(child: _body(context)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _picked.isEmpty ? null : () => setState(_picked.clear),
          child: Text(tr('video.dup.actorClear')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, Map.of(_picked)),
          child: Text(tr('common.ok')),
        ),
      ],
    );
  }
}

/// 删除任务的进度快照（来自任务表 `done_count / total_count`）
class _DeleteProgress {
  const _DeleteProgress({
    required this.done,
    required this.total,
    required this.state,
  });

  final int done;
  final int total;

  /// pending / running / done / failed / canceled
  final String state;
}

/// 删除进度框：不可关闭、点外部也关不掉，删完由调用方 pop。
class _DeleteProgressDialog extends StatelessWidget {
  const _DeleteProgressDialog({required this.progress});

  final ValueNotifier<_DeleteProgress> progress;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(tr('video.dup.deleting')),
        content: ValueListenableBuilder<_DeleteProgress>(
          valueListenable: progress,
          builder: (context, p, _) {
            final ratio = p.total > 0
                ? (p.done / p.total).clamp(0.0, 1.0)
                : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('video.dup.deletingHint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: p.state == 'done' ? 1 : ratio,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: NasTokens.spaceSm),
                Text(
                  p.total > 0 ? '${p.done}/${p.total}' : '${p.done}',
                  style: const TextStyle(
                    fontSize: NasTokens.fontCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
