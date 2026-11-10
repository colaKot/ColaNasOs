import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../../shared/music_playback_logic.dart';
import '../../../shared/music_primitives.dart';
import '../../controller/cola_player_controller.dart';

class MusicPlayCtrlBottomCenterArea extends StatelessWidget {
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

  const MusicPlayCtrlBottomCenterArea({
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

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          MusicPlayCtrlBottomCenterControls(
            showLoopButton: showLoopButton,
            showAddToPlayListButton: showAddToPlayListButton,
            onToggleLoopMode: onToggleLoopMode,
            onPrev: onPrev,
            onPlayPause: onPlayPause,
            onNext: onNext,
            onAddToPlayList: onAddToPlayList,
            loopMode: loopMode,
            loopIcon: loopIcon,
            isPlaying: isPlaying,
          ),
          MusicPlayCtrlBottomSeekBarWithTime(
            position: position,
            onDragUpdate: onDragUpdate,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            duration: duration,
            dragValueMs: dragValueMs,
            dragging: dragging,
            buffered: buffered,
          ),
          const SizedBox(height: 10.0),
        ],
      ),
    );
  }
}

class MusicPlayCtrlBottomSeekBarWithTime extends StatelessWidget {
  final Duration position;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragStart;
  final ValueChanged<double> onDragEnd;
  final Duration duration;
  final double dragValueMs;
  final bool dragging;
  final Duration buffered;

  const MusicPlayCtrlBottomSeekBarWithTime({
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxMs = MusicSeekBarMath.maxMs(duration);
    final enabled = MusicSeekBarMath.isSeekEnabled(duration);
    final value = MusicSeekBarMath.valueMs(
      position,
      duration,
      dragging: dragging,
      dragValueMs: dragValueMs,
    );

    final leftLabel = MusicTimeText.of(MusicSeekBarMath.fromMs(value));
    final rightLabel = MusicTimeText.of(duration);

    return Row(
      children: <Widget>[
        Text(
          leftLabel,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(width: 1.0),
        Expanded(
          child: MusicSlider(
            value: value,
            max: maxMs,
            trackHeight: 4,
            enabled: enabled,
            onChanged: enabled ? onDragUpdate : null,
            onChangeStart: enabled ? onDragStart : null,
            onChangeEnd: enabled ? onDragEnd : null,
          ),
        ),
        const SizedBox(width: 1.0),
        Text(
          rightLabel,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

class MusicPlayCtrlBottomCenterControls extends StatelessWidget {
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

  const MusicPlayCtrlBottomCenterControls({
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

  @override
  Widget build(BuildContext context) {
    final loopTip = loopMode.i18nKey.tr;

    final iconSize = isNarrow ? 32.0 : 24.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showLoopButton)
          IconButton(
            tooltip: loopTip,
            onPressed: onToggleLoopMode,
            iconSize: iconSize,
            icon: Icon(loopIcon, size: iconSize),
          ),
        IconButton(
          tooltip: 'music_prev_track'.tr,
          onPressed: onPrev,
          iconSize: iconSize,
          icon: Icon(Icons.skip_previous, size: iconSize),
        ),
        MusicPlayCtrlBottomPlayPauseButton(
          onPressed: onPlayPause,
          isPlaying: isPlaying,
          isNarrow: isNarrow,
        ),
        IconButton(
          tooltip: 'music_next_track'.tr,
          onPressed: onNext,
          iconSize: iconSize,
          icon: Icon(Icons.skip_next, size: iconSize),
        ),
        if (showAddToPlayListButton && onAddToPlayList != null)
          IconButton(
            tooltip: 'add_to_play_list'.tr,
            onPressed: onAddToPlayList,
            iconSize: iconSize,
            icon: Icon(Icons.playlist_add, size: iconSize),
          ),
      ],
    );
  }
}

class MusicPlayCtrlBottomPlayPauseButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool isPlaying;
  final bool isNarrow;

  const MusicPlayCtrlBottomPlayPauseButton({
    super.key,
    required this.isPlaying,
    required this.onPressed,
    this.isNarrow = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = isNarrow ? 46.8 : 36.0;
    final theme = Theme.of(context);
    return IconButton(
      tooltip: isPlaying ? 'pause'.tr : 'play'.tr,
      onPressed: onPressed,
      iconSize: size,
      icon: Icon(
        isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
        color: theme.colorScheme.primary,
        size: size,
      ),
    );
  }
}
