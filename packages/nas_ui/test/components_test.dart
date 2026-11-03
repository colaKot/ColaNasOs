import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('空态展示标题、说明与动作', (tester) async {
    await tester.pumpWidget(
      _wrap(
        NasEmptyState(
          title: '书架还是空的',
          message: '先绑定一个目录',
          action: FilledButton(onPressed: () {}, child: const Text('去绑定')),
        ),
      ),
    );
    expect(find.text('书架还是空的'), findsOneWidget);
    expect(find.text('先绑定一个目录'), findsOneWidget);
    expect(find.text('去绑定'), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
  });

  testWidgets('错误态点击重试触发回调', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _wrap(NasErrorState(message: '网络不可用', onRetry: () async => retried += 1)),
    );
    expect(find.text('网络不可用'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retried, 1);
  });

  testWidgets('搜索框：输入后出现清除按钮，点击清空', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var cleared = 0;

    await tester.pumpWidget(
      _wrap(
        NasSearchField(
          controller: controller,
          hintText: '搜索书名',
          onClear: () => cleared += 1,
        ),
      ),
    );

    expect(find.byIcon(Icons.clear), findsNothing);
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();
    expect(find.byIcon(Icons.clear), findsOneWidget);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(cleared, 1);
  });

  testWidgets('封面：无地址时用首字占位', (tester) async {
    await tester.pumpWidget(
      _wrap(const SizedBox(width: 100, height: 140, child: NasCoverImage(url: null, fallbackText: '三体'))),
    );
    expect(find.text('三'), findsOneWidget);
  });

  testWidgets('确认框：确定返回 true，取消返回 false', (tester) async {
    Future<bool?> run(String action) async {
      late Future<bool> pending;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () {
                pending = NasConfirmDialog.show(
                  ctx,
                  title: '删除相册',
                  message: '确定删除？',
                  danger: true,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      return pending;
    }

    expect(await run('确定'), true);
    expect(await run('取消'), false);
  });

  testWidgets('骨架网格按列数铺块', (tester) async {
    await tester.pumpWidget(
      _wrap(SizedBox(height: 400, child: NasSkeletonGrid(columns: 3, count: 6))),
    );
    expect(find.byType(NasSkeleton), findsNWidgets(6));
  });
}