import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

void main() {
  testWidgets('应用卡随文字放大自动增高且不溢出', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: NasTheme.dark(),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Center(
              child: SizedBox(
                width: 260,
                child: NasAppCard(
                  icon: Icons.movie_outlined,
                  title: '影视',
                  subtitle: '影音',
                  accent: const [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(NasCard)).height, greaterThan(112));
  });

  testWidgets('常规字号下应用卡仍保持 112 最小高度', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: NasTheme.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              child: NasAppCard(
                icon: Icons.movie_outlined,
                title: '影视',
                subtitle: '影音',
                accent: const [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('影视'), findsOneWidget);
    expect(find.text('影音'), findsOneWidget);
    expect(tester.getSize(find.byType(NasCard)).height, 132);
  });
}