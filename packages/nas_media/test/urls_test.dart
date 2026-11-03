import 'package:nas_media/nas_media.dart';
import 'package:test/test.dart';

void main() {
  final urls = MediaUrls('http://127.0.0.1:7788');

  test('反斜杠归一化为 POSIX 路径', () {
    expect(urls.file(r'\media\2026\a b.jpg'), contains('path=%2Fmedia%2F2026%2Fa%20b.jpg'));
  });

  test('缩略图带 size', () {
    final u = urls.thumbnail('/media/a.jpg', size: 128);
    expect(u, contains('/api/v1/files/thumb'));
    expect(u, contains('size=128'));
  });

  test('转码默认 web720', () {
    expect(urls.transcode('/v/movie.mp4'), contains('preset=web720'));
  });

  test('相对路径自动补前导斜杠', () {
    expect(urls.file('media/a.jpg'), contains('path=%2Fmedia%2Fa.jpg'));
  });
}