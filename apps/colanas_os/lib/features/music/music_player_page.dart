import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'equalizer.dart';
import 'music_cache.dart';
import 'music_playback.dart';
import 'queue_sheet.dart';

/// 音乐内置播放器（SP3-04 二期）：常驻 media_kit 内核 + 歌词跟播高亮。
///
/// 播放状态放在 [MusicPlaybackService] 单例里：离开本页、切换模块、最小化窗口
/// 都不会停播；Web 端同时更新浏览器 Media Session（系统媒体面板 / 媒体键可用）。
/// 宽屏：左侧封面与控件 + 右侧歌词；窄屏：上下堆叠。
class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({
    super.key,
    required this.queue,
    this.initialIndex = 0,
  });

  final List<MusicTrack> queue;
  final int initialIndex;

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage> {
  /// 有译文时每行多占一行小字；滚动定位用同一个高度
  static const _lineExtent = 44.0;
  static const _lineExtentBilingual = 60.0;

  final MusicPlaybackService _service = MusicPlaybackService.instance;
  final ScrollController _lyricsScroll = ScrollController();
  int _activeLine = -1;

  bool get _bilingual => _service.bilingual;

  double get _lineHeight =>
      _bilingual ? _lineExtentBilingual : _lineExtent;

  MusicTrack? get _track => _service.track;

  @override
  void initState() {
    super.initState();
    if (widget.queue.isNotEmpty) {
      _service.playQueue(widget.queue, widget.initialIndex);
    }
    _activeLine = _service.activeLine;
    _service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _lyricsScroll.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final active = _service.activeLine;
    // 播放位置每秒 notify 多次；只有「当前歌词行变了」才需要整页重建。
    // 进度条自己用 AnimatedBuilder 监听 service（见 _controlPane），不靠这里。
    if (active == _activeLine) return;
    setState(() => _activeLine = active);
    _scrollToActive(active);
  }

  void _scrollToActive(int active) {
    if (!_lyricsScroll.hasClients || active < 0) return;
    final extent = _lineHeight;
    final viewport = _lyricsScroll.position.viewportDimension;
    final target = (active * extent - viewport / 2 + extent / 2)
        .clamp(0.0, _lyricsScroll.position.maxScrollExtent);
    _lyricsScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Future<void> _openEqualizer() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                tr('ui.music.031'),
                style: const TextStyle(fontSize: NasTokens.fontSubtitle),
              ),
            ),
            for (final preset in equalizerPresets)
              ListTile(
                leading: Icon(
                  preset.id == _service.equalizerPreset
                      ? Icons.check
                      : Icons.graphic_eq,
                ),
                title: Text(tr(preset.labelKey)),
                onTap: () => Navigator.pop(ctx, preset.id),
              ),
          ],
        ),
      ),
    );
    if (selected != null) await _service.setEqualizer(selected);
  }

  static String _fmt(Duration d) {
    final total = d.inSeconds;
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 下载当前曲目到本地缓存（进度提示走 SnackBar；失败如实说原因）
  Future<void> _cacheCurrent(MusicTrack track) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(tr('music.cache.downloading'))));
    try {
      await _service.cacheTrack(track);
      messenger.showSnackBar(SnackBar(content: Text(tr('music.cache.done'))));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('music.cache.failed', {'error': '$e'}))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = _track;
    if (widget.queue.isEmpty || track == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('ui.music.019'))),
        body: NasEmptyState(
          title: tr('ui.music.016'),
          message: tr('ui.music.h266f73'),
          icon: Icons.music_note,
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(track.title, overflow: TextOverflow.ellipsis),
        actions: [
          // 离线缓存：只对有本地目录的平台显示（Web 端 MusicCache.supported = false）
          if (MusicCache.instance.supported)
            AnimatedBuilder(
              animation: _service,
              builder: (context, _) {
                final cached = _service.isCached(track.id);
                return IconButton(
                  tooltip: cached ? tr('music.cache.cached') : tr('music.cache.download'),
                  icon: Icon(
                    cached ? Icons.offline_pin : Icons.download_for_offline_outlined,
                    color: cached ? Theme.of(context).colorScheme.primary : null,
                  ),
                  onPressed: cached ? null : () => _cacheCurrent(track),
                );
              },
            ),
          if (!kIsWeb)
            IconButton(
              tooltip: tr('ui.music.031'),
              icon: const Icon(Icons.graphic_eq),
              onPressed: _openEqualizer,
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = useTwoPane(constraints.maxWidth);
          final panel = _controlPane(wide, track);
          final lyrics = _lyricsPane();
          if (!wide) {
            return Column(
              children: [
                panel,
                const Divider(height: 1),
                Expanded(child: lyrics),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 340, child: panel),
              const VerticalDivider(width: 1),
              Expanded(child: lyrics),
            ],
          );
        },
      ),
    );
  }

  Widget _controlPane(bool wide, MusicTrack track) {
    final coverSize = wide ? 220.0 : 132.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: coverSize,
            height: coverSize,
            child: NasCoverImage(
              url: ApiSession.instance.coverUrl('music', track.id),
              headers: ApiSession.instance.authHeaders,
              cacheWidth: (coverSize * 2).round(),
              icon: Icons.music_note,
              borderRadius: NasTokens.radiusMd,
            ),
          ),
          const SizedBox(height: NasTokens.spaceMd),
          Text(
            track.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: NasTokens.fontTitle),
          ),
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            [
              track.artist ?? tr('ui.music.hfcc741'),
              track.album ?? tr('ui.music.h324451'),
            ].join(' · '),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          if (_service.error != null) ...[
            const SizedBox(height: NasTokens.spaceSm),
            Text(
              _service.error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasDanger,
              ),
            ),
          ],
          const SizedBox(height: NasTokens.spaceSm),
          // 进度区自己监听 service：播放位置每秒 notify 4~10 次，若靠整页 setState
          // 驱动，封面、控制按钮、整棵歌词列表都会跟着重建。这里只让这一小块重建。
          AnimatedBuilder(
            animation: _service,
            builder: (context, _) {
              final dMs = _service.duration.inMilliseconds > 0
                  ? _service.duration.inMilliseconds
                  : (track.durationMs ?? 0);
              final mMs = dMs == 0 ? 1 : dMs;
              final v = _service.position.inMilliseconds.clamp(0, mMs).toDouble();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Slider(
                    value: v,
                    max: mMs.toDouble(),
                    onChanged: dMs == 0
                        ? null
                        : (x) => _service.seek(Duration(milliseconds: x.round())),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceXs),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _fmt(_service.position),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: NasTokens.fontMono,
                            color: context.nasTextSecondary,
                          ),
                        ),
                        Text(
                          _fmt(Duration(milliseconds: dMs)),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: NasTokens.fontMono,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: NasTokens.spaceSm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: tr('music.play.shuffle'),
                iconSize: 24,
                onPressed: () => _service.setShuffle(!_service.shuffle),
                icon: Icon(
                  Icons.shuffle,
                  color: _service.shuffle
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              const SizedBox(width: NasTokens.spaceXs),
              IconButton(
                tooltip: tr('ui.music.021'),
                iconSize: 32,
                onPressed: _service.previous,
                icon: const Icon(Icons.skip_previous),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              IconButton.filled(
                tooltip: tr(_service.playing ? 'ui.music.020' : 'ui.music.019'),
                iconSize: 40,
                onPressed: _service.toggle,
                icon: Icon(
                  _service.playing ? Icons.pause : Icons.play_arrow,
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              IconButton(
                tooltip: tr('ui.music.022'),
                iconSize: 32,
                onPressed: _service.next,
                icon: const Icon(Icons.skip_next),
              ),
              const SizedBox(width: NasTokens.spaceXs),
              IconButton(
                tooltip: tr(_repeatLabelKey(_service.repeatMode)),
                iconSize: 24,
                onPressed: _service.cycleRepeatMode,
                icon: Icon(
                  _service.repeatMode == MusicRepeatMode.one
                      ? Icons.repeat_one
                      : Icons.repeat,
                  color: _service.repeatMode == MusicRepeatMode.off
                      ? null
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceXs),
          TextButton.icon(
            onPressed: () => showMusicQueueSheet(context),
            icon: const Icon(Icons.queue_music, size: 18),
            label: Text(
              '${_service.index + 1} / ${_service.queue.length} · ${tr('music.queue.title')}',
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lyricsPane() {
    if (_service.lyricsLoading) return const NasLoading();
    final lines = _service.lyrics?.lines ?? const <MusicLyricsLine>[];
    if (lines.isEmpty) {
      return NasEmptyState(
        title: tr('ui.music.016'),
        message: tr('ui.music.hdb4c02'),
        icon: Icons.lyrics_outlined,
      );
    }
    final synced = _service.lyrics?.synced ?? false;
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceMd,
            0,
          ),
          child: Text(
            tr('ui.music.015'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _lyricsScroll,
            itemExtent: _lineHeight,
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final line = lines[i];
              final active = synced && i == _activeLine;
              return InkWell(
                onTap: line.timeMs == null
                    ? null
                    : () => _service.seek(
                        Duration(milliseconds: line.timeMs!),
                      ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NasTokens.spaceMd,
                  ),
                  child: Row(
                    children: [
                      if (line.timeMs != null)
                        SizedBox(
                          width: 52,
                          child: Text(
                            _fmt(Duration(milliseconds: line.timeMs!)),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: NasTokens.fontMono,
                              color: active
                                  ? primary
                                  : context.nasTextSecondary,
                            ),
                          ),
                        ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              line.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: active
                                    ? NasTokens.fontSubtitle
                                    : NasTokens.fontBody,
                                color: active
                                    ? primary
                                    : context.nasTextSecondary,
                                fontWeight: active
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                            if ((line.translation ?? '').isNotEmpty)
                              Text(
                                line.translation!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: NasTokens.fontCaption,
                                  color: active
                                      ? primary
                                      : context.nasTextSecondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 播放模式按钮的 tooltip 键（循环切换三态，提示要跟着状态走）
String _repeatLabelKey(MusicRepeatMode mode) => switch (mode) {
  MusicRepeatMode.off => 'music.play.repeatOff',
  MusicRepeatMode.all => 'music.play.repeatAll',
  MusicRepeatMode.one => 'music.play.repeatOne',
};
