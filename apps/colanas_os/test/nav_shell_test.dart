import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

/// 二级侧栏的布局回归。
///
/// 为什么有这个测试：侧栏折叠态（56 宽）下，头部「标题 + 折叠按钮」的可宽度只有约 36px，
/// 而 `IconButton` 默认最小点击区是 48 —— 直接放会 `RenderFlex overflowed by 4.0 pixels`。
/// 这个 bug 曾经在 photo / video / music **三份复制的布局代码里各犯一次**，
/// 修了两处漏一处。现在布局只有 [NasSideNav] 一份实现，这里用遍历把边界钉住：
///
///   - 展开 / 折叠 两种状态
///   - 320 / 360 / 480 宽度（含比默认 56 更窄的极端值）
///   - 有标题 / 无标题、分组标题有无
///
/// 只要有一组溢出，`tester.takeException()` 就会拿到 `FlutterError`，测试直接红。
void main() {
  List<NasNavGroup> groups({bool withTitles = true}) => [
    NasNavGroup(
      title: withTitles ? '影音' : '',
      entries: const [
        NasNavEntry(id: 'a', label: '首页', icon: Icons.home_outlined),
        NasNavEntry(id: 'b', label: '影片库', icon: Icons.movie_outlined),
      ],
    ),
    _secondGroup(withTitles),
  ];

  testWidgets('折叠态不再溢出（曾经 4px）', (tester) async {
    await tester.pumpWidget(
      _harness(
        NasSideNav(
          groups: groups(),
          selectedId: 'a',
          onSelect: (_) {},
          width: 56,
          iconOnly: true,
          title: '影视',
          onToggleCollapsed: () {},
          expandTooltip: '展开',
          collapseTooltip: '收起',
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开态不再溢出', (tester) async {
    await tester.pumpWidget(
      _harness(
        NasSideNav(
          groups: groups(),
          selectedId: 'b',
          onSelect: (_) {},
          width: 128,
          title: '影视',
          onToggleCollapsed: () {},
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏（320 / 360 / 480）折叠态也不溢出', (tester) async {
    addTearDown(tester.view.reset);
    for (final width in <double>[320, 360, 480]) {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpWidget(
        _harness(
          NasSideNav(
            groups: groups(),
            selectedId: 'a',
            onSelect: (_) {},
            width: 56,
            iconOnly: true,
            title: '影视',
            onToggleCollapsed: () {},
          ),
        ),
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'screenWidth=$width 折叠态溢出了',
      );
    }
  });

  testWidgets('无标题 / 无分组标题 / 无折叠按钮 都不崩', (tester) async {
    final cases = <String, Widget>{
      '无标题无按钮': NasSideNav(
        groups: groups(withTitles: false),
        selectedId: 'a',
        onSelect: (_) {},
        iconOnly: true,
      ),
      '有按钮无标题': NasSideNav(
        groups: groups(withTitles: false),
        selectedId: 'a',
        onSelect: (_) {},
        iconOnly: true,
        onToggleCollapsed: () {},
      ),
      '空分组': NasSideNav(
        groups: const [],
        selectedId: '',
        onSelect: (_) {},
        title: '空',
        onToggleCollapsed: () {},
      ),
    };
    for (final entry in cases.entries) {
      await tester.pumpWidget(_harness(entry.value));
      expect(tester.takeException(), isNull, reason: entry.key);
    }
  });

  testWidgets('点击回调带的是对应 entry 的 id', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _harness(
        NasSideNav(
          groups: groups(),
          selectedId: 'a',
          onSelect: (id) => picked = id,
          width: 128,
          title: '影视',
          onToggleCollapsed: () {},
        ),
      ),
    );
    await tester.tap(find.text('影片库'));
    await tester.pump();
    expect(picked, 'b');
  });
}

/// 第二组（单独提出来是因为 const 列表里不能再套复杂字面量）
NasNavGroup _secondGroup(bool withTitles) => NasNavGroup(
  title: withTitles ? '设置' : '',
  entries: const [NasNavEntry(id: 'c', label: '库管理', icon: Icons.tune)],
);

Widget _harness(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Row(
        children: [
          child,
          const Expanded(child: SizedBox()),
        ],
      ),
    ),
  );
}
