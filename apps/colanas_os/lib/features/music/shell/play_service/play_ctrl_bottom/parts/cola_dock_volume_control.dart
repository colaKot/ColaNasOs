import 'package:flutter/material.dart';

import '../../../shared/music_primitives.dart';

class MusicPlayCtrlBottomVolumeControl extends StatefulWidget {
  final double volume;
  final bool showInlineSlider;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onChanged;

  final bool showLoopButton;
  final VoidCallback? onToggleLoopMode;
  final String? loopTooltip;
  final IconData? loopIcon;

  final bool showPlayListButton;
  final String? playListTooltip;
  final IconData? playListIcon;
  final VoidCallback? onAddToPlayList;

  final bool showNowPlayingButton;
  final VoidCallback? onShowNowPlaying;
  final String? nowPlayingTooltip;
  final IconData? nowPlayingIcon;

  final String? volumeTooltip;

  const MusicPlayCtrlBottomVolumeControl({
    super.key,
    required this.volume,
    required this.onChanged,
    required this.onToggleMute,
    this.showInlineSlider = true,
    this.showLoopButton = false,
    this.loopIcon,
    this.loopTooltip,
    this.onToggleLoopMode,
    this.showPlayListButton = false,
    this.playListIcon,
    this.playListTooltip,
    this.onAddToPlayList,
    this.showNowPlayingButton = false,
    this.nowPlayingIcon,
    this.nowPlayingTooltip,
    this.onShowNowPlaying,
    this.volumeTooltip,
  });

  @override
  State<MusicPlayCtrlBottomVolumeControl> createState() =>
      _MusicPlayCtrlBottomVolumeControlState();
}

class _MusicPlayCtrlBottomVolumeControlState
    extends State<MusicPlayCtrlBottomVolumeControl> {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _volumeEntry;
  Offset _volumeOverlayOffset = Offset.zero;

  @override
  void dispose() {
    _hideVolumeOverlay();
    super.dispose();
  }

  void _hideVolumeOverlay() {
    _volumeEntry?.remove();
    _volumeEntry = null;
  }

  void _showVolumeOverlay(BuildContext context, double value) {
    if (_volumeEntry != null) {
      _hideVolumeOverlay();
      return;
    }

    final overlayState = Overlay.of(context, rootOverlay: true);
    final anchorCtx = _anchorKey.currentContext;
    final anchorBox = anchorCtx?.findRenderObject() as RenderBox?;
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (overlayBox == null || anchorBox == null) return;

    final targetTopLeft = anchorBox.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );

    const popupHeight = 216.0;
    const popupWidth = 58.0;
    const margin = 8.0;

    var desiredTopLeft = Offset(
      targetTopLeft.dx + (anchorBox.size.width / 2) - (popupWidth / 2),
      targetTopLeft.dy - popupHeight - 10,
    );

    desiredTopLeft = Offset(
      desiredTopLeft.dx.clamp(
        margin,
        overlayBox.size.width - popupWidth - margin,
      ),
      desiredTopLeft.dy.clamp(
        margin,
        overlayBox.size.height - popupHeight - margin,
      ),
    );

    _volumeOverlayOffset = desiredTopLeft - targetTopLeft;

    final theme = Theme.of(context);
    _volumeEntry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                onTap: _hideVolumeOverlay,
                behavior: HitTestBehavior.translucent,
              ),
            ),
            CompositedTransformFollower(
              showWhenUnlinked: false,
              offset: _volumeOverlayOffset,
              link: _layerLink,
              child: Material(
                color: theme.colorScheme.surface,
                elevation: 10.0,
                borderRadius: BorderRadius.all(Radius.circular(10)),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints.tightFor(
                    width: popupWidth,
                    height: popupHeight,
                  ),
                  child: _VolumePopup(
                    theme: theme,
                    onToggleMute: widget.onToggleMute,
                    onChanged: (v) => widget.onChanged(v.clamp(0.0, 1.0)),
                    initialValue: value,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(_volumeEntry!);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.volume.clamp(0.0, 1.0);
    final theme = Theme.of(context);
    final iconColor = theme.iconTheme.color?.withValues(alpha: 0.7);

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.showLoopButton)
            _TinyIconButton(
              tooltip: widget.loopTooltip,
              onTap: widget.onToggleLoopMode,
              iconColor: iconColor,
              icon: widget.loopIcon ?? Icons.repeat,
              enabled: widget.onToggleLoopMode != null,
            ),
          if (widget.showPlayListButton)
            _TinyIconButton(
              tooltip: widget.playListTooltip,
              onTap: widget.onAddToPlayList,
              iconColor: iconColor,
              icon: widget.playListIcon ?? Icons.playlist_add,
              enabled: widget.onAddToPlayList != null,
            ),
          if (widget.showNowPlayingButton)
            _TinyIconButton(
              tooltip: widget.nowPlayingTooltip,
              onTap: widget.onShowNowPlaying,
              iconColor: iconColor,
              icon: widget.nowPlayingIcon ?? Icons.queue_music_outlined,
              enabled: widget.onShowNowPlaying != null,
            ),
          CompositedTransformTarget(
            link: _layerLink,
            child: Container(
              key: _anchorKey,
              child: _TinyIconButton(
                tooltip: widget.volumeTooltip,
                onTap: widget.showInlineSlider
                    ? widget.onToggleMute
                    : () => _showVolumeOverlay(context, v),
                onLongPress: widget.showInlineSlider
                    ? null
                    : widget.onToggleMute,
                iconColor: iconColor,
                icon: v <= 0.01 ? Icons.volume_off : Icons.volume_up,
              ),
            ),
          ),
          if (widget.showInlineSlider) ...[
            const SizedBox(width: 6.0),
            SizedBox(
              width: 80.0,
              child: MusicSlider(value: v, max: 1, onChanged: widget.onChanged),
            ),
          ],
        ],
      ),
    );
  }
}

class _TinyIconButton extends StatelessWidget {
  final String? tooltip;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? iconColor;
  final IconData icon;
  final bool enabled;

  const _TinyIconButton({
    required this.icon,
    required this.onTap,
    this.onLongPress,
    this.tooltip,
    this.enabled = true,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = GestureDetector(
      onTap: enabled ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        child: Icon(
          icon,
          size: 18.0,
          color: enabled
              ? iconColor
              : theme.disabledColor.withValues(alpha: 0.65),
        ),
      ),
    );

    final t = tooltip?.trim() ?? '';
    if (t.isEmpty) return child;
    return Tooltip(message: t, child: child);
  }
}

class _VolumePopup extends StatefulWidget {
  final ThemeData theme;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onChanged;
  final double initialValue;

  const _VolumePopup({
    required this.theme,
    required this.onToggleMute,
    required this.onChanged,
    required this.initialValue,
  });

  @override
  State<_VolumePopup> createState() => _VolumePopupState();
}

class _VolumePopupState extends State<_VolumePopup> {
  late double _v;

  @override
  void initState() {
    super.initState();
    _v = widget.initialValue.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final label = '${(_v * 100).round()}%';
    final theme = widget.theme;
    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 38.0,
              height: 148.0,
              child: RotatedBox(
                quarterTurns: -1,
                child: SizedBox(
                  width: 148.0,
                  child: MusicSlider(
                    value: _v,
                    max: 1,
                    onChanged: (v) {
                      setState(() {
                        _v = v.clamp(0.0, 1.0);
                      });
                      widget.onChanged(_v);
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4.0),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 2.0),
            GestureDetector(
              onTap: widget.onToggleMute,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Icon(
                  _v <= 0.01 ? Icons.volume_off : Icons.volume_up,
                  size: 18.0,
                  color: theme.iconTheme.color?.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
