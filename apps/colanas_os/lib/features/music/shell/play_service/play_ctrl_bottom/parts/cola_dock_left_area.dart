import 'dart:async';

import 'package:flutter/material.dart';

import '../../../compat/getx.dart';

import '../../../list/models/cola_list_models.dart';
import '../../../shared/music_item_logic.dart';
import '../../../shared/music_playback_logic.dart';
import '../../app_components/cola_disc_cover.dart';

class MusicPlayCtrlBottomLeftArea extends StatelessWidget {
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onOpenFullscreen;
  final MusicListItem item;
  final bool isPlaying;
  final bool favoriteLoading;
  final double downloadProgress;
  final bool downloading;
  final String discAsset;
  final String coverUrl;

  const MusicPlayCtrlBottomLeftArea({
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

  @override
  Widget build(BuildContext context) {
    final localSubtitle = item.displaySubtitleText;
    final localTheme = Theme.of(context);
    final localSubtitleColor = localTheme.colorScheme.onSurface.withValues(
      alpha: 0.6,
    );
    final download = MusicDownloadState(
      downloading: downloading,
      fileHash: '',
      progress: downloadProgress,
    );
    final localProgressText = download.percentText;
    final localCanShowIndexActions = item.canShowIndexActions;

    final localTitle = MusicPlayCtrlBottomMarqueeText(
      text: item.displayTitle,
      style: localTheme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );

    final localMeta = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(width: double.infinity, child: localTitle),
        const SizedBox(height: 6.0),
        Row(
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            if (localCanShowIndexActions && onToggleFavorite != null) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: item.isFavorite ? 'unfavorite'.tr : 'favorites'.tr,
                padding: EdgeInsets.fromLTRB(0, 0, 0, 0),
                onPressed: favoriteLoading ? null : onToggleFavorite,
                icon: favoriteLoading
                    ? SizedBox(
                        width: 18.0,
                        height: 18.0,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.0,
                          color: Colors.red,
                        ),
                      )
                    : Icon(
                        item.isFavorite
                            ? Icons.favorite
                            : Icons.favorite_border,
                        size: 18.0,
                        color: item.isFavorite
                            ? Colors.red
                            : localSubtitleColor,
                      ),
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              const SizedBox(width: 6.0),
            ],
            if (localProgressText.isNotEmpty)
              Text(
                localProgressText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: localTheme.textTheme.bodySmall?.copyWith(
                  color: localSubtitleColor,
                ),
              ),
            if (localProgressText.isNotEmpty) const SizedBox(width: 8.0),
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
    );

    return Row(
      children: <Widget>[
        MusicPlayDiscCover(
          onTap: onOpenFullscreen,
          isPlaying: isPlaying,
          discAsset: discAsset,
          coverUrl: coverUrl,
        ),
        const SizedBox(width: 10.0),
        Expanded(child: localMeta),
      ],
    );
  }
}

class MusicPlayCtrlBottomMarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const MusicPlayCtrlBottomMarqueeText({
    required this.text,
    required this.style,
    super.key,
  });

  @override
  State<MusicPlayCtrlBottomMarqueeText> createState() =>
      _MusicPlayCtrlBottomMarqueeTextState();
}

class _MusicPlayCtrlBottomMarqueeTextState
    extends State<MusicPlayCtrlBottomMarqueeText> {
  final ScrollController _scrollController = ScrollController();
  int _runId = 0;
  String _lastText = '';
  double _lastAvailable = -1;
  bool _running = false;

  @override
  void dispose() {
    _runId++;
    _scrollController.dispose();
    super.dispose();
  }

  double _measureTextWidth(BuildContext context) {
    final localPainter = TextPainter(
      textDirection: Directionality.of(context),
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
    )..layout();
    return localPainter.width;
  }

  Future<void> _start(int runId) async {
    _running = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      while (mounted && _runId == runId && _scrollController.hasClients) {
        final localMax = _scrollController.position.maxScrollExtent;
        if (localMax <= 0) break;
        await _scrollController.animateTo(
          localMax,
          duration: Duration(milliseconds: localMax.round() * 28),
          curve: Curves.linear,
        );
        if (!mounted || _runId != runId || !_scrollController.hasClients) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted || _runId != runId || !_scrollController.hasClients) {
          return;
        }
        _scrollController.jumpTo(0);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      if (mounted && _runId == runId) {
        _running = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        if (available <= 0) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }

        final localTextWidth = _measureTextWidth(context);
        final localTextChanged = _lastText != widget.text;
        final shouldScroll = localTextWidth > available + 2;
        final widthChanged = (_lastAvailable - available).abs() > 0.5;
        _lastText = widget.text;
        _lastAvailable = available;

        if (!shouldScroll) {
          if (_running || localTextChanged || widthChanged) {
            _runId++;
            _running = false;
            if (_scrollController.hasClients) {
              _scrollController.jumpTo(0);
            }
          }
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }

        if ((localTextChanged || widthChanged) &&
            _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }

        if ((localTextChanged || widthChanged) && !_running) {
          final localId = ++_runId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_runId != localId) return;
            if (!_scrollController.hasClients) return;
            _scrollController.jumpTo(0);
            unawaited(_start(localId));
          });
        }

        return ClipRect(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            controller: _scrollController,
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
