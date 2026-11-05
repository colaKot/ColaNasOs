import 'dart:convert';
import 'dart:io';

import 'package:nas_core/nas_core.dart';
import 'package:path_provider/path_provider.dart';

/// 书籍离线缓存（桌面 / 移动端）。
///
/// 为什么要有：阅读地址是服务端流，断网 / 服务端离线就一本都打不开。
/// 缓存把整本书落到本地，配合阅读器优先读本地文件，断网也能看。
///
/// 设计取舍：
/// - 文件按 bookId + 扩展名命名（id 是稳定主键，改名不影响命中）；
/// - 索引 JSON 存在同目录 `.index.json`，记录标题 / 格式 / 大小；
/// - 先写 `.part` 再 rename，失败不留半截文件；
/// - 不自动淘汰，占用由用户在设置里手动清。
class BookCacheEntry {
  const BookCacheEntry({
    required this.id,
    required this.title,
    required this.format,
    required this.path,
    required this.bytes,
  });

  final String id;
  final String title;
  final String format;
  final String path;
  final int bytes;
}

class BookCache {
  BookCache._();

  static final BookCache instance = BookCache._();

  Directory? _dir;
  Map<String, BookCacheEntry> _entries = const {};
  bool _indexed = false;

  bool get supported => true;

  Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}book-offline');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  File _indexFile(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}.index.json');

  Future<void> ensureIndexed() async {
    if (_indexed) return;
    final dir = await _ensureDir();
    final map = <String, BookCacheEntry>{};
    try {
      final raw = await _indexFile(dir).readAsString();
      final data = jsonDecode(raw);
      if (data is Map) {
        for (final entry in data.entries) {
          final v = entry.value;
          if (v is! Map) continue;
          final p = (v['path'] as String?) ?? '';
          if (p.isEmpty) continue;
          final f = File(p);
          if (!await f.exists()) continue;
          map[entry.key as String] = BookCacheEntry(
            id: entry.key as String,
            title: (v['title'] as String?) ?? '',
            format: (v['format'] as String?) ?? '',
            path: p,
            bytes: await f.length(),
          );
        }
      }
    } catch (_) {
      /* 索引坏了就重建：文件仍在，但需要重新下载 */
    }
    _entries = map;
    _indexed = true;
  }

  Future<void> _saveIndex() async {
    final dir = await _ensureDir();
    final data = {
      for (final e in _entries.values)
        e.id: {'title': e.title, 'format': e.format, 'path': e.path},
    };
    try {
      await _indexFile(dir).writeAsString(jsonEncode(data));
    } catch (_) {
      /* 索引写失败不影响文件本身 */
    }
  }

  List<BookCacheEntry> get entries =>
      _entries.values.toList()..sort((a, b) => a.title.compareTo(b.title));

  bool has(String bookId) => _entries.containsKey(bookId);

  String? pathOf(String bookId) => _entries[bookId]?.path;

  Future<int> totalBytes() async {
    var sum = 0;
    for (final e in _entries.values) {
      sum += e.bytes;
    }
    return sum;
  }

  Future<void> clear() async {
    final dir = await _ensureDir();
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.index.json')) continue;
      try {
        await entity.delete();
      } catch (_) {
        /* 忽略单个文件 */
      }
    }
    _entries = const {};
    await _saveIndex();
  }

  Future<void> remove(String bookId) async {
    final entry = _entries[bookId];
    if (entry == null) return;
    try {
      final f = File(entry.path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      /* 忽略 */
    }
    final next = {..._entries}..remove(bookId);
    _entries = next;
    await _saveIndex();
  }

  Future<BookCacheEntry> download({
    required BookItem book,
    required String url,
    required Map<String, String> headers,
  }) async {
    await ensureIndexed();
    final existing = _entries[book.id];
    if (existing != null && await File(existing.path).exists()) return existing;

    final dir = await _ensureDir();
    final safeId = book.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final ext = book.format.isEmpty ? 'bin' : book.format;
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

    final entry = BookCacheEntry(
      id: book.id,
      title: book.title,
      format: ext,
      path: target.path,
      bytes: await target.length(),
    );
    _entries = {..._entries, book.id: entry};
    await _saveIndex();
    return entry;
  }

  /// 用系统默认应用打开本地文件（离线阅读 / 查看）
  Future<bool> openLocal(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
