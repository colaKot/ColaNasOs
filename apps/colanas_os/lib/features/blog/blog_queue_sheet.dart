import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import 'blog_player.dart';

/// 播放列表弹层：看队列、跳某一期、移除、再往里加多期。
///
/// 队列默认就是列表页里全部已完成的期次（自动连播），这里可以把它裁成自己想听的几期，
/// 也可以再从「全部期次」里补回来 —— 对应音乐的「3 / 120 · 播放列表」。
Future<void> showBlogQueueSheet(BuildContext context, BlogPlayer player) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      child: _BlogQueueSheet(player: player),
    ),
  );
}

class _BlogQueueSheet extends StatefulWidget {
  const _BlogQueueSheet({required this.player});

  final BlogPlayer player;

  @override
  State<_BlogQueueSheet> createState() => _BlogQueueSheetState();
}

class _BlogQueueSheetState extends State<_BlogQueueSheet> {
  BlogPlayer get p => widget.player;

  Future<void> _addAll() async {
    for (final ep in List.of(p.library)) {
      await p.enqueue(ep);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: p,
      builder: (context, _) {
        final queue = p.queue;
        final candidates = p.library.where((e) => !p.inQueue(e.id)).toList(growable: false);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      tr('blog.queue.title'),
                      style: const TextStyle(
                        fontSize: NasTokens.fontSubtitle,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text('${queue.length}'),
                    TextButton(
                      onPressed: queue.isEmpty ? null : p.clearQueue,
                      child: Text(tr('blog.queue.clear')),
                    ),
                  ],
                ),
                Flexible(
                  child: queue.isEmpty
                      ? Center(child: Text(tr('blog.queue.empty')))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: queue.length,
                          itemBuilder: (context, i) {
                            final ep = queue[i];
                            final current = i == p.index;
                            return ListTile(
                              dense: true,
                              leading: current
                                  ? Icon(Icons.volume_up, size: 20, color: scheme.primary)
                                  : SizedBox(
                                      width: 20,
                                      child: Text(
                                        '${i + 1}',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: NasTokens.fontCaption,
                                          color: context.nasTextSecondary,
                                        ),
                                      ),
                                    ),
                              title: Text(
                                ep.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: current ? scheme.primary : null,
                                  fontWeight: current ? FontWeight.w600 : null,
                                ),
                              ),
                              subtitle: Text(
                                formatDurationMs((ep.durationSec * 1000).round()),
                                style: TextStyle(fontSize: NasTokens.fontCaption),
                              ),
                              onTap: () {
                                Navigator.of(context).pop();
                                p.jumpTo(i);
                              },
                              trailing: IconButton(
                                tooltip: tr('blog.queue.remove'),
                                onPressed: () => p.removeAt(i),
                                icon: const Icon(Icons.close, size: 18),
                              ),
                            );
                          },
                        ),
                ),
                const Divider(height: 1),
                Row(
                  children: [
                    Text(
                      tr('blog.queue.add'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: candidates.isEmpty ? null : _addAll,
                      child: Text(tr('blog.queue.addAll')),
                    ),
                  ],
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 190),
                  child: candidates.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(NasTokens.spaceMd),
                          child: Text(
                            tr('blog.queue.noMore'),
                            style: TextStyle(
                              fontSize: NasTokens.fontCaption,
                              color: context.nasTextSecondary,
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: candidates.length,
                          itemBuilder: (context, i) {
                            final ep = candidates[i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.add, size: 18),
                              title: Text(
                                ep.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => p.enqueue(ep),
                            );
                          },
                        ),
                ),
                const SizedBox(height: NasTokens.spaceSm),
              ],
            ),
          ),
        );
      },
    );
  }
}
