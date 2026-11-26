import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';

import 'package:colanas_os/features/settings/mcp_settings_page.dart';

/// 设置 → MCP 页：默认「内容查询」、可切到「工程台」，两套配置各自正确。
void main() {
  setUpAll(() {
    I18n.instance.useForTest('zh-CN', const {
      'settings.mcp.title': 'MCP',
      'settings.mcp.subtitle': '把内容接给 AI IDE',
      'settings.mcp.tabContent': '内容查询',
      'settings.mcp.tabDev': '工程台',
      'settings.mcp.copy': '复制配置',
      'settings.mcp.copied': '已复制',
      'settings.mcp.genToken': '生成令牌',
      'settings.mcp.genTokenHint': '生成只读令牌并填入',
      'settings.mcp.contentHint': '连接本机服务端',
      'settings.mcp.devHint': '在源码仓库里查工程信息',
      'settings.mcp.toolsTitle': '可用工具',
    });
  });

  String configOf(WidgetTester tester) =>
      tester.widget<SelectableText>(find.byType(SelectableText)).data ?? '';

  testWidgets('默认内容查询，可切到工程台', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 2600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: McpSettingsPage()));
    await tester.pumpAndSettle();

    // 两个标签都在
    expect(find.text('内容查询'), findsOneWidget);
    expect(find.text('工程台'), findsOneWidget);

    // 默认内容查询配置：stdio sidecar + token 占位
    final content = configOf(tester);
    expect(content.contains('mcpServers'), isTrue);
    expect(content.contains('sidecars/mcp/main.js'), isTrue);
    expect(content.contains('COLANAS_MCP_TOKEN'), isTrue);
    expect(content.contains('COLANAS_MCP_BASE_URL'), isTrue);
    // 内容查询工具
    expect(find.text('files_list'), findsOneWidget);
    expect(find.text('photo_timeline'), findsOneWidget);

    // 切到工程台
    await tester.tap(find.text('工程台'));
    await tester.pumpAndSettle();

    final dev = configOf(tester);
    expect(dev.contains('tool/mcp-dev/main.js'), isTrue);
    expect(dev.contains('COLANAS_MCP_TOKEN'), isFalse);
    expect(find.text('doc_search'), findsOneWidget);
    expect(find.text('log_query'), findsOneWidget);
    // 工程台不出现生成令牌按钮
    expect(find.text('生成令牌'), findsNothing);
  });
}
