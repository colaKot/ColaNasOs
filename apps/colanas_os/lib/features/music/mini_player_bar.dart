import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'music_playback.dart';
import 'music_player_page.dart';
import 'queue_sheet.dart';

/// 底部常驻播放条（mini player）。
///
/// 为什么必须有：播放服务 [MusicPlaybackService] 是常驻单例，离开播放页音乐还在放，
/// 但**没有任何入口能暂停 / 切歌 / 看在放什么** —— 桌面端连系统媒体键都没有，
/// 用户体验就是「放着放着就找不到了」。这条把控制权还给用户。
///
/// 只在有曲目时占位（没有歌就该完全消失，不能留一条空白把内容顶上来）。
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key, this.margin});

  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    final service = MusicPlaybackService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final track = service.track;
        if (track == null) return const SizedBox.shrink();
        return _Bar(service: service, track: track, margin: margin);
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.service, required this.track, this.margin});

  final MusicPlaybackService service;
  final MusicTrack track;
  final EdgeInsets? margin;

  String get _coverUrl =>
      ApiSession.instance.coverUrl('music', track.id);

  double get _ratio {
    final d = service.duration.inMilliseconds;
    if (d <= 0) return 0;
    return (service.position.inMilliseconds / d).clamp(0.0, 1.0);
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicPlayerPage(
          queue: service.queue,
          initialIndex: service.index < 0 ? 0 : service.index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = [track.artist, track.album]
        .where((v) => (v ?? '').trim().isNotEmpty)
        .join(' · ');

    return Padding(
      padding: margin ??
          const EdgeInsets.fromLTRB(
            NasTokens.spaceSm,
            0,
            NasTokens.spaceSm,
            NasTokens.spaceXs,
          ),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(NasTokens.radiusMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 细进度条贴在条的顶边（不占额外高度）
              LinearProgressIndicator(
                value: _ratio,
                minHeight: 2,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: NasCoverImage(
                          url: _coverUrl,
                          headers: ApiSession.instance.authHeaders,
                          icon: Icons.music_note_outlined,
                          cacheWidth: 96,
                        ),
                      ),
                    ),
                    const SizedBox(width: NasTokens.spaceSm),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: NasTokens.fontCaption,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: NasTokens.fontMicro,
                                color: context.nasTextSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: tr('ui.music.021'),
                      visualDensity: VisualDensity.compact,
                      iconSize: 20,
                      onPressed: service.queue.length > 1 ? service.previous : null,
                      icon: const Icon(Icons.skip_previous),
                    ),
                    IconButton(
                      tooltip: service.playing ? tr('ui.music.020') : tr('ui.music.019'),
                      visualDensity: VisualDensity.compact,
                      iconSize: 28,
                      onPressed: service.toggle,
                      icon: Icon(service.playing ? Icons.pause_circle : Icons.play_circle),
                    ),
                    IconButton(
                      tooltip: tr('ui.music.022'),
                      visualDensity: VisualDensity.compact,
                      iconSize: 20,
                      onPressed: service.queue.length > 1 ? service.next : null,
                      icon: const Icon(Icons.skip_next),
                    ),
                    IconButton(
                      tooltip: tr('music.queue.title'),
                      visualDensity: VisualDensity.compact,
                      iconSize: 20,
                      onPressed: () => showMusicQueueSheet(context),
                      icon: const Icon(Icons.queue_music),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
