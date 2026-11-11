import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'video_card.dart';

/// 刮削结果 → 用户能看懂的一句话。
///
/// 为什么单独一个函数：五种状态（成功 / 跳过 / 没匹配到 / 不可用 / 失败）
/// 在三个页面（详情、列表菜单、批量）都要用，散着写必然文案不一致。
String scrapeOutcomeText(VideoScrapeResponse res) {
  switch (res.status) {
    case 'scraped':
      final base = tr('video.scrape.done', {
        'title': res.title ?? '',
        'source': res.source ?? '',
      });
      // 磁盘上的 nfo 比我们上次写库更新 = 用户手改过：明确告诉他"没覆盖你的"
      return res.sidecar == 'kept-user' ? '$base · ${tr('video.scrape.sidecarKept')}' : base;
    case 'skipped':
      return res.reason == 'excluded'
          ? tr('video.scrape.excluded')
          : (res.reason ?? tr('video.scrape.notfound'));
    case 'notfound':
      return res.reason ?? tr('video.scrape.notfound');
    case 'unavailable':
      return '${tr('video.scrape.notConfigured')}（${res.reason ?? ''}）';
    default:
      return res.reason ?? tr('video.scrape.notfound');
  }
}

/// 显示一次刮削的结果；不可用时额外给「去设置」的提示。
Future<void> showScrapeOutcome(BuildContext context, VideoScrapeResponse res) async {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  NasSnack.showOn(
    messenger,
    scrapeOutcomeText(res),
    duration: const Duration(seconds: 4),
  );
}

/// 手动匹配：搜 TMDB → 选一条 → 以 `tmdbId` 重新刮削。
///
/// 返回 true 表示写库成功（调用方据此刷新详情）。
///
/// `applyIds` 给「剧级」用：一次匹配把这条 TMDB 结果套到这部剧的全部集上
/// （服务端刮削是「一条一集」的，不能只写一集就指望整剧跟着变）。
Future<bool> showTmdbMatchDialog(
  BuildContext context, {
  required VideoItem item,
  List<String>? applyIds,
  String? initialQuery,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _TmdbMatchDialog(
      item: item,
      applyIds: applyIds,
      initialQuery: initialQuery,
    ),
  );
  return result == true;
}

class _TmdbMatchDialog extends StatefulWidget {
  const _TmdbMatchDialog({required this.item, this.applyIds, this.initialQuery});

  final VideoItem item;

  /// 非空时把匹配结果套到这些条目上（剧级手动匹配）
  final List<String>? applyIds;

  /// 搜索框预填：剧级用剧名（`item.title` 只是某一集的标题）
  final String? initialQuery;

  @override
  State<_TmdbMatchDialog> createState() => _TmdbMatchDialogState();
}

class _TmdbMatchDialogState extends State<_TmdbMatchDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text:
        widget.initialQuery ??
        // 预填：刮削名优先，否则文件名；用户多半只需按一下搜索
        (widget.item.title.isNotEmpty ? widget.item.title : widget.item.fileTitle),
  );
  bool _searching = false;
  bool _configured = true;
  String? _error;
  String? _progress;
  List<VideoTmdbCandidate> _items = const [];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoTmdbSearch(
        body: VideoTmdbSearchBody(
          q: q,
          mediaType: widget.item.series != null ? 'tv' : 'movie',
          year: (widget.item.year ?? 0) > 0 ? widget.item.year : null,
        ),
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _configured = res.configured;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _searching = false;
      });
    }
  }

  Future<void> _apply(VideoTmdbCandidate c) async {
    final targets = (widget.applyIds == null || widget.applyIds!.isEmpty)
        ? <String>[widget.item.id]
        : widget.applyIds!;
    setState(() {
      _searching = true;
      _error = null;
      _progress = null;
    });
    var scraped = 0;
    try {
      for (var i = 0; i < targets.length; i += 1) {
        final res = await ApiSession.instance.client.videoScrapeStart(
          body: VideoScrapeBody(
            id: targets[i],
            mode: 'force',
            mediaType: c.mediaType == 'tv' ? 'tv' : 'movie',
            tmdbId: c.tmdbId,
          ),
        );
        if (res.status == 'scraped') scraped += 1;
        if (!mounted) return;
        if (targets.length > 1) {
          setState(() {
            _progress = tr('video.scrape.bulkRunning', {
              'done': '${i + 1}',
              'total': '${targets.length}',
            });
          });
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(scraped > 0);
      if (scraped == 0) {
        NasSnack.show(context, tr('video.scrape.notfound'));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _searching = false;
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('video.scrape.searchTitle')),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: tr('video.scrape.searchHint'),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: Text(tr('common.search')),
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceSm),
            if (!_configured)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
                child: Text(
                  tr('video.scrape.notConfigured'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              ),
            Expanded(
              child: _searching
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          if (_progress != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _progress!,
                              style: TextStyle(
                                fontSize: NasTokens.fontCaption,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : _items.isEmpty
                      ? Center(
                          child: Text(
                            tr('video.scrape.noResult'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final c = _items[i];
                            final posterPath = c.posterPath;
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: SizedBox(
                                width: 40,
                                height: 60,
                                child: posterPath == null
                                    ? Container(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                      )
                                    : NasCoverImage(
                                        url:
                                            '${ApiSession.instance.baseUrl}/api/v1/discover/image?path=${Uri.encodeComponent(posterPath)}&size=w92',
                                        headers: videoArtHeaders,
                                        fallbackText: c.title,
                                      ),
                              ),
                              title: Text(
                                c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  if ((c.year ?? 0) > 0) '${c.year}',
                                  if ((c.score ?? 0) > 0) '★ ${(c.score ?? 0).toStringAsFixed(1)}',
                                  if (c.originalTitle.isNotEmpty && c.originalTitle != c.title)
                                    c.originalTitle,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: NasTokens.fontMicro),
                              ),
                              trailing: Text(tr('video.scrape.apply')),
                              onTap: () => _apply(c),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('common.cancel')),
        ),
      ],
    );
  }
}
