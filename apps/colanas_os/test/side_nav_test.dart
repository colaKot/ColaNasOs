import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

Widget _host(String styleId, String selectedId) => MaterialApp(
  theme: NasTheme.styled(styleId: styleId),
  home: Scaffold(
    body: NasSideNav(
      groups: [
        NasNavGroup(
          title: '影音',
          entries: [
            NasNavEntry(
              id: 'video',
              label: '影视',
              icon: Icons.movie_outlined,
            ),
            NasNavEntry(
              id: 'photo',
              label: '相册',
              icon: Icons.photo_library_outlined,
            ),
          ],
        ),
      ],
      selectedId: selectedId,
      onSelect: (_) {},
      footer: const SizedBox(height: 40),
    ),
  ),
);

void main() {
  testWidgets('强调条为 0 的皮肤：侧栏条目可正常绘制且宽度收窄到 128', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_host('aurora', 'video'));
    await tester.pump();

    // 0 宽度 hairline + 圆角曾触发 box_border 断言，整条导航项不绘制
    expect(tester.takeException(), isNull);
    expect(find.text('影视'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);
    expect(tester.getSize(find.byType(NasSideNav)).width, 128);
  });

  testWidgets('强调条为 3 的皮肤：选中态竖条仍然绘制', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_host('fluent', 'photo'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('相册'), findsOneWidget);
    expect(tester.getSize(find.byType(NasSideNav)).width, 128);
  });

  testWidgets('收起态只留图标：56 宽不溢出且不渲染文字', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: NasTheme.styled(styleId: 'aurora'),
        home: Scaffold(
          body: NasSideNav(
            width: 56,
            iconOnly: true,
            groups: [
              NasNavGroup(
                title: '影音',
                entries: [
                  NasNavEntry(
                    id: 'video',
                    label: '影视',
                    icon: Icons.movie_outlined,
                  ),
                ],
              ),
            ],
            selectedId: 'video',
            onSelect: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(NasSideNav)).width, 56);
    // 收起时只留图标：分组标题与条目文字都不应出现
    expect(find.text('影音'), findsNothing);
    expect(find.text('影视'), findsNothing);
  });
}
