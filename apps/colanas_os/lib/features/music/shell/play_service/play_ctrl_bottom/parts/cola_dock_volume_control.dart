import 'package:flutter/material.dart';

import '../../../shared/music_primitives.dart';

/// 播放条右侧工具区：循环、加入歌单、播放队列与音量入口。
class ColaMusicDockVolume extends StatefulWidget {
  const ColaMusicDockVolume({
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

  @override
  State<ColaMusicDockVolume> createState() => _ColaMusicDockVolumeState();
}

class _ColaMusicDockVolumeState extends State<ColaMusicDockVolume> {
  static const double _popupWidth = 58.0;
  static const double _popupHeight = 216.0;
  static const double _edgeGap = 8.0;

  final LayerLink _anchorLink = LayerLink();
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _popupEntry;
  Offset _popupOffset = Offset.zero;

  @override
  void dispose() {
    _dismissPopup();
    super.dispose();
  }

  void _dismissPopup() {
    _popupEntry?.remove();
    _popupEntry = null;
  }

  /// 以锚点中心对齐弹出层，并保证不超出窗口边界。
  Offset _anchorRelativeOffset(RenderBox anchor, RenderBox overlay) {
    final anchorOrigin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    final wanted = Offset(
      anchorOrigin.dx + anchor.size.width / 2 - _popupWidth / 2,
      anchorOrigin.dy - _popupHeight - 10,
    );
    final clamped = Offset(
      wanted.dx.clamp(_edgeGap, overlay.size.width - _popupWidth - _edgeGap),
      wanted.dy.clamp(_edgeGap, overlay.size.height - _popupHeight - _edgeGap),
    );
    return clamped - anchorOrigin;
  }

  void _togglePopup(BuildContext context, double level) {
    if (_popupEntry != null) {
      _dismissPopup();
      return;
    }

    final overlay = Overlay.of(context, rootOverlay: true);
    final anchor = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (anchor == null || overlayBox == null) return;

    _popupOffset = _anchorRelativeOffset(anchor, overlayBox);
    final palette = Theme.of(context);

    _popupEntry = OverlayEntry(
      builder: (_) => Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              onTap: _dismissPopup,
              behavior: HitTestBehavior.translucent,
            ),
          ),
          CompositedTransformFollower(
            showWhenUnlinked: false,
            link: _anchorLink,
            offset: _popupOffset,
            child: Material(
              color: palette.colorScheme.surface,
              elevation: 10.0,
              borderRadius: const BorderRadius.all(Radius.circular(10)),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints.tightFor(
                  width: _popupWidth,
                  height: _popupHeight,
                ),
                child: _DockVolumePopup(
                  theme: palette,
                  initialValue: level,
                  onToggleMute: widget.onToggleMute,
                  onChanged: (v) => widget.onChanged(v.clamp(0.0, 1.0)),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    overlay.insert(_popupEntry!);
  }

  Widget _buildVolumeButton(BuildContext context, double level, Color? tint) {
    return CompositedTransformTarget(
      link: _anchorLink,
      child: Container(
        key: _anchorKey,
        child: _DockIconAction(
          tooltip: widget.volumeTooltip,
          onTap: widget.showInlineSlider
              ? widget.onToggleMute
              : () => _togglePopup(context, level),
          onLongPress: widget.showInlineSlider ? null : widget.onToggleMute,
          iconColor: tint,
          icon: level <= 0.01 ? Icons.volume_off : Icons.volume_up,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.volume.clamp(0.0, 1.0);
    final palette = Theme.of(context);
    final tint = palette.iconTheme.color?.withValues(alpha: 0.7);

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.showLoopButton)
            _DockIconAction(
              tooltip: widget.loopTooltip,
              onTap: widget.onToggleLoopMode,
              iconColor: tint,
              icon: widget.loopIcon ?? Icons.repeat,
              enabled: widget.onToggleLoopMode != null,
            ),
          if (widget.showPlayListButton)
            _DockIconAction(
              tooltip: widget.playListTooltip,
              onTap: widget.onAddToPlayList,
              iconColor: tint,
              icon: widget.playListIcon ?? Icons.playlist_add,
              enabled: widget.onAddToPlayList != null,
            ),
          if (widget.showNowPlayingButton)
            _DockIconAction(
              tooltip: widget.nowPlayingTooltip,
              onTap: widget.onShowNowPlaying,
              iconColor: tint,
              icon: widget.nowPlayingIcon ?? Icons.queue_music_outlined,
              enabled: widget.onShowNowPlaying != null,
            ),
          _buildVolumeButton(context, level, tint),
          if (widget.showInlineSlider) ...[
            const SizedBox(width: 6.0),
            SizedBox(
              width: 80.0,
              child: MusicSlider(
                value: level,
                max: 1,
                onChanged: widget.onChanged,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 只有图标的轻量按钮，tooltip 为空时不包裹 Tooltip。
class _DockIconAction extends StatelessWidget {
  const _DockIconAction({
    required this.icon,
    this.tooltip,
    this.onTap,
    this.onLongPress,
    this.iconColor,
    this.enabled = true,
  });

  final String? tooltip;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? iconColor;
  final IconData icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context);
    final tappable = GestureDetector(
      onTap: enabled ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          icon,
          size: 18.0,
          color: enabled
              ? iconColor
              : palette.disabledColor.withValues(alpha: 0.65),
        ),
      ),
    );

    final label = tooltip?.trim() ?? '';
    return label.isEmpty ? tappable : Tooltip(message: label, child: tappable);
  }
}

/// 竖直音量面板：滑块旋转 90 度，底部显示百分比与静音按钮。
class _DockVolumePopup extends StatefulWidget {
  const _DockVolumePopup({
    required this.theme,
    required this.onToggleMute,
    required this.onChanged,
    required this.initialValue,
  });

  final ThemeData theme;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onChanged;
  final double initialValue;

  @override
  State<_DockVolumePopup> createState() => _DockVolumePopupState();
}

class _DockVolumePopupState extends State<_DockVolumePopup> {
  late double _level;

  @override
  void initState() {
    super.initState();
    _level = widget.initialValue.clamp(0.0, 1.0);
  }

  void _onSlide(double value) {
    final next = value.clamp(0.0, 1.0);
    setState(() {
      _level = next;
    });
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.theme;

    return Material(
      color: palette.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(8),
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
                    value: _level,
                    max: 1,
                    onChanged: _onSlide,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4.0),
            Text(
              '${(_level * 100).round()}%',
              style: palette.textTheme.bodySmall?.copyWith(
                color: palette.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 2.0),
            GestureDetector(
              onTap: widget.onToggleMute,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  _level <= 0.01 ? Icons.volume_off : Icons.volume_up,
                  size: 18.0,
                  color: palette.iconTheme.color?.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
