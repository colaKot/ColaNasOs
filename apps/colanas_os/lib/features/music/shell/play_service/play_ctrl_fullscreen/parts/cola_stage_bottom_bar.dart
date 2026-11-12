import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../compat/cola_device_utils.dart';
import '../../../list/models/cola_list_models.dart';
import '../../../shared/music_item_logic.dart';
import '../../../shared/music_playback_logic.dart';
import '../../../shared/music_primitives.dart';
import '../../controller/cola_player_controller.dart';
import '../../play_ctrl_bottom/parts/cola_dock_center_area.dart';
import '../../play_ctrl_bottom/parts/cola_dock_left_area.dart';
import '../../play_ctrl_bottom/parts/cola_dock_volume_control.dart';

/// 舞台底部控制区：磨砂背景 + 进度条 + 曲目信息 + 播放控制。
class ColaMusicStageControls extends StatefulWidget {
  const ColaMusicStageControls({
    super.key,
    required this.controller,
    required this.item,
    required this.isPlaying,
    required this.discAsset,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.loopIcon,
    required this.loopMode,
    required this.volume,
    required this.favoriteLoading,
    required this.coverUrl,
    required this.onToggleFavorite,
    required this.onToggleLoopMode,
    required this.onPrev,
    required this.onNext,
    required this.onPlayPause,
    required this.onAddToPlayList,
    required this.onVolumeChanged,
    required this.onSeekTo,
  });

  final MusicPlayServiceController controller;
  final MusicListItem item;
  final bool isPlaying;
  final String discAsset;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final IconData loopIcon;
  final MusicLoopMode loopMode;
  final double volume;
  final bool favoriteLoading;
  final String coverUrl;
  final VoidCallback? onToggleFavorite;
  final VoidCallback onToggleLoopMode;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPlayPause;
  final VoidCallback? onAddToPlayList;
  final ValueChanged<double> onVolumeChanged;
  final Future<void> Function(Duration position) onSeekTo;

  @override
  State<ColaMusicStageControls> createState() => _ColaMusicStageControlsState();
}

class _ColaMusicStageControlsState extends State<ColaMusicStageControls> {
  Widget _scrim(bool narrow) {
    final sigma = narrow ? 50.0 : 24.0;
    return Positioned.fill(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: narrow ? 0.15 : 0.28),
              border: Border(
                top: BorderSide(
                  color: Colors.white.withValues(alpha: 0.06),
                  width: 0.8,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 窄屏标题行：曲名 + （下载百分比）副标题。
  Widget _titleRow(ThemeData theme, bool downloading, double progress) {
    final item = widget.item;
    final percent = downloading ? MusicTimeText.percent(progress) : '';
    final subtitle = item.isSeries
        ? ''
        : (item.displaySubtitleText.isNotEmpty
              ? item.displaySubtitleText
              : item.album.trim());
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ColaMusicDockMarqueeText(
            text: item.displayTitle,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4.0),
          Row(
            children: <Widget>[
              if (percent.isNotEmpty)
                Text(
                  percent,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              if (percent.isNotEmpty) const SizedBox(width: 8.0),
              if (subtitle.isNotEmpty)
                Expanded(
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _transport(bool narrow) {
    return ColaMusicDockControls(
      onToggleLoopMode: widget.onToggleLoopMode,
      onPrev: widget.onPrev,
      onPlayPause: widget.onPlayPause,
      onNext: widget.onNext,
      onAddToPlayList: widget.onAddToPlayList,
      loopMode: widget.loopMode,
      loopIcon: widget.loopIcon,
      isPlaying: widget.isPlaying,
      isNarrow: narrow,
    );
  }

  Widget _seekBar(bool narrow) {
    return _StageSeekBar(
      showTimeLabels: narrow,
      position: widget.position,
      onSeekTo: widget.onSeekTo,
      isNarrow: narrow,
      duration: widget.duration,
      buffered: widget.buffered,
    );
  }

  Widget _narrowContent(ThemeData theme, bool downloading, double progress) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _titleRow(theme, downloading, progress),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: _seekBar(true),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Center(child: _transport(true)),
        ),
      ],
    );
  }

  Widget _wideContent(ThemeData theme, bool downloading, double progress) {
    final left = ColaMusicDockInfo(
      onToggleFavorite: widget.onToggleFavorite,
      onOpenFullscreen: null,
      item: widget.item,
      isPlaying: widget.isPlaying,
      favoriteLoading: widget.favoriteLoading,
      downloadProgress: progress,
      downloading: downloading,
      discAsset: widget.discAsset,
      coverUrl: widget.coverUrl,
    );
    final volume = ColaMusicDockVolume(
      volume: widget.volume,
      onToggleMute: widget.controller.toggleMute,
      onChanged: widget.onVolumeChanged,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _seekBar(false),
        const SizedBox(height: 6.0),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Row(
            children: <Widget>[
              Expanded(flex: 3, child: left),
              Expanded(flex: 5, child: Center(child: _transport(false))),
              Expanded(
                flex: 3,
                child: Align(alignment: Alignment.centerRight, child: volume),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = DeviceUtils.isMobile;
    final theme = Theme.of(context);
    final download = MusicDownloadState(
      downloading: widget.controller.isDownloading.value,
      fileHash: widget.controller.downloadingFileHash.value,
      progress: widget.controller.downloadProgress.value,
    );
    final downloading = download.matches(widget.item.fileHash);
    final progress = downloading ? download.progress : 0.0;

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        _scrim(narrow),
        SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (_, _) => narrow
                ? _narrowContent(theme, downloading, progress)
                : _wideContent(theme, downloading, progress),
          ),
        ),
      ],
    );
  }
}

/// 全屏进度条：悬停 / 拖拽时轨道变粗，并在滑块上方浮出时间气泡。
class _StageSeekBar extends StatefulWidget {
  const _StageSeekBar({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeekTo,
    this.isNarrow = false,
    this.showTimeLabels = false,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final Future<void> Function(Duration position) onSeekTo;
  final bool isNarrow;
  final bool showTimeLabels;

  @override
  State<_StageSeekBar> createState() => _StageSeekBarState();
}

class _StageSeekBarState extends State<_StageSeekBar> {
  bool _hovered = false;
  bool _dragging = false;
  double _dragValueMs = 0;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  void _beginDrag(double value) {
    setState(() {
      _dragging = true;
      _dragValueMs = value;
    });
  }

  Future<void> _finishDrag(double value) async {
    setState(() {
      _dragging = false;
      _dragValueMs = value;
    });
    await widget.onSeekTo(MusicSeekBarMath.fromMs(value));
  }

  static double _mix(double from, double to, double t) =>
      from + (to - from) * t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxMs = MusicSeekBarMath.maxMs(widget.duration);
    final enabled = MusicSeekBarMath.isSeekEnabled(widget.duration);
    final valueMs = MusicSeekBarMath.valueMs(
      widget.position,
      widget.duration,
      dragging: _dragging,
      dragValueMs: _dragValueMs,
    );
    final overlayVisible = _hovered || _dragging;

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: overlayVisible ? 1 : 0),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        builder: (context, t, _) => _buildBar(
          context,
          theme,
          t,
          valueMs: valueMs,
          maxMs: maxMs,
          enabled: enabled,
          overlayVisible: overlayVisible,
        ),
      ),
    );
  }

  Widget _buildBar(
    BuildContext context,
    ThemeData theme,
    double t, {
    required double valueMs,
    required double maxMs,
    required bool enabled,
    required bool overlayVisible,
  }) {
    final narrow = widget.isNarrow;
    final trackHeight = _mix(narrow ? 6 : 2, narrow ? 8 : 4, t);
    final thumbRadius = _mix(narrow ? 8 : 4, narrow ? 10 : 8, t);
    final overlayRadius = _mix(narrow ? 16 : 10, narrow ? 18 : 14, t);
    final boxHeight = narrow ? 18.0 : 12.0;

    final bubbleStyle =
        theme.textTheme.titleMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ) ??
        const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 16.0,
        );
    final bubbleLabel = MusicTimeText.pair(
      MusicSeekBarMath.fromMs(valueMs),
      widget.duration,
    );
    final painter = TextPainter(
      text: TextSpan(text: bubbleLabel, style: bubbleStyle),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final bubbleWidth = painter.width + 32;
    final bubbleHeight = painter.height + 16;

    final slider = SizedBox(
      height: boxHeight,
      child: LayoutBuilder(
        builder: (_, box) {
          final fraction = (valueMs / maxMs).clamp(0.0, 1.0);
          final thumbX = box.maxWidth * fraction;
          final bubbleLeft = math.min(
            math.max(0.0, thumbX - bubbleWidth / 2),
            math.max(0.0, box.maxWidth - bubbleWidth),
          );

          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: 0.0,
                right: 0.0,
                top: -(boxHeight / 2),
                height: boxHeight,
                child: MusicSlider(
                  value: valueMs,
                  max: maxMs,
                  enabled: enabled,
                  trackHeight: trackHeight,
                  thumbRadius: thumbRadius,
                  overlayRadius: overlayRadius,
                  inactiveTrackColor: theme.dividerColor.withValues(
                    alpha: 0.42,
                  ),
                  trackShape: _StageTrackShape(
                    useRoundedCorners: narrow,
                    cornerRadius: narrow ? 4.0 : 0.0,
                  ),
                  onChanged: enabled ? _beginDrag : null,
                  onChangeStart: enabled ? _beginDrag : null,
                  onChangeEnd: enabled ? _finishDrag : null,
                ),
              ),
              Positioned(
                left: bubbleLeft,
                top: -bubbleHeight - 10,
                width: bubbleWidth,
                child: _TimeBubble(
                  text: bubbleLabel,
                  style: bubbleStyle,
                  visible: overlayVisible,
                ),
              ),
            ],
          );
        },
      ),
    );

    if (!widget.showTimeLabels) return slider;

    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        slider,
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              MusicTimeText.of(MusicSeekBarMath.fromMs(valueMs)),
              style: labelStyle,
            ),
            Text(MusicTimeText.of(widget.duration), style: labelStyle),
          ],
        ),
      ],
    );
  }
}

/// 拖动时跟随滑块的时间提示气泡。
class _TimeBubble extends StatelessWidget {
  const _TimeBubble({
    required this.text,
    required this.style,
    required this.visible,
  });

  final String text;
  final TextStyle style;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.all(Radius.circular(18)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Text(text, style: style),
          ),
        ),
      ),
    );
  }
}

/// 通栏矩形轨道；窄屏时左右两端带圆角，宽屏保持直角。
class _StageTrackShape extends RectangularSliderTrackShape {
  const _StageTrackShape({
    this.useRoundedCorners = false,
    this.cornerRadius = 4.0,
  });

  final bool useRoundedCorners;
  final double cornerRadius;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final height = sliderTheme.trackHeight ?? 2;
    final top = offset.dy + (parentBox.size.height - height) / 2;
    return Rect.fromLTWH(offset.dx, top, parentBox.size.width, height);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    if (!useRoundedCorners) {
      super.paint(
        context,
        offset,
        parentBox: parentBox,
        sliderTheme: sliderTheme,
        enableAnimation: enableAnimation,
        textDirection: textDirection,
        thumbCenter: thumbCenter,
        secondaryOffset: secondaryOffset,
        isEnabled: isEnabled,
        isDiscrete: isDiscrete,
      );
      return;
    }

    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final activeColor = ColorTween(
      begin: sliderTheme.disabledActiveTrackColor,
      end: sliderTheme.activeTrackColor,
    ).evaluate(enableAnimation)!;
    final inactiveColor = ColorTween(
      begin: sliderTheme.disabledInactiveTrackColor,
      end: sliderTheme.inactiveTrackColor,
    ).evaluate(enableAnimation)!;
    final ltr = textDirection == TextDirection.ltr;
    final radius = Radius.circular(cornerRadius);

    final played = RRect.fromRectAndCorners(
      Rect.fromLTRB(rect.left, rect.top, thumbCenter.dx, rect.bottom),
      topLeft: radius,
      bottomLeft: radius,
    );
    final remaining = RRect.fromRectAndCorners(
      Rect.fromLTRB(thumbCenter.dx, rect.top, rect.right, rect.bottom),
      topRight: radius,
      bottomRight: radius,
    );

    context.canvas
      ..drawRRect(played, Paint()..color = ltr ? activeColor : inactiveColor)
      ..drawRRect(
        remaining,
        Paint()..color = ltr ? inactiveColor : activeColor,
      );
  }
}
