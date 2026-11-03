import 'dart:convert';
import 'dart:io';

import 'package:colanas_os/shell/app_visuals.dart';
import 'package:flutter_test/flutter_test.dart';

/// 图标名白名单校验。
///
/// 契约里的图标是**字符串**（`contracts/apps.json` 的 `icon` 字段）：写错一个字母不会编译失败，
/// 运行时只是静默兜底成 `Icons.apps`，界面上看不出来。这个测试把两个方向都钉住：
///
///   1. 契约里出现的每个图标名，都必须在 [AppVisuals.icons] 白名单里；
///   2. 白名单里的每个名字，都必须真的被用到（契约或客户端源码），不留死条目。
///
/// 新增图标时的流程：先在 `AppVisuals.icons` 里加一行，再改契约/代码。
void main() {
  // `flutter test` 的工作目录是 apps/colanas_os
  final root = Directory('../..');
  final appsJson = File('${root.path}/contracts/apps.json');

  /// 契约里所有 `icon` 字段（一级导航的 App 图标、二级菜单的分组图标与条目图标）
  Set<String> contractIcons() {
    final spec = jsonDecode(appsJson.readAsStringSync()) as Map<String, dynamic>;
    final names = <String>{};
    for (final app in (spec['apps'] as List).cast<Map<String, dynamic>>()) {
      final icon = app['icon'];
      if (icon is String) names.add(icon);
      final nav = app['nav'] as Map<String, dynamic>?;
      if (nav == null) continue;
      for (final section
          in (nav['sections'] as List? ?? const []).cast<Map<String, dynamic>>()) {
        final sectionIcon = section['icon'];
        if (sectionIcon is String) names.add(sectionIcon);
        for (final item
            in (section['items'] as List? ?? const []).cast<Map<String, dynamic>>()) {
          final itemIcon = item['icon'];
          if (itemIcon is String) names.add(itemIcon);
        }
      }
    }
    return names;
  }

  test('契约里的图标名都在白名单内', () {
    final missing = <String>[];
    for (final name in contractIcons()) {
      if (AppVisuals.iconOrNull(name) == null) missing.add(name);
    }
    expect(
      missing,
      isEmpty,
      reason:
          '这些图标名不在 AppVisuals.icons 里（会静默兜底成 Icons.apps）：'
          '${missing.join(', ')}',
    );
  });

  test('白名单里没有没人用的死条目', () {
    // 只要名字以「带引号的字面量」出现在客户端源码或契约里，就算被用到。
    // app_visuals.dart 自己就是白名单，不能算。
    final haystack = StringBuffer(appsJson.readAsStringSync());
    for (final dir in <String>['${root.path}/apps/colanas_os/lib', '${root.path}/packages']) {
      final rootDir = Directory(dir);
      if (!rootDir.existsSync()) continue;
      for (final entity in rootDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('app_visuals.dart')) continue;
        haystack.write(entity.readAsStringSync());
      }
    }
    final text = haystack.toString();

    final dead = AppVisuals.icons.keys
        .where((name) => !text.contains("'$name'") && !text.contains('"$name"'))
        .toList();
    expect(
      dead,
      isEmpty,
      reason: '白名单里这些图标名没有任何地方在用，删掉它们：${dead.join(', ')}',
    );
  });

  test('影视动态库项的图标名也在白名单内', () {
    // 这三个名字不在契约里（库类型是运行时才知道的），由 video_shell 直接给出
    for (final name in const [
      'live_tv_outlined',
      'local_movies_outlined',
      'movie_outlined',
    ]) {
      expect(AppVisuals.iconOrNull(name), isNotNull, reason: name);
    }
  });

  test('白名单本身不允许重复键（同名不同图标）', () {
    expect(AppVisuals.icons.length, AppVisuals.icons.keys.toSet().length);
  });
}
