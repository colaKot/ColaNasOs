import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

void _loadZh() {
  final file = File('../nas_core/lib/l10n/zh-CN.json');
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final messages =
      (json['messages'] as Map).map((k, v) => MapEntry(k.toString(), '$v'));
  I18n.instance.useForTest('zh-CN', messages);
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(_loadZh);

  testWidgets('受限能力：提示文案带能力名与补充说明', (tester) async {
    await tester.pumpWidget(
      _wrap(
        NasCapabilityNotice(
          capabilityName: '文件管理',
          level: CapabilityLevel.limited,
          hint: '浏览器端受沙箱限制',
        ),
      ),
    );

    expect(find.text('文件管理在当前端为受限能力，部分操作不可用'), findsOneWidget);
    expect(find.text('浏览器端受沙箱限制'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.block_rounded), findsNothing);
  });

  testWidgets('不提供的能力：用阻断图标与不提供文案', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const NasCapabilityNotice(
          capabilityName: '终端',
          level: CapabilityLevel.none,
        ),
      ),
    );

    expect(find.text('终端在当前端不提供'), findsOneWidget);
    expect(find.byIcon(Icons.block_rounded), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
  });
}