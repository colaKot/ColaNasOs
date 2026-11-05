import 'dart:convert';
import 'dart:io';

import 'package:colanas_os/core/settings_store.dart';
import 'package:colanas_os/features/login/login_page.dart';
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
    // 没有保存过地址、且默认地址也连不上 → 停在第一步「填地址」
    await SettingsStore.instance.setString('auth.server', null);

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ColaNasApp());
    // 地址框默认预填当前服务地址 → 启动会静默试连一次；测试环境的
    // HttpClient 被替换成恒 400，连不上就停在「填地址」这一步。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('ColaNasOs'), findsOneWidget);
    expect(find.text('连接到你的 NAS'), findsOneWidget);
    expect(find.text('服务地址'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('登录'), findsNothing);
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
    // 登录是两步：先连服务器。测试里用注入口假装探测成功（已初始化），
    // 这样启动的自动重连会直接进到账号密码这一步。
    LoginPage.debugProbe = (_) async => false;
    addTearDown(() => LoginPage.debugProbe = null);
    await SettingsStore.instance.setString('auth.server', 'http://127.0.0.1:7788');
    addTearDown(() => SettingsStore.instance.setString('auth.server', null));

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ColaNasApp());
    // 自动重连是 unawaited 的：多泵几帧等 setState 切到第二步
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('登录 ColaNasOs'), findsOneWidget);
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