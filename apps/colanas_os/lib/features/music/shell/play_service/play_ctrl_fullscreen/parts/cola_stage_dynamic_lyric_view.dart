import 'dart:async';

import 'package:flutter/material.dart';

import '../../../compat/lyric_kit.dart';

/// 单个字在当前进度下的高亮比例，取值 [0, 1]。
double resolveStageWordHighlight({
  required Duration progress,
  required Duration start,
  required Duration? end,
  required Duration? nextStart,
}) {
  final resolvedEnd =
      end ?? nextStart ?? start + const Duration(milliseconds: 450);
  if (progress < start) return 0;
  if (resolvedEnd <= start) return 1;
  if (progress >= resolvedEnd) return 1;
  final elapsed = progress.inMilliseconds - start.inMilliseconds;
  final span = resolvedEnd.inMilliseconds - start.inMilliseconds;
  return Curves.easeOut.transform((elapsed / span).clamp(0, 1));
}

/// 逐字歌词视图：跟随播放进度逐字染色，并自动把当前行滚到可见位置。
class ColaMusicStageWordLyricView extends StatefulWidget {
  const ColaMusicStageWordLyricView({
    required this.style,
    required this.onSeekTo,
    required this.model,
    super.key,
    required this.controller,
    required this.centerMode,
  });

  final LyricStyle style;
  final LyricModel model;
  final LyricController controller;
  final bool centerMode;
  final Future<void> Function(Duration position) onSeekTo;

  @override
  State<ColaMusicStageWordLyricView> createState() =>
      _ColaMusicStageWordLyricViewState();
}

class _ColaMusicStageWordLyricViewState
    extends State<ColaMusicStageWordLyricView> {
  late List<GlobalKey> _anchors;
  int _lastScrolledTo = -1;

  List<GlobalKey> _newAnchors() => List<GlobalKey>.generate(
    widget.model.lines.length,
    (_) => GlobalKey(),
    growable: false,
  );

  @override
  void initState() {
    super.initState();
    _anchors = _newAnchors();
    widget.controller.activeIndexNotifiter.addListener(_onActiveLineChanged);
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(covariant ColaMusicStageWordLyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model == widget.model) return;
    _lastScrolledTo = -1;
    _anchors = _newAnchors();
    _scheduleReveal();
  }

  @override
  void dispose() {
    widget.controller.activeIndexNotifiter.removeListener(_onActiveLineChanged);
    super.dispose();
  }

  void _scheduleReveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    _revealActiveLine();
  });

  void _onActiveLineChanged() => _revealActiveLine();

  void _revealActiveLine() {
    final index = widget.controller.activeIndexNotifiter.value;
    if (!mounted || index < 0 || index >= _anchors.length) return;
    if (_lastScrolledTo == index) return;
    final target = _anchors[index].currentContext;
    if (target == null) return;
    _lastScrolledTo = index;
    unawaited(
      Scrollable.ensureVisible(
        target,
        alignment: 0.32,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.controller.progressNotifier,
      builder: (context, progress, _) {
        return ValueListenableBuilder<int>(
          valueListenable: widget.controller.activeIndexNotifiter,
          builder: (context, activeIndex, _) =>
              _lyricBody(progress, activeIndex),
        );
      },
    );
  }

  Widget _lyricBody(Duration progress, int activeIndex) {
    final lines = widget.model.lines;
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(0, 64, widget.centerMode ? 0 : 10, 20),
        child: Column(
          crossAxisAlignment: widget.centerMode
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: <Widget>[
            for (var i = 0; i < lines.length; i++)
              KeyedSubtree(
                key: _anchors[i],
                child: _LyricLineTile(
                  style: widget.style,
                  progress: progress,
                  onSeekTo: widget.onSeekTo,
                  line: lines[i],
                  centered: widget.centerMode,
                  active: i == activeIndex,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单行歌词：点击跳转、译文、逐字高亮都收在这里。
class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    required this.style,
    required this.progress,
    required this.onSeekTo,
    required this.line,
    required this.centered,
    required this.active,
  });

  final LyricStyle style;
  final Duration progress;
  final LyricLine line;
  final bool centered;
  final bool active;
  final Future<void> Function(Duration position) onSeekTo;

  TextAlign get _align => centered ? TextAlign.center : TextAlign.left;

  CrossAxisAlignment get _axis =>
      centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => unawaited(onSeekTo(line.start)),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
        child: Column(
          crossAxisAlignment: _axis,
          children: <Widget>[
            AnimatedOpacity(
              opacity: active ? 1 : 0.9,
              duration: const Duration(milliseconds: 160),
              child: _lineContent(),
            ),
            if ((line.translation ?? '').trim().isNotEmpty) _translation(),
          ],
        ),
      ),
    );
  }

  Widget _lineContent() {
    final words = line.words;
    if (!active || words == null || words.isEmpty) {
      return Text(
        line.text,
        textAlign: _align,
        style: active ? style.activeStyle : style.textStyle,
      );
    }
    return _WordHighlightedText(
      words: words,
      progress: progress,
      baseStyle: style.textStyle,
      align: _align,
      activeStyle: style.activeStyle,
    );
  }

  Widget _translation() {
    final original = style.translationStyle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 0),
      child: Text(
        line.translation!,
        textAlign: _align,
        style: original.copyWith(
          color: active
              ? original.color
              : original.color?.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class _WordHighlightedText extends StatelessWidget {
  const _WordHighlightedText({
    required this.words,
    required this.progress,
    required this.baseStyle,
    required this.align,
    required this.activeStyle,
  });

  final List<LyricWord> words;
  final Duration progress;
  final TextStyle baseStyle;
  final TextAlign align;
  final TextStyle activeStyle;

  @override
  Widget build(BuildContext context) =>
      Text.rich(TextSpan(children: _spans()), textAlign: align);

  List<InlineSpan> _spans() {
    final highlight = activeStyle.color ?? Colors.white;
    final dimmed =
        activeStyle.color?.withValues(alpha: 0.36) ??
        baseStyle.color?.withValues(alpha: 0.36) ??
        Colors.white.withValues(alpha: 0.36);

    return <InlineSpan>[
      for (var i = 0; i < words.length; i++)
        TextSpan(
          text: words[i].text,
          style: activeStyle.copyWith(
            color: _colorFor(words[i], i, dimmed, highlight),
          ),
        ),
    ];
  }

  Color? _colorFor(LyricWord word, int index, Color dimmed, Color highlight) {
    final nextAt = index + 1 < words.length ? words[index + 1].start : null;
    final ratio = resolveStageWordHighlight(
      start: word.start,
      progress: progress,
      nextStart: nextAt,
      end: word.end,
    );
    return Color.lerp(dimmed, highlight, ratio);
  }
}
