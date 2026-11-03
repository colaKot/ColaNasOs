import 'package:flutter_test/flutter_test.dart';

import 'package:colanas_os/features/music/equalizer.dart';

void main() {
  test('关闭预设清空滤镜链', () {
    expect(audioFilterForEqualizer('off'), '');
  });

  test('未知预设按关闭处理', () {
    expect(audioFilterForEqualizer('nope'), '');
  });

  test('流行预设只保留非零段并带 8 段频率', () {
    final af = audioFilterForEqualizer('pop');
    expect(af.startsWith('lavfi=['), true);
    expect(af.contains('f=120:t=q:w=1:g=2'), true);
    expect(af.contains('f=1000'), false);
    expect(af.contains('f=8000:t=q:w=1:g=-2'), true);
  });

  test('预设 id 都能反查，标签键连续', () {
    expect(equalizerPresets.length, 6);
    for (final preset in equalizerPresets) {
      expect(equalizerPresetOf(preset.id)?.id, preset.id);
      expect(preset.gains.length, equalizerFrequencies.length);
    }
  });
}
