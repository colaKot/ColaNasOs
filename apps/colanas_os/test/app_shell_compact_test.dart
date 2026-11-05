import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import 'package:colanas_os/shell/app_nav_shell.dart';

/// 手机端「二级菜单搬到底部」的回归（需求：工作台是首页 + 房子 + 侧栏改底部）。
///
/// 这里挂的是真实的 [AppNavShell]（契约 → tab 的映射逻辑都在里面），
/// 不是单独测组件，所以能钉住三条：
///   1. 窄屏**不再**渲染 `NasSideNav`（竖向二级侧栏消失）；
///   2. 底部 tab 的数量与顺序来自 `contracts/apps.json#nav.mobile.tabs`；
///   3. 点「更多」进的是整页，且侧栏里没进 tab 的项都在里面。
void main() {
  setUpAll(() {
    // 测试不读 assets：只注入需要断言的文案，其余回退成键名（便于精确断言）。
    I18n.instance.useForTest('zh-CN', const {
      'nav.more': '更多',
      'nav.home': '工作台',
      'ui.photo.041': '照片',
    });
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    required double width,
    String appId = 'photo',
    String defaultKey = 'timeline',
    double height = 844,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppNavShell(
            appId: appId,
            defaultKey: defaultKey,
            content: (key) => Center(child: Text('content:$key')),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('390 宽（手机）：没有侧栏、有房子、底部 5 个 tab', (tester) async {
    await pumpShell(tester, width: 390);

    expect(tester.takeException(), isNull);
    // 需求 1：竖向二级侧栏在手机端彻底消失
    expect(find.byType(NasSideNav), findsNothing);
    expect(find.byType(NasBottomTabBar), findsOneWidget);
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);

    final bar = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(bar.items.length, 5);
    // 相册的契约顺序：照片 / 足迹 / 相册 / AI 中心 / 更多
    expect(bar.items.last.label, '更多');
  });

  testWidgets('360 / 320 宽都不溢出', (tester) async {
    for (final width in <double>[360, 320]) {
      await pumpShell(tester, width: width);
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
  });

  testWidgets('点「更多」打开更多页，点条目回到内容', (tester) async {
    await pumpShell(tester, width: 390);
    expect(find.text('content:timeline'), findsOneWidget);

    // 底部最后一个 tab 是「更多」
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();

    // 更多页是整页分组列表（不是半屏 sheet）：先断言容器，
    // 再点首屏第一项（回收站在列表靠下，需要滚动才构建）。
    expect(find.byType(NasMorePage), findsOneWidget);
    expect(find.text('photo.nav.memory'), findsOneWidget);

    await tester.tap(find.text('photo.nav.memory'));
    await tester.pumpAndSettle();
    expect(find.text('content:memory'), findsOneWidget);
    // 从更多进入后，顶栏左侧变成「返回」（子页形态）
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  testWidgets('1280 宽（桌面）：侧栏还在，没有底部 tab', (tester) async {
    await pumpShell(tester, width: 1280, height: 900);

    expect(find.byType(NasSideNav), findsOneWidget);
    expect(find.byType(NasBottomTabBar), findsNothing);
    // 桌面没有 56 手机顶栏（房子只属于手机）
    expect(find.byType(NasMobileAppBar), findsNothing);
  });

  testWidgets('影视：动态库归到「库」tab（aliases 生效）', (tester) async {
    await pumpShell(
      tester,
      width: 390,
      appId: 'video',
      defaultKey: 'lib:7',
    );

    final bar = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    // 选中 lib:7 时，高亮的是「库」tab（索引 0），不是退回最后一个
    expect(bar.currentIndex, 0);
    expect(find.text('content:lib:7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
