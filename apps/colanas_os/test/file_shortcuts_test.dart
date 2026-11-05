import 'package:flutter_test/flutter_test.dart';

import 'package:colanas_os/core/file_shortcuts.dart';
import 'package:colanas_os/core/settings_store.dart';

/// 文件 App 的「收藏 / 最近访问」是**只存本机**的（SettingsStore）。
///
/// 这里盯三件事：同一个目录不重复出现、顺序是最新在前、超过上限要截断；
/// 以及写进设置后能原样读回来（否则重启客户端收藏就没了）。
void main() {
  final shortcuts = FileShortcuts.instance;

  FileShortcut dir(String path) =>
      FileShortcut(path: path, name: path.split('/').last);

  setUp(() async {
    // 清掉上一条用例留下的键，避免用例之间互相污染
    await SettingsStore.instance.setString('files.favorites', null);
    await SettingsStore.instance.setString('files.recent', null);
    shortcuts.resetForTest();
  });

  test('收藏：加入 / 最新在前 / 再点取消', () async {
    shortcuts.ensureLoaded();
    await shortcuts.toggleFavorite(dir('/a'));
    await shortcuts.toggleFavorite(dir('/b'));
    expect(shortcuts.favorites.map((f) => f.path), ['/b', '/a']);

    // toggle 语义：已收藏就是取消（不是「挪到最前」）
    final stillFav = await shortcuts.toggleFavorite(dir('/a'));
    expect(stillFav, isFalse);
    expect(shortcuts.favorites.map((f) => f.path), ['/b']);

    // 再点回来，并且不会出现两条
    await shortcuts.toggleFavorite(dir('/a'));
    expect(shortcuts.favorites.map((f) => f.path), ['/a', '/b']);
    expect(shortcuts.isFavorite('/a'), isTrue);
    expect(shortcuts.isFavorite('/b'), isTrue);
  });

  test('最近：头插、去重、上限 20、根目录不记', () async {
    shortcuts.ensureLoaded();
    await shortcuts.recordRecent(dir('/'));
    expect(shortcuts.recent, isEmpty);

    for (var i = 0; i < 25; i++) {
      await shortcuts.recordRecent(dir('/d$i'));
    }
    expect(shortcuts.recent.length, FileShortcuts.recentLimit);
    expect(shortcuts.recent.first.path, '/d24');
    expect(
      shortcuts.recent.map((f) => f.path),
      isNot(contains('/d0')),
      reason: '超过上限的应该被挤掉',
    );

    // 再访问老的目录：移到最前，且不多一条
    await shortcuts.recordRecent(dir('/d20'));
    expect(shortcuts.recent.first.path, '/d20');
    expect(
      shortcuts.recent.where((f) => f.path == '/d20').length,
      1,
    );
    // 同一条连续访问不重复写
    final before = shortcuts.recent.length;
    await shortcuts.recordRecent(dir('/d20'));
    expect(shortcuts.recent.length, before);
  });

  test('写进设置后能读回来（重启客户端不丢）', () async {
    shortcuts.ensureLoaded();
    await shortcuts.toggleFavorite(dir('/keep'));
    await shortcuts.recordRecent(dir('/visited'));

    shortcuts.resetForTest();
    shortcuts.ensureLoaded();
    expect(shortcuts.favorites.map((f) => f.path), ['/keep']);
    expect(shortcuts.recent.map((f) => f.path), ['/visited']);
  });

  test('目录没了：forget 同时清掉收藏与最近', () async {
    shortcuts.ensureLoaded();
    await shortcuts.toggleFavorite(dir('/gone'));
    await shortcuts.toggleFavorite(dir('/stay'));
    await shortcuts.recordRecent(dir('/gone'));

    await shortcuts.forget('/gone');
    expect(shortcuts.favorites.map((f) => f.path), ['/stay']);
    expect(shortcuts.recent, isEmpty);
  });

  test('存坏了不炸：坏 JSON 按空列表处理', () async {
    await SettingsStore.instance.setString('files.favorites', '{"not":"a list"}');
    shortcuts.resetForTest();
    shortcuts.ensureLoaded();
    expect(shortcuts.favorites, isEmpty);

    await SettingsStore.instance.setString('files.favorites', 'not json at all');
    shortcuts.resetForTest();
    shortcuts.ensureLoaded();
    expect(shortcuts.favorites, isEmpty);
  });
}
