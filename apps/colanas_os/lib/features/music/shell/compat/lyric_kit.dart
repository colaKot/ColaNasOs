/// 歌词解析与渲染的核心模型（纯 Dart + Flutter 绘制）。
///
/// 对外提供 `LyricModel` / `LyricLine` / `LyricWord` / `LrcParser` /
/// `LyricController` / `LyricStyle` / `LyricStyles` / `FadeRange` / `LyricView`
/// 这组类型，供歌词页与逐字歌词视图复用。
///
/// 解析约定：
/// - `LrcParser.extractLine` 只认**行首**的时间标签，正文里的 `[xx:yy]` 不当时间；
/// - 一行多标签（副歌复用）会展开成多行；
/// - `LyricController` 暴露 `progressNotifier` / `activeIndexNotifiter`
///   （后者沿用历史拼写，避免改动既有调用点）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

// ============================================================ 数据模型

/// LRC 单行：可能带多个时间戳（同一句歌词在多个时间点重复）
class LrcLine {
  LrcLine({required this.durations, required this.text});

  final List<Duration> durations;
  final String text;

  @override
  String toString() => 'LrcLine($durations, "$text")';
}

/// 逐字时间轴上的一个片段（增强型 LRC `<mm:ss.xx>` 标签）
class LyricWord {
  LyricWord({required this.text, required this.start, this.end});

  final String text;
  final Duration start;
  final Duration? end;

  Duration get duration =>
      end == null ? const Duration(milliseconds: 450) : end! - start;

  @override
  String toString() => 'LyricWord("$text", $start → $end)';
}

class LyricLine {
  LyricLine({
    required this.start,
    this.end,
    required this.text,
    this.words,
    this.translation,
  });

  final Duration start;
  final Duration? end;
  final String text;
  final List<LyricWord>? words;
  final String? translation;

  Duration get duration =>
      end == null ? const Duration(seconds: 3) : end! - start;

  bool get hasTranslation => (translation ?? '').trim().isNotEmpty;

  @override
  String toString() => 'LyricLine($start, "$text")';
}

class LyricModel {
  LyricModel({
    this.tags = const <String, String>{},
    this.lines = const <LyricLine>[],
  });

  /// `[ti:歌名]` 之类的元信息
  final Map<String, String> tags;
  final List<LyricLine> lines;

  bool get isEmpty => lines.isEmpty;

  @override
  String toString() => 'LyricModel(${lines.length} lines)';
}

// ============================================================ LRC 解析

class LrcParser {
  const LrcParser._();

  /// `[mm:ss]` / `[mm:ss.xx]` / `[mm:ss:xx]`
  static final RegExp _timeTag = RegExp(
    r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );

  /// `[ti:xxx]` 这类元标签（标签名以非数字开头）
  static final RegExp _metaTag = RegExp(r'^\[(\D[^:]*):(.*?)\]\s*$');

  /// 解析单行：返回「时间点 + 正文」，没有行首时间标签则返回 null。
  static LrcLine? extractLine(String raw) {
    final matches = _timeTag.allMatches(raw);
    if (matches.isEmpty) return null;
    // 只认行首连续的时间标签：正文里出现的 `[12:34]` 不算
    if (matches.first.start != 0) return null;
    final durations = <Duration>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start != cursor) break;
      durations.add(_toDuration(m));
      cursor = m.end;
    }
    if (durations.isEmpty) return null;
    return LrcLine(durations: durations, text: raw.substring(cursor).trim());
  }

  /// 整段 LRC → [LyricModel]
  static LyricModel parse(String lyric) {
    final tags = <String, String>{};
    final lines = <LyricLine>[];
    for (final rawLine in lyric.split(RegExp(r'\r?\n'))) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) continue;
      final meta = _metaTag.firstMatch(trimmed);
      if (meta != null) {
        tags[meta.group(1)!.trim()] = meta.group(2)!.trim();
        continue;
      }
      final lrcLine = extractLine(trimmed);
      if (lrcLine == null) continue;
      for (final start in lrcLine.durations) {
        lines.add(LyricLine(start: start, text: lrcLine.text));
      }
    }
    lines.sort((a, b) => a.start.compareTo(b.start));
    // 用下一行的起点补 end，滚动 / 进度计算才不会一格一格跳
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].end != null) continue;
      final next = i + 1 < lines.length ? lines[i + 1].start : null;
      lines[i] = LyricLine(
        start: lines[i].start,
        end: next,
        text: lines[i].text,
        words: lines[i].words,
        translation: lines[i].translation,
      );
    }
    return LyricModel(tags: tags, lines: lines);
  }

  static Duration _toDuration(RegExpMatch m) {
    final minutes = int.tryParse(m.group(1) ?? '0') ?? 0;
    final seconds = int.tryParse(m.group(2) ?? '0') ?? 0;
    final fraction = m.group(3) ?? '0';
    final millis = int.tryParse(fraction.padRight(3, '0').substring(0, 3)) ?? 0;
    return Duration(minutes: minutes, seconds: seconds, milliseconds: millis);
  }
}

// ============================================================ 控制器

/// 歌词播放控制器：喂进度、算当前行、回调点行跳转。
class LyricController {
  final ValueNotifier<Duration> progressNotifier = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// 当前高亮行下标；-1 = 还没到第一句
  /// （原库拼写就是 Notifiter，调用方按这个写的，别改）
  final ValueNotifier<int> activeIndexNotifiter = ValueNotifier<int>(-1);

  LyricModel? _model;
  void Function(Duration position)? _onTapLine;

  LyricModel? get model => _model;

  List<LyricLine> get lines => _model?.lines ?? const <LyricLine>[];

  void loadLyricModel(LyricModel model) {
    _model = model;
    _recompute();
  }

  void loadLyric(String lyric) {
    _model = LrcParser.parse(lyric);
    _recompute();
  }

  void setProgress(Duration position) {
    progressNotifier.value = position;
    _recompute();
  }

  void setOnTapLineCallback(void Function(Duration position)? callback) {
    _onTapLine = callback;
  }

  /// 点击某行 → 让播放器 seek 到该行起点
  void seekToLine(int index) {
    final all = lines;
    if (index < 0 || index >= all.length) return;
    _onTapLine?.call(all[index].start);
  }

  /// 当前进度所在的行下标（找不到返回 -1）
  int indexAt(Duration position) {
    final all = lines;
    if (all.isEmpty) return -1;
    if (position < all.first.start) return -1;
    var lo = 0;
    var hi = all.length - 1;
    var found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (all[mid].start <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  void _recompute() {
    final next = indexAt(progressNotifier.value);
    if (next != activeIndexNotifiter.value) {
      activeIndexNotifiter.value = next;
    }
  }

  void dispose() {
    progressNotifier.dispose();
    activeIndexNotifiter.dispose();
  }
}

// ============================================================ 样式

/// 上下渐隐的高度（像素）
class FadeRange {
  const FadeRange({this.top = 0, this.bottom = 0});

  final double top;
  final double bottom;

  @override
  String toString() => 'FadeRange(top: $top, bottom: $bottom)';
}

class LyricStyle {
  const LyricStyle({
    this.textStyle = const TextStyle(fontSize: 16, color: Colors.white70),
    this.activeStyle = const TextStyle(
      fontSize: 18,
      color: Colors.white,
      fontWeight: FontWeight.w600,
    ),
    this.translationStyle = const TextStyle(
      fontSize: 13,
      color: Colors.white54,
    ),
    this.textAlign = TextAlign.left,
    this.contentAlignment = CrossAxisAlignment.start,
    this.highlightAlign = MainAxisAlignment.start,
    this.activeAlignment = MainAxisAlignment.start,
    this.fadeRange,
    this.contentPadding = const EdgeInsets.fromLTRB(0, 64, 10, 20),
    this.activeHighlightColor = Colors.white,
    this.selectedColor,
    this.linePadding = const EdgeInsets.symmetric(vertical: 10),
  });

  final TextStyle textStyle;
  final TextStyle activeStyle;
  final TextStyle translationStyle;
  final TextAlign textAlign;
  final CrossAxisAlignment contentAlignment;
  final MainAxisAlignment highlightAlign;
  final MainAxisAlignment activeAlignment;
  final FadeRange? fadeRange;
  final EdgeInsets contentPadding;
  final Color activeHighlightColor;

  /// 用户手动点选行时的高亮色（未配置时回落到当前行样式）
  final Color? selectedColor;
  final EdgeInsets linePadding;

  LyricStyle copyWith({
    TextStyle? textStyle,
    TextStyle? activeStyle,
    TextStyle? translationStyle,
    TextAlign? textAlign,
    CrossAxisAlignment? contentAlignment,
    MainAxisAlignment? highlightAlign,
    MainAxisAlignment? activeAlignment,
    FadeRange? fadeRange,
    EdgeInsets? contentPadding,
    Color? activeHighlightColor,
    Color? selectedColor,
    EdgeInsets? linePadding,
  }) {
    return LyricStyle(
      textStyle: textStyle ?? this.textStyle,
      activeStyle: activeStyle ?? this.activeStyle,
      translationStyle: translationStyle ?? this.translationStyle,
      textAlign: textAlign ?? this.textAlign,
      contentAlignment: contentAlignment ?? this.contentAlignment,
      highlightAlign: highlightAlign ?? this.highlightAlign,
      activeAlignment: activeAlignment ?? this.activeAlignment,
      fadeRange: fadeRange ?? this.fadeRange,
      contentPadding: contentPadding ?? this.contentPadding,
      activeHighlightColor: activeHighlightColor ?? this.activeHighlightColor,
      selectedColor: selectedColor ?? this.selectedColor,
      linePadding: linePadding ?? this.linePadding,
    );
  }
}

class LyricStyles {
  const LyricStyles._();

  /// 默认预设：深色背景、白字、当前行放大加粗
  static const LyricStyle default1 = LyricStyle();
}

// ============================================================ 视图

/// 普通（非逐字）歌词视图：整行滚动居中，当前行高亮。
///
/// 逐字歌词由 `ColaMusicStageWordLyricView` 单独按 word 时间轴涂色。
class LyricView extends StatefulWidget {
  const LyricView({
    super.key,
    required this.controller,
    required this.style,
    this.width,
    this.height,
  });

  final LyricController controller;
  final LyricStyle style;
  final double? width;
  final double? height;

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  final ScrollController _scroll = ScrollController();
  int _lastIndex = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.activeIndexNotifiter.addListener(_handleActiveChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToActive(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant LyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.activeIndexNotifiter.removeListener(
        _handleActiveChanged,
      );
      widget.controller.activeIndexNotifiter.addListener(_handleActiveChanged);
      _lastIndex = -1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToActive(animate: false);
      });
    }
  }

  @override
  void dispose() {
    widget.controller.activeIndexNotifiter.removeListener(_handleActiveChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _handleActiveChanged() {
    _scrollToActive(animate: true);
  }

  /// 每行高度：按当前行字号留足空间，避免放大后互相压
  double get _lineHeight {
    final active = widget.style.activeStyle.fontSize ?? 18;
    return active * 2.0 + widget.style.linePadding.vertical;
  }

  void _scrollToActive({required bool animate}) {
    if (!mounted || !_scroll.hasClients) return;
    final index = widget.controller.activeIndexNotifiter.value;
    if (index < 0 || index == _lastIndex) return;
    _lastIndex = index;
    final viewport = _scroll.position.viewportDimension;
    final target = index * _lineHeight + _lineHeight / 2 - viewport * 0.32;
    final clamped = target.clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );
    if (animate) {
      unawaited(
        _scroll.animateTo(
          clamped,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      _scroll.jumpTo(clamped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ValueListenableBuilder<int>(
        valueListenable: widget.controller.activeIndexNotifiter,
        builder: (context, activeIndex, _) {
          final lines = widget.controller.lines;
          if (lines.isEmpty) {
            return Padding(
              padding: style.contentPadding,
              child: Text(
                '',
                style: style.textStyle,
                textAlign: style.textAlign,
              ),
            );
          }
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) {
              final fade = style.fadeRange;
              if (fade == null || (fade.top <= 0 && fade.bottom <= 0)) {
                return const LinearGradient(
                  colors: <Color>[Colors.white, Colors.white],
                ).createShader(rect);
              }
              final topStop = (fade.top / rect.height).clamp(0.0, 1.0);
              final bottomStop =
                  1.0 - (fade.bottom / rect.height).clamp(0.0, 1.0);
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const <Color>[
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: <double>[0.0, topStop, bottomStop, 1.0],
              ).createShader(rect);
            },
            child: ListView.builder(
              controller: _scroll,
              padding: style.contentPadding,
              itemExtent: _lineHeight,
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final line = lines[index];
                final isActive = index == activeIndex;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.controller.seekToLine(index),
                  child: Align(
                    alignment: style.textAlign == TextAlign.center
                        ? Alignment.center
                        : Alignment.centerLeft,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: style.contentAlignment,
                      children: <Widget>[
                        Text(
                          line.text,
                          textAlign: style.textAlign,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: isActive
                              ? style.activeStyle.copyWith(
                                  color:
                                      style.activeStyle.color ??
                                      style.activeHighlightColor,
                                )
                              : style.textStyle,
                        ),
                        if (line.hasTranslation)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              line.translation!,
                              textAlign: style.textAlign,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: style.translationStyle,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
