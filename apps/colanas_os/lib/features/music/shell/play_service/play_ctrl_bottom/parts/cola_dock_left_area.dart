import 'dart:async';

import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../../list/models/cola_list_models.dart';
import '../../../shared/music_item_logic.dart';
import '../../../shared/music_playback_logic.dart';
import '../../app_components/cola_disc_cover.dart';

/// 播放条左侧：封面、标题与副信息，以及收藏按钮。
class ColaMusicDockInfo extends StatelessWidget {
  const ColaMusicDockInfo({
    required this.onToggleFavorite,
    this.onOpenFullscreen,
    super.key,
    required this.item,
    required this.isPlaying,
    required this.favoriteLoading,
    required this.downloadProgress,
    required this.downloading,
    required this.discAsset,
    required this.coverUrl,
  });

  final VoidCallback? onToggleFavorite;
  final VoidCallback? onOpenFullscreen;
  final MusicListItem item;
  final bool isPlaying;
  final bool favoriteLoading;
  final double downloadProgress;
  final bool downloading;
  final String discAsset;
  final String coverUrl;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context);
    final mutedColor = palette.colorScheme.onSurface.withValues(alpha: 0.6);

    return Row(
      children: <Widget>[
        MusicPlayDiscCover(
          onTap: onOpenFullscreen,
          isPlaying: isPlaying,
          discAsset: discAsset,
          coverUrl: coverUrl,
        ),
        const SizedBox(width: 10.0),
        Expanded(
          child: _buildTexts(
            palette: palette,
            mutedColor: mutedColor,
            progressLabel: MusicTimeText.downloadPercent(
              downloading,
              downloadProgress,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTexts({
    required ThemeData palette,
    required Color mutedColor,
    required String progressLabel,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: ColaMusicDockMarqueeText(
            text: item.displayTitle,
            style: palette.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 6.0),
        Row(
          mainAxisSize: MainAxisSize.max,
          children: _buildMetaItems(
            palette: palette,
            mutedColor: mutedColor,
            progressLabel: progressLabel,
          ),
        ),
      ],
    );
  }

  List<Widget> _buildMetaItems({
    required ThemeData palette,
    required Color mutedColor,
    required String progressLabel,
  }) {
    final showFavorite = item.canShowIndexActions && onToggleFavorite != null;
    final subtitle = item.displaySubtitleText;
    final smallStyle = palette.textTheme.bodySmall?.copyWith(color: mutedColor);

    return <Widget>[
      if (showFavorite) ...[
        _buildFavoriteButton(mutedColor),
        const SizedBox(width: 6.0),
      ],
      if (progressLabel.isNotEmpty) ...[
        Text(
          progressLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: smallStyle,
        ),
        const SizedBox(width: 8.0),
      ],
      if (subtitle.isNotEmpty)
        Expanded(
          child: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: smallStyle,
          ),
        ),
    ];
  }

  Widget _buildFavoriteButton(Color mutedColor) {
    final marked = item.isFavorite;
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: marked ? 'unfavorite'.tr : 'favorites'.tr,
      padding: EdgeInsets.zero,
      onPressed: favoriteLoading ? null : onToggleFavorite,
      icon: favoriteLoading
          ? const SizedBox(
              width: 18.0,
              height: 18.0,
              child: CircularProgressIndicator(
                strokeWidth: 1.0,
                color: Colors.red,
              ),
            )
          : Icon(
              marked ? Icons.favorite : Icons.favorite_border,
              size: 18.0,
              color: marked ? Colors.red : mutedColor,
            ),
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }
}

/// 宽度不足时自动横向滚动的单行文本。
class ColaMusicDockMarqueeText extends StatefulWidget {
  const ColaMusicDockMarqueeText({
    required this.text,
    required this.style,
    super.key,
  });

  final String text;
  final TextStyle? style;

  @override
  State<ColaMusicDockMarqueeText> createState() =>
      _ColaMusicDockMarqueeTextState();
}

class _ColaMusicDockMarqueeTextState extends State<ColaMusicDockMarqueeText> {
  static const Duration _leadIn = Duration(milliseconds: 600);
  static const Duration _tailHold = Duration(milliseconds: 500);
  static const Duration _rewindHold = Duration(milliseconds: 300);

  final ScrollController _scroller = ScrollController();
  int _cycle = 0;
  String _measuredText = '';
  double _measuredWidth = -1;
  bool _scrolling = false;

  @override
  void dispose() {
    _cycle++;
    _scroller.dispose();
    super.dispose();
  }

  bool get _canScroll => _scroller.hasClients;

  double _naturalWidth(BuildContext context) {
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  void _rewind() {
    if (!_canScroll) return;
    _scroller.jumpTo(0);
  }

  /// 结束当前滚动循环，并让下方计划中的循环失效。
  void _stopCycle() {
    _cycle++;
    _scrolling = false;
    _rewind();
  }

  void _queueCycle() {
    final token = ++_cycle;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _cycle != token || !_canScroll) return;
      _scroller.jumpTo(0);
      unawaited(_runCycle(token));
    });
  }

  Future<void> _runCycle(int token) async {
    _scrolling = true;
    try {
      await Future<void>.delayed(_leadIn);
      while (mounted && _cycle == token && _canScroll) {
        final distance = _scroller.position.maxScrollExtent;
        if (distance <= 0) break;
        await _scroller.animateTo(
          distance,
          duration: Duration(milliseconds: distance.round() * 28),
          curve: Curves.linear,
        );
        if (!mounted || _cycle != token || !_canScroll) return;
        await Future<void>.delayed(_tailHold);
        if (!mounted || _cycle != token || !_canScroll) return;
        _scroller.jumpTo(0);
        await Future<void>.delayed(_rewindHold);
      }
    } finally {
      if (mounted && _cycle == token) _scrolling = false;
    }
  }

  Widget _plainText() {
    return Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        if (available <= 0) return _plainText();

        final naturalWidth = _naturalWidth(context);
        final textChanged = _measuredText != widget.text;
        final widthChanged = (_measuredWidth - available).abs() > 0.5;
        final overflowed = naturalWidth > available + 2;

        _measuredText = widget.text;
        _measuredWidth = available;

        if (!overflowed) {
          if (_scrolling || textChanged || widthChanged) _stopCycle();
          return _plainText();
        }

        final layoutChanged = textChanged || widthChanged;
        if (layoutChanged) {
          _rewind();
          if (!_scrolling) _queueCycle();
        }

        return ClipRect(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            controller: _scroller,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.visible,
              softWrap: false,
              style: widget.style,
            ),
          ),
        );
      },
    );
  }
}
