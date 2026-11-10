import 'package:colanas_os/shell/shell_back.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 顶栏「返回上一层」的统一通道：栈语义 + 按 App 隔离 + 页面销毁自动注销。
/// 2026-11-06 之前的版本一个 appId 只能有一个 handler，外壳与页面会互相覆盖。
void main() {
  setUp(() {
    ShellBack.clear('test');
    ShellBack.clear('other');
  });

  test('栈：后注册的优先，remove 精确注销，按 appId 隔离', () {
    var hits = 0;
    final a = ShellBack.push('test', () => hits = 1);
    final b = ShellBack.push('test', () => hits = 2);
    expect(ShellBack.depth('test'), 2);
    ShellBack.handlerFor('test')!.call();
    expect(hits, 2);

    ShellBack.remove('test', a); // 删栈底不该影响栈顶
    expect(ShellBack.depth('test'), 1);
    ShellBack.handlerFor('test')!.call();
    expect(hits, 2);

    ShellBack.remove('test', b);
    expect(ShellBack.handlerFor('test'), isNull);

    ShellBack.push('other', () {});
    expect(ShellBack.handlerFor('test'), isNull);
    expect(ShellBack.handlerFor('other'), isNotNull);
  });

  testWidgets('SubPageScope：active 切换自动注册 / 注销，销毁不留悬空回调', (tester) async {
    var back = 0;
    Widget wrap(bool active) => ShellBackScope(
          appId: 'test',
          child: SubPageScope(
            active: active,
            onBack: () => back += 1,
            child: const SizedBox.shrink(),
          ),
        );

    await tester.pumpWidget(wrap(true));
    await tester.pump(); // 注册被推到帧后，避开 build 中 setState
    expect(ShellBack.depth('test'), 1);
    ShellBack.handlerFor('test')!.call();
    expect(back, 1);

    await tester.pumpWidget(wrap(false));
    await tester.pump();
    expect(ShellBack.handlerFor('test'), isNull);

    await tester.pumpWidget(wrap(true));
    await tester.pump();
    expect(ShellBack.depth('test'), 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(ShellBack.handlerFor('test'), isNull);
  });
}
