import 'dart:io';

import 'package:path/path.dart' as p;

import '../../compat/host.dart';
import 'cache_contracts.dart';

/// 音频缓存的「账本」：内存索引 + 磁盘文件的一致性维护。
///
/// 索引以 `CacheKeys.musicAudioCacheIndex` 持久化，每条记录形如
/// `{filename, completed, lastAccessMs}`。所有落盘文件名的拼装、清理、
/// 淘汰都集中在这里，播放门面只问「这个 hash 有没有可用文件」。
class AudioCacheIndex {
  AudioCacheIndex(this._directory);

  /// 惰性取当前缓存目录；`init()` 之前返回 null。
  final Directory? Function() _directory;

  final Map<String, Map<String, dynamic>> _records =
      <String, Map<String, dynamic>>{};

  static const String _keyName = 'filename';
  static const String _keyDone = 'completed';
  static const String _keyAccess = 'lastAccessMs';

  Iterable<String> get keys => _records.keys;

  Map<String, dynamic>? recordOf(String hash) => _records[hash];

  String filenameOf(String hash) =>
      (recordOf(hash)?[_keyName] ?? '').toString().trim();

  bool isCompleted(String hash) => recordOf(hash)?[_keyDone] == true;

  File? completedFile(String hash) {
    final dir = _directory();
    final name = filenameOf(hash);
    if (dir == null || name.isEmpty || !isCompleted(hash)) return null;
    return File(p.join(dir.path, name));
  }

  /// 启动时读回索引，并剔除「标记完成但文件已不在」的条目。
  Future<void> restore() async {
    _records.clear();
    final stored = CacheManager().getJson(CacheKeys.musicAudioCacheIndex);
    if (stored is Map) {
      for (final item in stored.entries) {
        final value = item.value;
        if (value is Map) {
          _records[item.key.toString()] = value.cast<String, dynamic>();
        }
      }
    }
    await _dropStale();
  }

  Future<void> persist() async {
    await CacheManager().setJson(CacheKeys.musicAudioCacheIndex, _records);
  }

  Future<void> mark({
    required String hash,
    required String filename,
    required bool completed,
  }) async {
    final entry = _records.putIfAbsent(hash, () => <String, dynamic>{});
    entry[_keyName] = filename;
    entry[_keyDone] = completed;
    entry[_keyAccess] = DateTime.now().millisecondsSinceEpoch;
    await persist();
  }

  Future<void> forget(String hash) async {
    final removed = _records.remove(hash);
    if (removed == null) return;
    await _eraseFiles(removed[_keyName]?.toString() ?? '');
    await persist();
  }

  Future<void> clear() async {
    _records.clear();
    final dir = _directory();
    if (dir != null) {
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
    await CacheManager().setJson(
      CacheKeys.musicAudioCacheIndex,
      <String, dynamic>{},
    );
  }

  /// 统计只算已完成且文件确实存在的条目，顺手修账本。
  Future<MusicAudioCacheStats> stats() async {
    final dir = _directory();
    if (dir == null) return MusicAudioCacheStats.empty;

    var entries = 0;
    var bytes = 0;
    final stale = <String>[];

    for (final item in _records.entries) {
      if (item.value[_keyDone] != true) continue;
      final name = (item.value[_keyName] ?? '').toString().trim();
      if (name.isEmpty) {
        stale.add(item.key);
        continue;
      }
      final file = File(p.join(dir.path, name));
      if (!await file.exists()) {
        stale.add(item.key);
        continue;
      }
      entries++;
      bytes += await _safeLength(file);
    }

    if (stale.isNotEmpty) {
      stale.forEach(_records.remove);
      await persist();
    }
    return MusicAudioCacheStats(count: entries, totalBytes: bytes);
  }

  /// 按最近访问时间淘汰最旧的条目，直到不超过 [maxItems]。
  Future<void> trimTo(int maxItems) async {
    if (maxItems <= 0) return;
    final done =
        _records.entries
            .where((e) => e.value[_keyDone] == true)
            .toList(growable: false)
          ..sort((a, b) => _accessMs(a.value).compareTo(_accessMs(b.value)));

    final excess = done.length - maxItems;
    if (excess <= 0) return;

    for (final item in done.take(excess)) {
      await _eraseFiles((item.value[_keyName] ?? '').toString());
      _records.remove(item.key);
    }
    await persist();
  }

  Future<void> _dropStale() async {
    final dir = _directory();
    if (dir == null) return;
    final stale = <String>[];
    for (final item in _records.entries) {
      if (item.value[_keyDone] != true) continue;
      final name = (item.value[_keyName] ?? '').toString().trim();
      if (name.isEmpty || !await File(p.join(dir.path, name)).exists()) {
        stale.add(item.key);
      }
    }
    if (stale.isEmpty) return;
    stale.forEach(_records.remove);
    await persist();
  }

  Future<void> _eraseFiles(String name) async {
    final dir = _directory();
    if (dir == null || name.trim().isEmpty) return;
    for (final candidate in <String>[name, '$name.part']) {
      final file = File(p.join(dir.path, candidate));
      if (!await file.exists()) continue;
      try {
        await file.delete();
      } catch (_) {
        // 文件可能被播放器占用，下次统计时再修账本。
      }
    }
  }

  static int _accessMs(Map<String, dynamic> record) =>
      (record[_keyAccess] as num?)?.toInt() ?? 0;

  static Future<int> _safeLength(File file) async {
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }
}
