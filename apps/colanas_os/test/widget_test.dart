import 'dart:convert';
import 'dart:io';

import 'package:colanas_os/core/settings_store.dart';
import 'package:colanas_os/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

/// 测试不经过 `runColanasApp()`，所以手动注入 zh-CN 文案（与运行时同一份契约产物）。
void _loadZh() {
  final file = File('../../packages/nas_core/lib/l10n/zh-CN.json');
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final messages = (json['messages'] as Map).map((k, v) => MapEntry(k.toString(), '$v'));
  I18n.instance.useForTest('zh-CN', messages);
}

void main() {
  setUpAll(_loadZh);

  testWidgets('未登录时展示登录页（窄屏）', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ColaNasApp());

    expect(find.text('登录 ColaNasOs'), findsOneWidget);
    expect(find.text('服务地址'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('宽屏同样先登录，且布局判定为 expanded', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ColaNasApp());

    expect(find.text('ColaNasOs'), findsOneWidget);
    expect(layoutFor(1400), LayoutMode.expanded);
  });

  testWidgets('两步验证默认关闭，勾选后才出现验证码输入', (tester) async {
    // 指向必然连不上的地址：探测失败会静默走普通登录页，不依赖本机内核状态
    await SettingsStore.instance.setString('auth.server', 'http://127.0.0.1:1');
    addTearDown(() => SettingsStore.instance.setString('auth.server', null));

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ColaNasApp());
    await tester.pump();

    expect(find.text('下次自动登录'), findsOneWidget);
    expect(find.text('两步验证'), findsOneWidget);
    expect(find.text('两步验证码'), findsNothing);

    await tester.tap(find.text('两步验证'));
    await tester.pump();

    expect(find.text('两步验证码'), findsOneWidget);
  });

  test('断点函数仍可用', () {
    expect(layoutFor(390), LayoutMode.compact);
    expect(layoutFor(800), LayoutMode.medium);
  });
}