import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

void main() {
  test('亮 / 暗两套主题的亮度与表面色不同', () {
    final dark = NasTheme.dark();
    final light = NasTheme.light();

    expect(dark.brightness, Brightness.dark);
    expect(light.brightness, Brightness.light);
    expect(dark.colorScheme.surface, isNot(light.colorScheme.surface));
    // 次要文字色必须随主题变化：写死 tokens 的暗色值会在浅背景上对比不足
    expect(dark.colorScheme.onSurfaceVariant, isNot(light.colorScheme.onSurfaceVariant));
  });

  test('语义色扩展从主题取色（危险色两套主题都可用）', () {
    expect(NasTheme.dark().colorScheme.error, NasTheme.light().colorScheme.error);
    expect(NasTheme.light().colorScheme.onSurfaceVariant.computeLuminance(), lessThan(0.5));
    expect(NasTheme.dark().colorScheme.onSurfaceVariant.computeLuminance(), greaterThan(0.2));
  });
}