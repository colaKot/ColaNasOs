import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

/// 手机外壳（`NasAppScaffold` / `NasBottomTabBar` / `NasMorePage`）的布局回归。
///
/// 手机端全部模块共用这三个组件，所以只要这里不溢出，各模块就不会因为
/// "底部 tab 太多 / 标题太长 / 5 个 tab 挤在 320 宽"而炸掉。
void main() {
  const tabs = <NasTabItem>[
    NasTabItem(id: 'timeline', label: '照片', icon: Icons.photo_library_outlined),
    NasTabItem(id: 'footprint', label: '足迹', icon: Icons.place_outlined),
    NasTabItem(id: 'album', label: '相册', icon: Icons.photo_album_outlined),
    NasTabItem(id: 'ai', label: 'AI', icon: Icons.auto_awesome_outlined),
    NasTabItem(id: '@more', label: '更多', icon: Icons.more_horiz),
  ];

  Widget harness(Widget child, {double width = 360}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 780)),
      child: SizedBox(width: width, height: 780, child: child),
    ),
  );

  testWidgets('360 宽：顶栏有房子、底部 5 个 tab、不溢出', (tester) async {
    await tester.pumpWidget(
      harness(
        NasAppScaffold(
          title: '相册',
          onHome: () {},
          items: tabs,
          selectedId: 'timeline',
          onSelect: (_) {},
          body: const SizedBox.expand(),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    expect(find.byType(NasBottomTabBar), findsOneWidget);
    for (final t in tabs) {
      expect(find.text(t.label), findsWidgets, reason: '缺 tab ${t.id}');
    }
  });

  testWidgets('320 / 360 / 430 宽都不溢出（5 tab 挤最窄）', (tester) async {
    for (final width in <double>[320, 360, 430]) {
      await tester.pumpWidget(
        harness(
          NasAppScaffold(
            title: '一个很长很长的模块标题用来验证省略号',
            onHome: () {},
            items: tabs,
            selectedId: 'album',
            onSelect: (_) {},
            body: const SizedBox.expand(),
          ),
          width: width,
        ),
      );
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
  });

  testWidgets('没有底部 tab 时也占掉底部安全区、不报错', (tester) async {
    await tester.pumpWidget(
      harness(
        NasAppScaffold(
          title: '设置',
          onHome: () {},
          items: const [],
          selectedId: '',
          onSelect: (_) {},
          body: const SizedBox.expand(),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(NasBottomTabBar), findsNothing);
  });

  testWidgets('返回优先于房子（子页形态）', (tester) async {
    await tester.pumpWidget(
      harness(
        NasAppScaffold(
          title: '回收站',
          onHome: () {},
          onBack: () {},
          items: tabs,
          selectedId: 'timeline',
          onSelect: (_) {},
          body: const SizedBox.expand(),
        ),
      ),
    );
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.home_outlined), findsNothing);
  });

  group('NasBottomTabBar.matches', () {
    const bar = NasBottomTabBar(
      items: tabs,
      selectedId: '',
      onSelect: _noop,
      aliases: <String, List<String>>{
        'timeline': <String>['lib'],
      },
    );

    test('精确 id 命中', () {
      expect(bar.matches('timeline', 'timeline'), isTrue);
    });

    test('动态项按前缀归入 tab', () {
      expect(bar.matches('lib', 'lib:3'), isTrue);
      expect(bar.matches('timeline', 'lib:3'), isTrue, reason: 'alias 生效');
      expect(bar.matches('album', 'lib:3'), isFalse);
    });

    test('不相关 id 不命中', () {
      expect(bar.matches('timeline', 'favorites'), isFalse);
    });
  });

  testWidgets('更多页按分组列出条目并可点', (tester) async {
    String? picked;
    await tester.pumpWidget(
      harness(
        NasMorePage(
          title: '更多',
          groups: const [
            NasNavGroup(
              title: '回忆',
              entries: [
                NasNavEntry(id: 'memory', label: '记忆', icon: Icons.auto_stories_outlined),
              ],
            ),
            NasNavGroup(
              title: '设置',
              entries: [
                NasNavEntry(id: 'trash', label: '回收站', icon: Icons.delete_outline),
                NasNavEntry(id: 'source', label: '相册来源', icon: Icons.folder_outlined),
              ],
            ),
          ],
          onSelect: (id) => picked = id,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('记忆'), findsOneWidget);
    expect(find.text('回收站'), findsOneWidget);
    await tester.tap(find.text('回收站'));
    expect(picked, 'trash');
  });

  group('多选态工具条', () {
    testWidgets('bulkBar 非空时顶掉底部 tab', (tester) async {
      await tester.pumpWidget(
        harness(
          NasAppScaffold(
            title: '相册',
            onHome: () {},
            items: tabs,
            selectedId: 'timeline',
            onSelect: (_) {},
            bulkBar: const NasBulkBar(
              spec: NasBulkSpec(
                title: '已选 2 项',
                actions: [
                  NasBulkAction(
                    icon: Icons.delete_outline,
                    tooltip: '删除',
                    onPressed: _noopAction,
                  ),
                ],
              ),
            ),
            body: const SizedBox.expand(),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(NasBottomTabBar), findsNothing);
      expect(find.byType(NasBulkBar), findsOneWidget);
      expect(find.text('已选 2 项'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('动作禁用时点了不触发', (tester) async {
      var hits = 0;
      await tester.pumpWidget(
        harness(
          NasAppScaffold(
            title: '相册',
            onHome: () {},
            items: tabs,
            selectedId: 'timeline',
            onSelect: (_) {},
            bulkBar: NasBulkBar(
              spec: NasBulkSpec(
                title: '已选 0 项',
                actions: [
                  NasBulkAction(
                    icon: Icons.delete_outline,
                    tooltip: '删除',
                    enabled: false,
                    onPressed: () => hits++,
                  ),
                ],
              ),
            ),
            body: const SizedBox.expand(),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.delete_outline));
      expect(hits, 0);
    });

    test('同内容的声明不重复通知（防止 publish→rebuild→publish 自激）', () {
      final ctl = NasBulkController();
      var notified = 0;
      ctl.addListener(() => notified++);
      NasBulkSpec spec() => const NasBulkSpec(
        title: '已选 1 项',
        actions: [
          NasBulkAction(
            icon: Icons.delete_outline,
            tooltip: '删除',
            onPressed: _noopAction,
          ),
        ],
      );
      ctl.show(spec());
      ctl.show(spec());
      expect(notified, 1);
      ctl.hide();
      ctl.hide();
      expect(notified, 2);
    });
  });
}

void _noop(String _) {}

/// 无参空动作（顶层函数才能当 const 参数用）
void _noopAction() {}
