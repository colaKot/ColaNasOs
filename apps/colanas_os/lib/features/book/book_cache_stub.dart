import 'package:nas_core/nas_core.dart';

/// Web 端没有可持久化的本地目录：离线缓存不支持。
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

  bool get supported => false;

  Future<void> ensureIndexed() async {}

  List<BookCacheEntry> get entries => const [];

  bool has(String bookId) => false;

  String? pathOf(String bookId) => null;

  Future<int> totalBytes() async => 0;

  Future<void> clear() async {}

  Future<void> remove(String bookId) async {}

  Future<BookCacheEntry?> download({
    required BookItem book,
    required String url,
    required Map<String, String> headers,
  }) async {
    throw UnsupportedError('offline cache is not available on web');
  }

  Future<bool> openLocal(String path) async => false;
}
