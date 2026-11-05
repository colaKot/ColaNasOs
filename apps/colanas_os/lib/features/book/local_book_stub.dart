import 'local_book_types.dart';

/// Web 端没有文件系统：离线解析不可用，阅读仍走服务端。
class LocalBookSource extends LocalBookSourceBase {
  LocalBookSource._(this.toc);

  @override
  final LocalToc toc;

  static Future<LocalBookSource?> open(String path, String format) async =>
      null;

  @override
  Future<LocalPage?> page(int index) async => null;

  @override
  void dispose() {}
}
