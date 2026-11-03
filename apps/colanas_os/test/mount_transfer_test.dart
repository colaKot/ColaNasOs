import 'package:colanas_os/core/mount_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('根目录直接拼文件名', () {
    expect(joinRemotePath('', 'a.txt'), 'a.txt');
    expect(joinRemotePath('/', 'a.txt'), 'a.txt');
  });

  test('子目录保留层级，去掉多余斜杠', () {
    expect(joinRemotePath('docs/2026', 'a.txt'), 'docs/2026/a.txt');
    expect(joinRemotePath('/docs/2026/', '/a.txt'), 'docs/2026/a.txt');
  });

  test('空文件名只返回目录', () {
    expect(joinRemotePath('docs', ''), 'docs');
  });
}