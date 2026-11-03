/// 音乐均衡器预设（纯函数，便于单测）。
///
/// 桌面端 media_kit 走 libmpv，用 `af` 属性挂 `lavfi` 的 `equalizer` 链；
/// Web 端是 HTML5 `<audio>`，没有音频滤镜能力，因此只在桌面端生效。
class EqualizerPreset {
  const EqualizerPreset({
    required this.id,
    required this.labelKey,
    required this.gains,
  });

  final String id;

  /// i18n 键：`ui.music.032` ~ `ui.music.037`
  final String labelKey;

  /// 8 段增益（dB），依次对应 [frequencies]
  final List<double> gains;
}

/// 固定 8 段，覆盖常见调音区间
const List<int> equalizerFrequencies = [60, 120, 250, 500, 1000, 2000, 4000, 8000];

const List<EqualizerPreset> equalizerPresets = [
  EqualizerPreset(
    id: 'off',
    labelKey: 'ui.music.032',
    gains: [0, 0, 0, 0, 0, 0, 0, 0],
  ),
  EqualizerPreset(
    id: 'pop',
    labelKey: 'ui.music.033',
    gains: [0, 2, 4, 2, 0, -1, -2, -2],
  ),
  EqualizerPreset(
    id: 'rock',
    labelKey: 'ui.music.034',
    gains: [5, 4, 2, 0, -1, 1, 3, 5],
  ),
  EqualizerPreset(
    id: 'jazz',
    labelKey: 'ui.music.035',
    gains: [2, 3, 3, 2, 1, -1, -2, -3],
  ),
  EqualizerPreset(
    id: 'classical',
    labelKey: 'ui.music.036',
    gains: [1, 1, 0, 1, 0, 0, 1, 2],
  ),
  EqualizerPreset(
    id: 'vocal',
    labelKey: 'ui.music.037',
    gains: [-2, -1, 0, 2, 3, 3, 1, -1],
  ),
];

EqualizerPreset? equalizerPresetOf(String? id) {
  if (id == null) return null;
  for (final preset in equalizerPresets) {
    if (preset.id == id) return preset;
  }
  return null;
}

/// mpv `af` 属性值；`off` 返回空串（清空滤镜链）
String audioFilterForEqualizer(String presetId) {
  final preset = equalizerPresetOf(presetId) ?? equalizerPresets.first;
  if (preset.id == 'off') return '';
  final parts = <String>[];
  for (var i = 0; i < equalizerFrequencies.length; i++) {
    final gain = preset.gains[i];
    if (gain == 0) continue;
    parts.add(
      'equalizer=f=${equalizerFrequencies[i]}:t=q:w=1:g=${_formatGain(gain)}',
    );
  }
  if (parts.isEmpty) return '';
  return 'lavfi=[${parts.join(',')}]';
}

String _formatGain(double value) {
  final rounded = value.roundToDouble();
  return rounded == value ? '${rounded.toInt()}' : value.toString();
}
