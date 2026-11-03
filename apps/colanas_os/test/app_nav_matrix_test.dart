import 'dart:convert';
import 'dart:io';

import 'package:colanas_os/core/session.dart';
import 'package:colanas_os/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

/// **全部 App × 全部菜单项** 的冒烟遍历。
///
/// 为什么要有：`app-nav.check` 只保证「契约里的菜单项在 `_content()` 里有分支」，
/// 但分支指向的页面是不是一构建就抛异常（越界、空值、断言），静态检查看不出来。
/// 这里把一级导航的每个 App、以及每个 App 左侧栏的每个菜单项都真点一遍：
///
///   - 点完 `pump` 两帧，`tester.takeException()` 必须为 null；
///   - 菜单项必须能从侧栏找到（按 [NasSideNav.keyOf] 的稳定 key）；
///   - 页面里的请求全部指向不可达地址，失败也只允许走到错误态，不允许崩。
///
/// 没有做真实的接口替身：这些页面的失败路径（`NasErrorState`）本身就是需要覆盖的形态。
void main() {
  setUpAll(_loadZh);

  setUp(() {
    // 必然连不上的地址：请求快速失败，页面走错误态，测试不依赖本机内核
    ApiSession.instance.baseUrl = 'http://127.0.0.1:9';
  });

  testWidgets('一级导航：每个 App 都能进入且不抛异常', (tester) async {
    await _pumpShell(tester);

    final apps = AppRegistry.apps.where((a) => a.available).toList();
    expect(apps, isNotEmpty);

    for (final app in apps) {
      final finder = find.byKey(NasSideNav.keyOf('app', app.id));
      expect(finder, findsOneWidget, reason: '一级导航里找不到 ${app.id}');
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: '进入 ${app.id} 时抛异常');
    }

    await _dispose(tester);
  });

  testWidgets('二级导航：每个 App 的每个菜单项都能进入且不抛异常', (tester) async {
    await _pumpShell(tester);

    // 遍历顺序：契约声明顺序（`kAppNavSpecs` 生成自 contracts/apps.json）
    for (final entry in kAppNavSpecs.entries) {
      final appId = entry.key;
      final spec = entry.value;

      final appFinder = find.byKey(NasSideNav.keyOf('app', appId));
      expect(appFinder, findsOneWidget, reason: '一级导航里找不到 $appId');
      await tester.ensureVisible(appFinder);
      await tester.tap(appFinder);
      await _settle(tester);

      // 条件项（`when`，如影视的日本榜单要存在 jp_movie 库才出现）不遍历：
      // 测试里没有库数据，它们本来就不该渲染出来
      final ids = spec.sections
          .expand((s) => s.items)
          .where((item) => !item.isDynamic && item.when == null)
          .map((item) => item.id)
          .toList();
      expect(ids, isNotEmpty, reason: '$appId 的 nav 契约没有可遍历菜单项');

      for (final id in ids) {
        final finder = find.byKey(NasSideNav.keyOf(appId, id));
        expect(finder, findsOneWidget, reason: '$appId 的侧栏里找不到菜单项 $id');
        await tester.ensureVisible(finder);
        await tester.tap(finder, warnIfMissed: false);
        await _settle(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '$appId → $id 渲染时抛异常',
        );
      }
    }

    await _dispose(tester);
  });
}

Future<void> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(const MaterialApp(home: AppShell()));
  await tester.pump();
}

/// 点完一帧再给一帧：页面普遍在 `initState` 里发请求，两帧足够走到骨架/错误态
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
}

/// 卸载整棵树：让所有页面的 `dispose` 跑完，避免「Timer is still pending」
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void _loadZh() {
  final file = File('../../packages/nas_core/lib/l10n/zh-CN.json');
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final messages = (json['messages'] as Map).map(
    (k, v) => MapEntry(k.toString(), '$v'),
  );
  I18n.instance.useForTest('zh-CN', messages);
}
