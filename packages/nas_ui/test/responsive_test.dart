import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

void main() {
  test('窄屏判定为 compact', () {
    expect(layoutFor(390), LayoutMode.compact);
  });

  test('断点：600 / 1024', () {
    expect(layoutFor(599), LayoutMode.compact);
    expect(layoutFor(600), LayoutMode.medium);
    expect(layoutFor(1023), LayoutMode.medium);
    expect(layoutFor(1024), LayoutMode.expanded);
  });

  test('NaN / 非正数兜底为 compact', () {
    expect(layoutFor(double.nan), LayoutMode.compact);
    expect(layoutFor(0), LayoutMode.compact);
    expect(layoutFor(-10), LayoutMode.compact);
  });

  test('双栏与网格列数', () {
    expect(useTwoPane(390), false);
    expect(useTwoPane(800), true);
    expect(gridColumns(390), 2);
    expect(gridColumns(800), 4);
    expect(gridColumns(1400), 6);
  });
}