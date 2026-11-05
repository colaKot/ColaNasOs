// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'local_book_types.dart';

/// 客户端本地解析 epub / txt / cbz，离线也能翻页。
///
/// 为什么搬到客户端：服务端 `/book/toc` + `/book/page` 是要联网的，
/// 缓存下载完一本之后断网仍然打不开，等于没离线。
/// 这里只解压当前章 / 当前页，不整包展开；单章文本与单页图片都有上限。
const _maxTextBytes = 8 * 1024 * 1024;
const _maxPageText = 200_000;
const _maxImageBytes = 8 * 1024 * 1024;
const _maxEpubChapters = 2000;
const _maxFileBytes = 256 * 1024 * 1024;

class _TxtChapter {
  const _TxtChapter({
    required this.title,
    required this.start,
    required this.end,
  });

  final String title;
  final int start;
  final int end;
}

class LocalBookSource extends LocalBookSourceBase {
  LocalBookSource._({
    required this.toc,
    Map<String, ArchiveFile>? files,
    String? text,
    List<_TxtChapter>? chapters,
    List<String>? spine,
    Map<String, String>? titles,
    List<String>? images,
  }) : _files = files ?? const {},
       _text = text,
       _chapters = chapters,
       _spine = spine,
       _titles = titles,
       _images = images;

  @override
  final LocalToc toc;

  final Map<String, ArchiveFile> _files;
  final String? _text;
  final List<_TxtChapter>? _chapters;
  final List<String>? _spine;
  final Map<String, String>? _titles;
  final List<String>? _images;

  static Future<LocalBookSource?> open(String path, String format) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final size = await file.length();
    if (size <= 0 || size > _maxFileBytes) return null;
    final ext = format.toLowerCase().trim();
    try {
      if (ext == 'txt') {
        if (size > _maxTextBytes) return null;
        final text = utf8.decode(
          await file.readAsBytes(),
          allowMalformed: true,
        );
        return _fromTxt(text);
      }
      if (ext != 'epub' && ext != 'cbz') return null;
      final bytes = await file.readAsBytes();
      if (ext == 'epub') return _fromEpub(bytes);
      return _fromCbz(bytes);
    } catch (_) {
      return null;
    }
  }

  static LocalBookSource? _fromTxt(String text) {
    final chapters = _splitTxt(text);
    return LocalBookSource._(
      text: text,
      chapters: chapters,
      toc: LocalToc(
        kind: LocalReaderKind.text,
        pages: [
          for (var i = 0; i < chapters.length; i++)
            LocalTocPage(index: i, title: _clip(chapters[i].title, 80)),
        ],
      ),
    );
  }

  static LocalBookSource? _fromEpub(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = {for (final f in archive.files) f.name: f};
    final container = _readArchiveText(files['META-INF/container.xml']);
    final opfPath = RegExp(
      r'''<rootfile\b[^>]*\bfull-path\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(container ?? '')?.group(1);
    if (opfPath == null || opfPath.isEmpty) return null;
    final opf = _readArchiveText(files[opfPath]);
    if (opf == null) return null;

    final items =
        <String, ({String href, String mediaType, String properties})>{};
    for (final m in RegExp(
      r'<item\b[^>]*>',
      caseSensitive: false,
    ).allMatches(opf)) {
      final tag = m.group(0)!;
      final id = _attr(tag, 'id');
      final href = _attr(tag, 'href');
      if (id == null || href == null) continue;
      items[id] = (
        href: href,
        mediaType: _attr(tag, 'media-type') ?? '',
        properties: _attr(tag, 'properties') ?? '',
      );
    }

    final spine = <String>[];
    for (final m in RegExp(
      r'<itemref\b[^>]*>',
      caseSensitive: false,
    ).allMatches(opf)) {
      final idref = _attr(m.group(0)!, 'idref');
      if (idref == null) continue;
      final item = items[idref];
      if (item == null) continue;
      spine.add(_resolveZipPath(opfPath, item.href));
      if (spine.length >= _maxEpubChapters) break;
    }
    if (spine.isEmpty) return null;

    var titles = <String, String>{};
    final navItem = items.values
        .where(
          (i) =>
              RegExp(r'\bnav\b', caseSensitive: false).hasMatch(i.properties) &&
              RegExp(r'\.x?html?$', caseSensitive: false).hasMatch(i.href),
        )
        .firstOrNull;
    if (navItem != null) {
      final navPath = _resolveZipPath(opfPath, navItem.href);
      final nav = _readArchiveText(files[navPath]);
      if (nav != null) titles = _parseNavTitles(nav, navPath);
    }

    return LocalBookSource._(
      files: files,
      spine: spine,
      titles: titles,
      toc: LocalToc(
        kind: LocalReaderKind.text,
        pages: [
          for (var i = 0; i < spine.length; i++)
            LocalTocPage(
              index: i,
              title: titles[spine[i]] ?? _titleFromHref(spine[i], i),
            ),
        ],
      ),
    );
  }

  static LocalBookSource? _fromCbz(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final images =
        archive.files
            .where(
              (f) =>
                  !f.name.startsWith('__MACOSX/') &&
                  !f.name.endsWith('/') &&
                  RegExp(
                    r'\.(jpe?g|png|webp|gif)$',
                    caseSensitive: false,
                  ).hasMatch(f.name),
            )
            .map((f) => f.name)
            .toList()
          ..sort(_naturalCompare);
    if (images.isEmpty) return null;
    final files = {for (final f in archive.files) f.name: f};
    return LocalBookSource._(
      files: files,
      images: images,
      toc: LocalToc(
        kind: LocalReaderKind.image,
        pages: [
          for (var i = 0; i < images.length; i++)
            LocalTocPage(index: i, title: '第 ${i + 1} 页'),
        ],
      ),
    );
  }

  @override
  Future<LocalPage?> page(int index) async {
    if (index < 0 || index >= toc.total) return null;
    final kind = toc.kind;
    if (kind == LocalReaderKind.image) {
      final name = _images![index];
      final file = _files[name];
      if (file == null || file.size > _maxImageBytes) return null;
      final data = file.readBytes();
      if (data == null) return null;
      final ext = name.split('.').last.toLowerCase();
      return LocalPage(
        index: index,
        title: '第 ${index + 1} 页',
        kind: LocalReaderKind.image,
        imageBytes: data,
        mime: _mimeOf(ext),
      );
    }

    final spine = _spine;
    if (spine != null) {
      final href = spine[index];
      final file = _files[href];
      if (file == null) return null;
      final raw = _readArchiveText(file);
      if (raw == null) return null;
      final title = _titles?[href] ?? _titleFromHref(href, index);
      return _textPage(index, title, _htmlToText(raw));
    }

    final text = _text;
    final chapters = _chapters;
    if (text == null || chapters == null) return null;
    final c = chapters[index];
    return _textPage(index, _clip(c.title, 80), text.substring(c.start, c.end));
  }

  static LocalPage _textPage(int index, String title, String raw) {
    final text = raw.trim();
    final truncated = text.length > _maxPageText;
    return LocalPage(
      index: index,
      title: title,
      kind: LocalReaderKind.text,
      text: truncated ? text.substring(0, _maxPageText) : text,
      truncated: truncated,
    );
  }

  @override
  void dispose() {
    // archive 文件内容随 GC 释放，这里不需要显式关闭
  }
}

// ---------------------------------------------------------------- 解析工具

String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);

String? _attr(String tag, String name) {
  final re = RegExp(
    "\\b$name\\s*=\\s*['\"]([^'\"]*)['\"]",
    caseSensitive: false,
  );
  return re.firstMatch(tag)?.group(1);
}

String? _readArchiveText(ArchiveFile? file) {
  if (file == null) return null;
  try {
    final bytes = file.readBytes();
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

String _resolveZipPath(String basePath, String href) {
  final clean = Uri.decodeFull(href.split('#').first);
  final dir = basePath.contains('/')
      ? basePath.substring(0, basePath.lastIndexOf('/'))
      : '';
  final parts = <String>[];
  for (final p in '$dir/$clean'.replaceAll('\\', '/').split('/')) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(p);
    }
  }
  return parts.join('/');
}

Map<String, String> _parseNavTitles(String nav, String navPath) {
  final out = <String, String>{};
  for (final m in RegExp(
    r'''<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>''',
    caseSensitive: false,
  ).allMatches(nav)) {
    final href = m.group(1);
    final inner = m.group(2) ?? '';
    final title = _htmlToText(inner).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (href == null || href.isEmpty || title.isEmpty) continue;
    final resolved = _resolveZipPath(navPath, href);
    out[resolved] = _clip(title, 80);
    out[href.split('#').first] = _clip(title, 80);
  }
  return out;
}

String _titleFromHref(String href, int index) {
  final base = href
      .split('/')
      .last
      .replaceAll(RegExp(r'\.x?html?$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[-_]+'), ' ')
      .trim();
  return base.isNotEmpty && base.length <= 60 ? base : '第 ${index + 1} 节';
}

String _htmlToText(String html) {
  var s = html
      .replaceAll(RegExp(r'<head\b[\s\S]*?</head>', caseSensitive: false), ' ')
      .replaceAll(
        RegExp(r'<script\b[\s\S]*?</script>', caseSensitive: false),
        ' ',
      )
      .replaceAll(
        RegExp(r'<style\b[\s\S]*?</style>', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
      .replaceAll(
        RegExp(
          r'</(p|div|h[1-6]|li|tr|blockquote|section)>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  return _decodeEntities(s)
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _decodeEntities(String s) {
  var out = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final n = int.tryParse(m.group(1)!);
    return n == null ? m.group(0)! : String.fromCharCode(n);
  });
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-f]+);', caseSensitive: false), (
    m,
  ) {
    final n = int.tryParse(m.group(1)!, radix: 16);
    return n == null ? m.group(0)! : String.fromCharCode(n);
  });
  return out.replaceAll('&amp;', '&');
}

final _chapterRe = RegExp(
  r'^\s*(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[章节回卷篇幕](?=\s|$)|Chapter\s+\d+(?=\s|$)|CHAPTER\s+\d+(?=\s|$)|(?:序章|楔子|尾声|后记|番外)(?=\s|$)).*$',
);

List<_TxtChapter> _splitTxt(String text) {
  final chapters = <_TxtChapter>[];
  var offset = 0;
  _TxtChapter? current;

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    final lineStart = offset;
    offset += raw.length + 1;
    if (line.isEmpty || line.length > 60) continue;
    if (!_chapterRe.hasMatch(line)) continue;
    if (current != null) {
      chapters.add(
        _TxtChapter(title: current.title, start: current.start, end: lineStart),
      );
    }
    current = _TxtChapter(title: line, start: lineStart, end: text.length);
  }

  if (current != null) {
    chapters.add(
      _TxtChapter(title: current.title, start: current.start, end: text.length),
    );
  }
  if (chapters.isEmpty) {
    return [_TxtChapter(title: '全文', start: 0, end: text.length)];
  }
  // 首章前有内容 → 前言
  final first = chapters.first;
  if (first.start > 0 && text.substring(0, first.start).trim().isNotEmpty) {
    chapters.insert(0, _TxtChapter(title: '前言', start: 0, end: first.start));
  }
  return chapters;
}

int _naturalCompare(String a, String b) {
  final at = RegExp(r'\d+|\D+')
      .allMatches(a.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  final bt = RegExp(r'\d+|\D+')
      .allMatches(b.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  final n = at.length < bt.length ? at.length : bt.length;
  for (var i = 0; i < n; i++) {
    final x = at[i];
    final y = bt[i];
    final xn = int.tryParse(x);
    final yn = int.tryParse(y);
    final cmp = (xn != null && yn != null) ? xn.compareTo(yn) : x.compareTo(y);
    if (cmp != 0) return cmp;
  }
  return at.length.compareTo(bt.length);
}

String _mimeOf(String ext) {
  switch (ext.toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    default:
      return 'image/jpeg';
  }
}
