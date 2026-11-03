import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

void main() {
  testWidgets('NasCard 可被方向键遍历，Enter 触发点击', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NasTheme.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NasCard(
                    onTap: () => taps++,
                    child: const SizedBox(height: 56, child: Text('A')),
                  ),
                  const SizedBox(height: 12),
                  NasCard(
                    onTap: () => taps++,
                    child: const SizedBox(height: 56, child: Text('B')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // Tab 进入焦点链 → 第一张卡
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);

    // 方向键下移到第二张卡
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 2);
  });

  testWidgets('TV 确认键（select）也能触发卡片', (tester) async {
    var taps = 0;
    const tvShortcuts = <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: NasTheme.dark(),
        home: Shortcuts(
          shortcuts: tvShortcuts,
          child: Scaffold(
            body: Center(
              child: NasCard(
                onTap: () => taps++,
                child: const SizedBox(height: 56, child: Text('A')),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(taps, 1);
  });
}
