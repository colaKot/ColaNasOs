import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 音乐离线缓存（桌面 / 移动端）。
///
/// 为什么要有：`/music/stream-url` 是短期令牌 + 每次重新拉流，**离线就一首都没有**。
/// 缓存把「听过的歌」落到本地，飞机上 / 断网时还能放同一批曲子。
///
/// 设计取舍：
///   - 文件按 trackId + 扩展名命名（id 是稳定主键，改名不影响命中）；
///   - 不做过期清理：音乐文件不会"过期"，占满由用户在设置里手动清；
///   - 下载失败不留半截文件（先写 .part 再 rename），否则下次会播到坏文件。
class MusicCache {
  MusicCache._();

  static final MusicCache instance = MusicCache._();

  Directory? _dir;
  Map<String, String> _index = const {};

  Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}music-cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// 首次调用扫描一次已有缓存（避免每次播放都 stat 一遍目录）
  Future<void> ensureIndexed() async {
    if (_index.isNotEmpty) return;
    final dir = await _ensureDir();
    final map = <String, String>{};
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.part')) continue;
      final dot = name.indexOf('.');
      if (dot <= 0) continue;
      map[name.substring(0, dot)] = entity.path;
    }
    _index = map;
  }

  bool get supported => true;

  bool has(String trackId) => _index.containsKey(trackId);

  String? pathOf(String trackId) => _index[trackId];

  /// 已缓存的总字节数（设置页展示用）
  Future<int> totalBytes() async {
    final dir = await _ensureDir();
    var sum = 0;
    await for (final e in dir.list(followLinks: false)) {
      if (e is File) {
        try {
          sum += await e.length();
        } catch (_) {
          /* 忽略单个文件错误 */
        }
      }
    }
    return sum;
  }

  Future<void> clear() async {
    final dir = await _ensureDir();
    await for (final e in dir.list(followLinks: false)) {
      if (e is File) {
        try {
          await e.delete();
        } catch (_) {
          /* 忽略 */
        }
      }
    }
    _index = const {};
  }

  /// 下载一首到缓存。返回本地路径；失败抛错（调用方负责提示）。
  Future<String> download({
    required String trackId,
    required String url,
    required Map<String, String> headers,
    String ext = 'bin',
  }) async {
    final existing = _index[trackId];
    if (existing != null && await File(existing).exists()) return existing;

    final dir = await _ensureDir();
    final safeId = trackId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final target = File('${dir.path}${Platform.pathSeparator}$safeId.$ext');
    final part = File('${target.path}.part');

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      headers.forEach(req.headers.set);
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final sink = part.openWrite();
      await res.pipe(sink);
      await sink.close();
      if (await part.length() < 1024) {
        await part.delete();
        throw const HttpException('empty body');
      }
      await part.rename(target.path);
    } finally {
      client.close(force: true);
    }

    _index = {..._index, trackId: target.path};
    return target.path;
  }

  Future<void> remove(String trackId) async {
    final p = _index[trackId];
    if (p == null) return;
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (_) {
      /* 忽略 */
    }
    final next = {..._index}..remove(trackId);
    _index = next;
  }
}
