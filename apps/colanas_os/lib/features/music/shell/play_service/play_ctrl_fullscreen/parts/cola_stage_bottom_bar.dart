import 'dart:math';
import 'dart:ui';

import '../../../compat/cola_device_utils.dart';

import 'package:flutter/material.dart';

import '../../../list/models/cola_list_models.dart';
import '../../../shared/music_item_logic.dart';
import '../../../shared/music_playback_logic.dart';
import '../../../shared/music_primitives.dart';
import '../../controller/cola_player_controller.dart';
import '../../play_ctrl_bottom/parts/cola_dock_center_area.dart';
import '../../play_ctrl_bottom/parts/cola_dock_left_area.dart';
import '../../play_ctrl_bottom/parts/cola_dock_volume_control.dart';

class MusicPlayCtrlFullScreenBottomBar extends StatefulWidget {
  final double volume;
  final Duration position;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleLoopMode;
  final VoidCallback? onToggleFavorite;
  final VoidCallback onPrev;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback? onAddToPlayList;
  final MusicLoopMode loopMode;
  final IconData loopIcon;
  final MusicListItem item;
  final bool isPlaying;
  final bool favoriteLoading;
  final Duration duration;
  final String discAsset;
  final String coverUrl;
  final MusicPlayServiceController controller;
  final Duration buffered;
  final Future<void> Function(Duration position) onSeekTo;

  const MusicPlayCtrlFullScreenBottomBar({
    required this.volume,
    required this.position,
    required this.onVolumeChanged,
    required this.onToggleLoopMode,
    required this.onToggleFavorite,
    required this.onSeekTo,
    required this.onPrev,
    required this.onPlayPause,
    required this.onNext,
    required this.onAddToPlayList,
    required this.loopMode,
    required this.loopIcon,
    super.key,
    required this.item,
    required this.isPlaying,
    required this.favoriteLoading,
    required this.duration,
    required this.discAsset,
    required this.coverUrl,
    required this.controller,
    required this.buffered,
  });

  @override
  State<MusicPlayCtrlFullScreenBottomBar> createState() =>
      _MusicPlayCtrlFullScreenBottomBarState();
}

class _MusicPlayCtrlFullScreenBottomBarState
    extends State<MusicPlayCtrlFullScreenBottomBar> {
  @override
  Widget build(BuildContext context) {
    final isNarrow = DeviceUtils.isMobile;
    final localTheme = Theme.of(context);

    final localDecoration = BoxDecoration(
      color: isNarrow
          ? Colors.black.withValues(alpha: 0.15)
          : Colors.black.withValues(alpha: 0.28),
      border: Border(
        top: BorderSide(
          color: Colors.white.withValues(alpha: 0.06),
          width: 0.8,
        ),
      ),
    );

    final localBlurSigma = isNarrow ? 50.0 : 24.0;

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: localBlurSigma,
                sigmaY: localBlurSigma,
              ),
              child: Container(decoration: localDecoration),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (ctx, c) {
              final isNarrow = DeviceUtils.isMobile;
              final downloadState = MusicDownloadState(
                downloading: widget.controller.isDownloading.value,
                fileHash: widget.controller.downloadingFileHash.value,
                progress: widget.controller.downloadProgress.value,
              );
              final localDownloading = downloadState.matches(
                widget.item.fileHash,
              );
              final localDownloadProgress = localDownloading
                  ? downloadState.progress
                  : 0.0;

              final localSubtitle = widget.item.isSeries
                  ? ''
                  : widget.item.displaySubtitleText.isNotEmpty
                  ? widget.item.displaySubtitleText
                  : widget.item.album.trim();
              final localSubtitleColor = localTheme.colorScheme.onSurface
                  .withValues(alpha: 0.6);
              final localProgressText = localDownloading
                  ? MusicTimeText.percent(localDownloadProgress)
                  : '';

              final localTitleRow = Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    MusicPlayCtrlBottomMarqueeText(
                      text: widget.item.displayTitle,
                      style: localTheme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: localTheme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4.0),
                    Row(
                      children: <Widget>[
                        if (localProgressText.isNotEmpty)
                          Text(
                            localProgressText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: localTheme.textTheme.bodySmall?.copyWith(
                              color: localSubtitleColor,
                            ),
                          ),
                        if (localProgressText.isNotEmpty)
                          const SizedBox(width: 8.0),
                        if (localSubtitle.isNotEmpty)
                          Expanded(
                            child: Text(
                              localSubtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: localTheme.textTheme.bodySmall?.copyWith(
                                color: localSubtitleColor,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );

              final localControls = MusicPlayCtrlBottomCenterControls(
                onToggleLoopMode: widget.onToggleLoopMode,
                onPrev: widget.onPrev,
                onPlayPause: widget.onPlayPause,
                onNext: widget.onNext,
                onAddToPlayList: widget.onAddToPlayList,
                loopMode: widget.loopMode,
                loopIcon: widget.loopIcon,
                isPlaying: widget.isPlaying,
                isNarrow: isNarrow,
              );

              final localSeekBar = _FullScreenHoverSeekBar(
                showTimeLabels: isNarrow,
                position: widget.position,
                onSeekTo: widget.onSeekTo,
                isNarrow: isNarrow,
                duration: widget.duration,
                buffered: widget.buffered,
              );

              if (isNarrow) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    localTitleRow,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                      child: localSeekBar,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      child: Center(child: localControls),
                    ),
                  ],
                );
              }

              final localLeft = MusicPlayCtrlBottomLeftArea(
                onToggleFavorite: widget.onToggleFavorite,
                onOpenFullscreen: null,
                item: widget.item,
                isPlaying: widget.isPlaying,
                favoriteLoading: widget.favoriteLoading,
                downloadProgress: localDownloadProgress,
                downloading: localDownloading,
                discAsset: widget.discAsset,
                coverUrl: widget.coverUrl,
              );

              final localVol = MusicPlayCtrlBottomVolumeControl(
                volume: widget.volume,
                onToggleMute: widget.controller.toggleMute,
                onChanged: widget.onVolumeChanged,
              );

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  localSeekBar,
                  const SizedBox(height: 6.0),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: Row(
                      children: <Widget>[
                        Expanded(flex: 3, child: localLeft),
                        Expanded(flex: 5, child: Center(child: localControls)),
                        Expanded(
                          flex: 3,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: localVol,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FullScreenHoverSeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final Future<void> Function(Duration position) onSeekTo;
  final bool isNarrow;
  final bool showTimeLabels;

  const _FullScreenHoverSeekBar({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeekTo,
    this.isNarrow = false,
    this.showTimeLabels = false,
  });

  @override
  State<_FullScreenHoverSeekBar> createState() =>
      _FullScreenHoverSeekBarState();
}

class _FullScreenHoverSeekBarState extends State<_FullScreenHoverSeekBar> {
  bool _hover = false;
  bool _dragging = false;
  double _dragValueMs = 0;

  @override
  Widget build(BuildContext context) {
    final localTheme = Theme.of(context);
    final localMaxMs = MusicSeekBarMath.maxMs(widget.duration);
    final localEnabled = MusicSeekBarMath.isSeekEnabled(widget.duration);
    final localValue = MusicSeekBarMath.valueMs(
      widget.position,
      widget.duration,
      dragging: _dragging,
      dragValueMs: _dragValueMs,
    );

    final localShowOverlay = _hover || _dragging;
    final localPosText = MusicTimeText.of(MusicSeekBarMath.fromMs(localValue));
    final localDurText = MusicTimeText.of(widget.duration);

    return MouseRegion(
      onExit: (_) => setState(() => _hover = false),
      onEnter: (_) => setState(() => _hover = true),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: localShowOverlay ? 1 : 0),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        builder: (context, t, _) {
          final localMaxTrackHeight = widget.isNarrow ? 8 : 4;
          final localBaseTrackHeight = widget.isNarrow ? 6 : 2;
          final localMaxThumbRadius = widget.isNarrow ? 10 : 8;
          final localBaseThumbRadius = widget.isNarrow ? 8 : 4;
          final localMaxOverlayRadius = widget.isNarrow ? 18 : 14;
          final localBaseOverlayRadius = widget.isNarrow ? 16 : 10;
          final localSliderBoxHeight = widget.isNarrow ? 18.0 : 12.0;

          final localTrackHeight =
              localBaseTrackHeight +
              (localMaxTrackHeight - localBaseTrackHeight) * t;
          final localThumbRadius =
              localBaseThumbRadius +
              (localMaxThumbRadius - localBaseThumbRadius) * t;
          final localOverlayRadius =
              localBaseOverlayRadius +
              (localMaxOverlayRadius - localBaseOverlayRadius) * t;
          final localSliderTop = -(localSliderBoxHeight / 2);
          final localTextStyle =
              localTheme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ) ??
              const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16.0,
                color: Colors.white,
              );
          final localSmallTextStyle = localTheme.textTheme.bodySmall?.copyWith(
            color: localTheme.colorScheme.onSurface.withValues(alpha: 0.7),
          );
          final localTooltipText = MusicTimeText.pair(
            MusicSeekBarMath.fromMs(localValue),
            widget.duration,
          );
          final localTextPainter = TextPainter(
            textDirection: Directionality.of(context),
            text: TextSpan(text: localTooltipText, style: localTextStyle),
            maxLines: 1,
          )..layout();
          final localTooltipHeight = localTextPainter.height + 16;
          final localTooltipWidth = localTextPainter.width + 32;

          final cornerRadius = widget.isNarrow ? 4.0 : 0.0;

          final sliderWidget = SizedBox(
            height: localSliderBoxHeight,
            child: LayoutBuilder(
              builder: (context, c) {
                final localFraction = (localValue / localMaxMs).clamp(0.0, 1.0);
                final localThumbX = c.maxWidth * localFraction;
                final localTooltipLeft = min(
                  max(0.0, localThumbX - localTooltipWidth / 2),
                  max(0.0, c.maxWidth - localTooltipWidth),
                );

                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned(
                      left: 0.0,
                      right: 0.0,
                      top: localSliderTop,
                      height: localSliderBoxHeight,
                      child: MusicSlider(
                        value: localValue,
                        max: localMaxMs,
                        enabled: localEnabled,
                        trackHeight: localTrackHeight,
                        thumbRadius: localThumbRadius,
                        overlayRadius: localOverlayRadius,
                        inactiveTrackColor: Theme.of(context).dividerColor
                            .withValues(alpha: 0.42),
                        trackShape: _FullWidthRectTrackShape(
                          useRoundedCorners: widget.isNarrow,
                          cornerRadius: cornerRadius,
                        ),
                        onChanged: localEnabled
                            ? (v) => setState(() {
                                _dragging = true;
                                _dragValueMs = v;
                              })
                            : null,
                        onChangeStart: localEnabled
                            ? (v) => setState(() {
                                _dragging = true;
                                _dragValueMs = v;
                              })
                            : null,
                        onChangeEnd: localEnabled
                            ? (v) async {
                                setState(() {
                                  _dragging = false;
                                  _dragValueMs = v;
                                });
                                await widget.onSeekTo(
                                  MusicSeekBarMath.fromMs(v),
                                );
                              }
                            : null,
                      ),
                    ),
                    Positioned(
                      left: localTooltipLeft,
                      top: -localTooltipHeight - 10,
                      width: localTooltipWidth,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: localShowOverlay ? 1 : 0,
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.easeOut,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.all(
                                Radius.circular(18),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 8.0,
                              ),
                              child: Text(
                                localTooltipText,
                                style: localTextStyle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );

          if (widget.showTimeLabels) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                sliderWidget,
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(localPosText, style: localSmallTextStyle),
                    Text(localDurText, style: localSmallTextStyle),
                  ],
                ),
              ],
            );
          }

          return sliderWidget;
        },
      ),
    );
  }
}

class _FullWidthRectTrackShape extends RectangularSliderTrackShape {
  final bool useRoundedCorners;
  final double cornerRadius;

  const _FullWidthRectTrackShape({
    this.useRoundedCorners = false,
    this.cornerRadius = 4.0,
  });

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final localTrackLeft = offset.dx;
    final localTrackHeight = sliderTheme.trackHeight ?? 2;
    final localTrackWidth = parentBox.size.width;
    final localTrackTop =
        offset.dy + (parentBox.size.height - localTrackHeight) / 2;
    return Rect.fromLTWH(
      localTrackLeft,
      localTrackTop,
      localTrackWidth,
      localTrackHeight,
    );
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

    final Rect localTrackRect = getPreferredRect(
      sliderTheme: sliderTheme,
      parentBox: parentBox,
      offset: offset,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    final ColorTween localActiveTrackColorTween = ColorTween(
      begin: sliderTheme.disabledActiveTrackColor,
      end: sliderTheme.activeTrackColor,
    );
    final ColorTween localInactiveTrackColorTween = ColorTween(
      begin: sliderTheme.disabledInactiveTrackColor,
      end: sliderTheme.inactiveTrackColor,
    );
    final Paint localActivePaint = Paint()
      ..color = localActiveTrackColorTween.evaluate(enableAnimation)!;
    final Paint localInactivePaint = Paint()
      ..color = localInactiveTrackColorTween.evaluate(enableAnimation)!;

    final Paint leftTrackPaint;
    final Paint rightTrackPaint;
    switch (textDirection) {
      case TextDirection.ltr:
        leftTrackPaint = localActivePaint;
        rightTrackPaint = localInactivePaint;
      case TextDirection.rtl:
        leftTrackPaint = localInactivePaint;
        rightTrackPaint = localActivePaint;
    }

    final RRect localLeftRRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(
        localTrackRect.left,
        localTrackRect.top,
        thumbCenter.dx - localTrackRect.left,
        localTrackRect.height,
      ),
      topLeft: Radius.circular(cornerRadius),
      bottomLeft: Radius.circular(cornerRadius),
    );
    final RRect localRightRRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(
        thumbCenter.dx,
        localTrackRect.top,
        localTrackRect.right - thumbCenter.dx,
        localTrackRect.height,
      ),
      topRight: Radius.circular(cornerRadius),
      bottomRight: Radius.circular(cornerRadius),
    );

    context.canvas.drawRRect(localLeftRRect, leftTrackPaint);
    context.canvas.drawRRect(localRightRRect, rightTrackPaint);
  }
}
