import 'dart:typed_data';

/// 本地阅读器数据类型（Web / IO 共用，不依赖 dart:io）。
enum LocalReaderKind { text, image, none }

class LocalTocPage {
  const LocalTocPage({required this.index, required this.title});

  final int index;
  final String title;
}

class LocalToc {
  const LocalToc({required this.kind, required this.pages});

  final LocalReaderKind kind;
  final List<LocalTocPage> pages;

  int get total => pages.length;
}

class LocalPage {
  const LocalPage({
    required this.index,
    required this.title,
    required this.kind,
    this.text,
    this.imageBytes,
    this.mime,
    this.truncated = false,
  });

  final int index;
  final String title;
  final LocalReaderKind kind;
  final String? text;
  final Uint8List? imageBytes;
  final String? mime;
  final bool truncated;
}

abstract class LocalBookSourceBase {
  LocalToc get toc;

  Future<LocalPage?> page(int index);

  void dispose();
}
