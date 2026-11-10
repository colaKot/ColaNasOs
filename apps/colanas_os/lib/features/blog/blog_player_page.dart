import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import 'blog_player.dart';
import 'blog_queue_sheet.dart';

/// 博客的**全屏播放页**：点底部迷你播放条进来。
///
/// 与音乐播放页同一套心智模型：封面区 + 可拖进度条 + 上/下一期 + 倍速 + 播放列表。
/// 播放器本身是全局单例，这里只是它的一个视图；返回 / 切模块 / 熄屏都不会停。
class BlogPlayerPage extends StatefulWidget {
  const BlogPlayerPage({super.key, this.player});

  final BlogPlayer? player;

  @override
  State<BlogPlayerPage> createState() => _BlogPlayerPageState();
}

class _BlogPlayerPageState extends State<BlogPlayerPage> {
  /// 拖动进度条期间用本地值，不然 position 流会把滑块往回拽
  double? _dragValue;

  BlogPlayer get _player => widget.player ?? BlogPlayer.instance;

  static const List<double> _rates = [1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _player,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final p = _player;
    final ep = p.episode;
    final total = p.duration.inMilliseconds > 0
        ? p.duration.inMilliseconds
        : (ep == null ? 0 : (ep.durationSec * 1000).round());
    final pos = p.position.inMilliseconds.clamp(0, total == 0 ? 0 : total);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('blog.player.title')),
        actions: [
          IconButton(
            tooltip: tr('blog.queue.title'),
            onPressed: () => showBlogQueueSheet(context, p),
            icon: const Icon(Icons.queue_music),
          ),
        ],
      ),
      body: ep == null
          ? Center(child: Text(tr('blog.player.noEpisode')))
          : Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Padding(
                    padding: const EdgeInsets.all(NasTokens.spaceLg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 播客没有封面图，用一个稳定的品牌色块，不引额外资源
                        AspectRatio(
                          aspectRatio: 1,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(NasTokens.radiusLg),
                              gradient: LinearGradient(
                                colors: [
                                  scheme.primaryContainer,
                                  scheme.tertiaryContainer,
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                            child: Icon(
                              Icons.podcasts,
                              size: 96,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(height: NasTokens.spaceLg),
                        Text(
                          ep.title,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: NasTokens.fontTitle,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: NasTokens.spaceXs),
                        Text(
                          [
                            formatDateTimeSec(ep.createdAt),
                            formatDurationMs(total),
                            tr('blog.episodes.items', {'count': ep.itemCount}),
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                        const SizedBox(height: NasTokens.spaceLg),
                        Slider(
                          value: _dragValue ?? (total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0),
                          onChanged: total > 0
                              ? (v) => setState(() => _dragValue = v)
                              : null,
                          onChangeEnd: total > 0
                              ? (v) {
                                  p.seek(Duration(milliseconds: (total * v).round()));
                                  setState(() => _dragValue = null);
                                }
                              : null,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(formatDurationMs(pos)),
                              Text(formatDurationMs(total)),
                            ],
                          ),
                        ),
                        const SizedBox(height: NasTokens.spaceMd),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton(
                              onPressed: () {
                                final i = _rates.indexOf(p.rate);
                                p.setRate(_rates[(i + 1) % _rates.length]);
                              },
                              child: Text('${p.rate.toStringAsFixed(2).replaceAll(RegExp(r'0$'), '')}x'),
                            ),
                            IconButton(
                              tooltip: tr('blog.player.prev'),
                              onPressed: p.queue.isEmpty ? null : p.prev,
                              icon: const Icon(Icons.skip_previous),
                            ),
                            const SizedBox(width: NasTokens.spaceSm),
                            IconButton.filled(
                              tooltip: p.playing
                                  ? tr('blog.player.pause')
                                  : tr('blog.player.play'),
                              onPressed: p.toggle,
                              iconSize: 40,
                              icon: p.loading
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : Icon(p.playing ? Icons.pause : Icons.play_arrow),
                            ),
                            const SizedBox(width: NasTokens.spaceSm),
                            IconButton(
                              tooltip: tr('blog.player.next'),
                              onPressed: p.queue.isEmpty ? null : p.next,
                              icon: const Icon(Icons.skip_next),
                            ),
                            TextButton.icon(
                              onPressed: () => showBlogQueueSheet(context, p),
                              icon: const Icon(Icons.queue_music, size: 18),
                              label: Text('${p.index + 1} / ${p.queue.length}'),
                            ),
                          ],
                        ),
                        if (p.error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: NasTokens.spaceMd),
                            child: Text(
                              p.error!,
                              style: const TextStyle(
                                color: Color(NasTokens.colorDanger),
                                fontSize: NasTokens.fontCaption,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
