import '../../../compat/lyric_kit.dart';

/// 一行 LRC 拆出的时间锚点 + 原始正文。
class _TimedText {
  const _TimedText(this.at, this.body);

  final Duration at;
  final String body;
}

/// 把带 `<mm:ss.xx>` 标记的正文切成逐字片段。
class _WordSplitter {
  const _WordSplitter._();

  static final RegExp marker = RegExp(r'<(\d{1,}:\d{2})(?:\.(\d{1,3}))?>');

  static LyricLine assemble(_TimedText draft) {
    final hits = marker.allMatches(draft.body).toList(growable: false);
    if (hits.isEmpty) {
      return LyricLine(start: draft.at, text: draft.body);
    }

    final plain = StringBuffer();
    final words = <LyricWord>[];
    var segmentAt = draft.at;
    var cursor = 0;

    for (final hit in hits) {
      final nextAt = _stamp(hit.group(1)!, hit.group(2));
      if (hit.start > cursor) {
        _append(
          words,
          plain,
          draft.body.substring(cursor, hit.start),
          segmentAt,
          nextAt,
        );
      }
      segmentAt = nextAt;
      cursor = hit.end;
    }

    if (cursor < draft.body.length) {
      _append(words, plain, draft.body.substring(cursor), segmentAt, null);
    }

    final text = plain.isEmpty
        ? draft.body.replaceAll(marker, '')
        : plain.toString();
    return LyricLine(
      words: words.isEmpty ? null : words,
      text: text,
      start: draft.at,
      end: words.isEmpty ? null : words.last.end,
    );
  }

  static void _append(
    List<LyricWord> words,
    StringBuffer plain,
    String text,
    Duration from,
    Duration? to,
  ) {
    if (text.isEmpty) return;
    plain.write(text);
    words.add(LyricWord(text: text, start: from, end: to));
  }

  static Duration _stamp(String clock, String? fraction) {
    final pair = clock.split(':');
    final seconds = pair.length > 1 ? int.tryParse(pair[1]) ?? 0 : 0;
    final minutes = int.tryParse(pair.first) ?? 0;
    final millis = int.tryParse((fraction ?? '0').padRight(3, '0')) ?? 0;
    return Duration(milliseconds: minutes * 60000 + seconds * 1000 + millis);
  }
}

/// 逐字 LRC 解析器。
///
/// 一次扫描同时完成「元信息收集 / 时间轴展开 / 是否含逐字标记」判断，
/// 再交给 [_WordSplitter] 切词、按同时间戳合并译文。没有逐字标记时返回 null，
/// 交由普通 LRC 解析器处理。
class MusicPlayCtrlFullScreenDynamicLyricParser {
  const MusicPlayCtrlFullScreenDynamicLyricParser._();

  static final RegExp _metadata = RegExp(r'^\[(\D[^:]*):(.*?)\]\s*$');
  static final RegExp _lineBreak = RegExp(r'\r?\n');

  static LyricModel? tryParse(String lyric) {
    final drafts = <_TimedText>[];
    final tags = <String, String>{};
    var hasWordMarkers = false;

    for (final raw in lyric.split(_lineBreak)) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;

      final meta = _metadata.firstMatch(line.trim());
      if (meta != null) {
        tags[meta.group(1)!.trim()] = meta.group(2)!.trim();
        continue;
      }

      final parsed = LrcParser.extractLine(line);
      if (parsed == null) continue;
      for (final at in parsed.durations) {
        drafts.add(_TimedText(at, parsed.text));
        hasWordMarkers =
            hasWordMarkers || _WordSplitter.marker.hasMatch(parsed.text);
      }
    }

    if (!hasWordMarkers || drafts.isEmpty) return null;
    drafts.sort((a, b) => a.at.compareTo(b.at));

    final lines = drafts.map(_WordSplitter.assemble).toList(growable: false);
    return LyricModel(tags: tags, lines: _withTranslations(lines));
  }

  /// 同一时间戳的第二行视为译文，只合并前两行。
  static List<LyricLine> _withTranslations(List<LyricLine> sorted) {
    final grouped = <Duration, List<LyricLine>>{};
    for (final line in sorted) {
      grouped.putIfAbsent(line.start, () => <LyricLine>[]).add(line);
    }

    return grouped.values
        .expand<LyricLine>(_expandGroup)
        .toList(growable: false);
  }

  static Iterable<LyricLine> _expandGroup(List<LyricLine> group) sync* {
    final primary = group.first;
    if (group.length == 1) {
      yield primary;
      return;
    }
    final translation = group[1].text.trim();
    yield LyricLine(
      words: primary.words,
      translation: translation.isEmpty ? null : translation,
      text: primary.text,
      start: primary.start,
      end: primary.end,
    );
  }
}
