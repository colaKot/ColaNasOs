import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../../shared/music_playback_logic.dart';
import '../../../shared/music_primitives.dart';
import '../../controller/cola_player_controller.dart';

/// 播放条中部：上一首 / 播放 / 下一首 + 进度条。
class ColaMusicDockProgress extends StatelessWidget {
  const ColaMusicDockProgress({
    super.key,
    required this.isPlaying,
    required this.loopMode,
    required this.loopIcon,
    required this.onToggleLoopMode,
    this.showLoopButton = true,
    required this.onPrev,
    required this.onNext,
    required this.onPlayPause,
    required this.onAddToPlayList,
    this.showAddToPlayListButton = true,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.dragging,
    required this.dragValueMs,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final bool showLoopButton;
  final bool showAddToPlayListButton;
  final VoidCallback onToggleLoopMode;
  final VoidCallback onPrev;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback? onAddToPlayList;
  final MusicLoopMode loopMode;
  final IconData loopIcon;
  final bool isPlaying;

  final Duration position;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragStart;
  final ValueChanged<double> onDragEnd;
  final Duration duration;
  final double dragValueMs;
  final bool dragging;
  final Duration buffered;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ColaMusicDockControls(
            isPlaying: isPlaying,
            loopMode: loopMode,
            loopIcon: loopIcon,
            onToggleLoopMode: onToggleLoopMode,
            showLoopButton: showLoopButton,
            onPrev: onPrev,
            onNext: onNext,
            onPlayPause: onPlayPause,
            onAddToPlayList: onAddToPlayList,
            showAddToPlayListButton: showAddToPlayListButton,
          ),
          ColaMusicDockSeekBar(
            position: position,
            duration: duration,
            buffered: buffered,
            dragging: dragging,
            dragValueMs: dragValueMs,
            onDragStart: onDragStart,
            onDragUpdate: onDragUpdate,
            onDragEnd: onDragEnd,
          ),
          const SizedBox(height: 10.0),
        ],
      ),
    );
  }
}

/// 两端显示时间、中间为可拖动滑块的进度条。
class ColaMusicDockSeekBar extends StatelessWidget {
  const ColaMusicDockSeekBar({
    required this.position,
    required this.onDragUpdate,
    required this.onDragStart,
    required this.onDragEnd,
    super.key,
    required this.duration,
    required this.dragValueMs,
    required this.dragging,
    required this.buffered,
  });

  final Duration position;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragStart;
  final ValueChanged<double> onDragEnd;
  final Duration duration;
  final double dragValueMs;
  final bool dragging;
  final Duration buffered;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context);
    final maxMs = MusicSeekBarMath.maxMs(duration);
    final seekable = MusicSeekBarMath.isSeekEnabled(duration);
    final currentMs = MusicSeekBarMath.valueMs(
      position,
      duration,
      dragging: dragging,
      dragValueMs: dragValueMs,
    );
    final timeStyle = palette.textTheme.bodySmall?.copyWith(
      color: palette.colorScheme.onSurface.withValues(alpha: 0.7),
    );

    return Row(
      children: <Widget>[
        Text(
          MusicTimeText.of(MusicSeekBarMath.fromMs(currentMs)),
          style: timeStyle,
        ),
        const SizedBox(width: 1.0),
        Expanded(
          child: MusicSlider(
            value: currentMs,
            max: maxMs,
            trackHeight: 4,
            enabled: seekable,
            onChanged: seekable ? onDragUpdate : null,
            onChangeStart: seekable ? onDragStart : null,
            onChangeEnd: seekable ? onDragEnd : null,
          ),
        ),
        const SizedBox(width: 1.0),
        Text(MusicTimeText.of(duration), style: timeStyle),
      ],
    );
  }
}

/// 传输控制按钮组，全屏与悬浮两种尺寸共用。
class ColaMusicDockControls extends StatelessWidget {
  const ColaMusicDockControls({
    super.key,
    required this.isPlaying,
    required this.loopMode,
    required this.loopIcon,
    required this.onToggleLoopMode,
    this.showLoopButton = true,
    required this.onPrev,
    required this.onNext,
    required this.onPlayPause,
    required this.onAddToPlayList,
    this.showAddToPlayListButton = true,
    this.isNarrow = false,
  });

  final bool showLoopButton;
  final bool showAddToPlayListButton;
  final VoidCallback onToggleLoopMode;
  final VoidCallback onPrev;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback? onAddToPlayList;
  final MusicLoopMode loopMode;
  final IconData loopIcon;
  final bool isPlaying;
  final bool isNarrow;

  @override
  Widget build(BuildContext context) {
    final iconSize = isNarrow ? 32.0 : 24.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showLoopButton)
          IconButton(
            tooltip: loopMode.i18nKey.tr,
            onPressed: onToggleLoopMode,
            iconSize: iconSize,
            icon: Icon(loopIcon, size: iconSize),
          ),
        _buildIconButton(
          tooltip: 'music_prev_track'.tr,
          icon: Icons.skip_previous,
          onPressed: onPrev,
          size: iconSize,
        ),
        ColaMusicDockPlayButton(
          isPlaying: isPlaying,
          onPressed: onPlayPause,
          isNarrow: isNarrow,
        ),
        _buildIconButton(
          tooltip: 'music_next_track'.tr,
          icon: Icons.skip_next,
          onPressed: onNext,
          size: iconSize,
        ),
        if (showAddToPlayListButton && onAddToPlayList != null)
          _buildIconButton(
            tooltip: 'add_to_play_list'.tr,
            icon: Icons.playlist_add,
            onPressed: onAddToPlayList,
            size: iconSize,
          ),
      ],
    );
  }

  Widget _buildIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    required double size,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: size,
      icon: Icon(icon, size: size),
    );
  }
}

/// 主播放 / 暂停按钮，使用主题主色。
class ColaMusicDockPlayButton extends StatelessWidget {
  const ColaMusicDockPlayButton({
    super.key,
    required this.isPlaying,
    required this.onPressed,
    this.isNarrow = false,
  });

  final VoidCallback onPressed;
  final bool isPlaying;
  final bool isNarrow;

  @override
  Widget build(BuildContext context) {
    final glyphSize = isNarrow ? 46.8 : 36.0;
    final tint = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: isPlaying ? 'pause'.tr : 'play'.tr,
      onPressed: onPressed,
      iconSize: glyphSize,
      icon: Icon(
        isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
        color: tint,
        size: glyphSize,
      ),
    );
  }
}
