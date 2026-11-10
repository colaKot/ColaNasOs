/// 在线歌词的检索、比对与写入。
///
/// 原先这些类型和纯函数都塞在播放控制器的 part 文件里，控制器既管状态又管
/// HTTP 与字符串归一化。这里按「无状态的匹配工具 + 单一接口封装」拆开：
/// 匹配规则只认「文件名包含候选标题 + 时长误差 ≤5 秒」，避免同名不同版本串词。
library;

import '../compat/api_base.dart';
import '../list/models/cola_list_models.dart';

/// 一条在线歌词候选。
class LyricSearchItem {
  const LyricSearchItem({
    required this.id,
    required this.source,
    required this.title,
    required this.album,
    required this.artist,
    required this.durationMs,
    required this.preview,
    required this.lrc,
  });

  final String id;
  final String source;
  final String title;
  final String album;
  final String artist;
  final int durationMs;
  final String preview;
  final String lrc;

  factory LyricSearchItem.fromMap(Map<dynamic, dynamic> map) => LyricSearchItem(
    id: map['id']?.toString() ?? '',
    source: map['source']?.toString() ?? '',
    title: map['title']?.toString() ?? '',
    album: map['album']?.toString() ?? '',
    artist: map['artist']?.toString() ?? '',
    durationMs: int.tryParse(map['duration']?.toString() ?? '') ?? 0,
    preview: map['preview']?.toString() ?? '',
    lrc: map['lrc']?.toString() ?? '',
  );
}

class LyricApiService extends BaseApiService {
  LyricApiService._();

  static final LyricApiService instance = LyricApiService._();

  static const String searchPath = '/api/music/lyric/search';
  static const String writePath = '/api/music/lyric/set';

  Future<List<LyricSearchItem>> search(
    String keyword, {
    bool showLoading = false,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) return const <LyricSearchItem>[];
    final reply = await apiPost<List<dynamic>>(
      searchPath,
      body: <String, dynamic>{'keyword': query},
      showLoading: showLoading,
    );
    if (!reply.success) return const <LyricSearchItem>[];
    return (reply.data ?? const <dynamic>[])
        .whereType<Map>()
        .map((entry) => LyricSearchItem.fromMap(entry))
        .toList();
  }

  Future<bool> write({
    required String musicPath,
    required String lrc,
    bool showLoading = false,
  }) async {
    final path = musicPath.trim();
    final text = lrc.trim();
    if (path.isEmpty || text.isEmpty) return false;
    final reply = await apiPost<Map<String, dynamic>>(
      writePath,
      body: <String, dynamic>{'music_path': path, 'lrc': text},
      showLoading: showLoading,
    );
    return reply.success;
  }
}

/// 去掉目录与扩展名，得到用于比对的文件主干。
String lyricFileStem(String pathOrFile) {
  final input = pathOrFile.trim();
  if (input.isEmpty) return '';
  final slash = input.lastIndexOf('/');
  final backSlash = input.lastIndexOf('\\');
  final separator = slash > backSlash ? slash : backSlash;
  final name = separator >= 0 ? input.substring(separator + 1) : input;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// 只保留中英文与数字，忽略大小写、标点、空格差异。
String normalizeLyricText(String input) {
  final text = input.trim().toLowerCase();
  if (text.isEmpty) return '';
  return text.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '');
}

/// 检索词：标题优先用元数据，缺了就用文件名主干；有艺人才拼艺人。
String buildLyricKeyword(MusicListItem item, {required String filePath}) {
  final title = item.title.trim();
  final artist = item.artist.trim();
  final fallback = lyricFileStem(
    item.filename.trim().isNotEmpty ? item.filename : filePath,
  );
  final chosen = (title.isNotEmpty ? title : fallback).trim();
  if (chosen.isEmpty) return '';
  return artist.isEmpty ? chosen : '$chosen $artist';
}

/// 曲库里的时长单位是秒。
int durationSecondsToMs(int seconds) => seconds <= 0 ? 0 : seconds * 1000;

/// 标题要出现在文件名主干里，且候选时长与播放器时长相差不超过 5 秒。
bool isHighLyricMatch({
  required LyricSearchItem candidate,
  required String fileStemNormalized,
  required int expectedDurationMs,
}) {
  final title = normalizeLyricText(candidate.title);
  if (title.isEmpty || fileStemNormalized.isEmpty) return false;
  final durationClose =
      candidate.durationMs > 0 &&
      (candidate.durationMs - expectedDurationMs).abs() <= 5000;
  return durationClose && fileStemNormalized.contains(title);
}
