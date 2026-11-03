import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import 'music_playback.dart';

/// 播放队列抽屉：看当前队列、点播、拖动排序、移出、清空。
///
/// 此前队列只存在于 `MusicPlaybackService` 的内存里，界面上**完全没有入口** ——
/// 用户点开一首歌后想"看看后面还排了什么、把某首去掉"，无处可去。
Future<void> showMusicQueueSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _QueueSheet(),
  );
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final service = MusicPlaybackService.instance;
    return SafeArea(
      child: AnimatedBuilder(
        animation: service,
        builder: (context, _) {
          final queue = service.queue;
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.62,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NasTokens.spaceMd,
                    0,
                    NasTokens.spaceSm,
                    NasTokens.spaceXs,
                  ),
                  child: Row(
                    children: [
                      Text(
                        tr('music.queue.title'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: NasTokens.spaceSm),
                      Text(
                        tr('music.queue.count', {'count': '${queue.length}'}),
                        style: TextStyle(
                          fontSize: NasTokens.fontCaption,
                          color: context.nasTextSecondary,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: queue.isEmpty
                            ? null
                            : () {
                                service.clearQueue();
                                Navigator.of(context).pop();
                              },
                        icon: const Icon(Icons.clear_all, size: 18),
                        label: Text(tr('music.queue.clear')),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: queue.isEmpty
                      ? Center(
                          child: Text(
                            tr('music.queue.empty'),
                            style: TextStyle(color: context.nasTextSecondary),
                          ),
                        )
                      : ReorderableListView.builder(
                          padding: const EdgeInsets.only(bottom: NasTokens.spaceMd),
                          itemCount: queue.length,
                          onReorderItem: service.moveTo,
                          itemBuilder: (context, i) {
                            final t = queue[i];
                            final active = i == service.index;
                            return ListTile(
                              key: ValueKey('queue-${t.id}-$i'),
                              dense: true,
                              leading: SizedBox(
                                width: 26,
                                child: active
                                    ? Icon(
                                        service.playing
                                            ? Icons.equalizer
                                            : Icons.pause_circle_outline,
                                        size: 18,
                                        color: Theme.of(context).colorScheme.primary,
                                      )
                                    : Text(
                                        '${i + 1}',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: NasTokens.fontCaption,
                                          color: context.nasTextSecondary,
                                        ),
                                      ),
                              ),
                              title: Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: active ? FontWeight.w700 : null,
                                  color: active
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                              ),
                              subtitle: Text(
                                [t.artist ?? '', t.album ?? '']
                                    .where((x) => x.isNotEmpty)
                                    .join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => service.jumpTo(i),
                              trailing: IconButton(
                                tooltip: tr('music.queue.remove'),
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => service.removeAt(i),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
