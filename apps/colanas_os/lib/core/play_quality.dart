// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/play-quality.json
// regenerate: npm run gen:play-quality

/// 播放画质档位：与 player session 的 `preset` 枚举同源，客户端不再自己列表。
class PlayQualityPreset {
  const PlayQualityPreset({
    required this.key,
    required this.label,
    required this.height,
    required this.videoBitrateKbps,
  });

  final String key;
  final String label;
  final int height;
  final int videoBitrateKbps;

  /// 供下拉框展示的码率短标签（如 2.8 Mbps）。
  String get bitrateLabel {
    final mbps = videoBitrateKbps / 1000;
    return '${mbps.toStringAsFixed(mbps >= 10 ? 0 : 1)} Mbps';
  }
}

/// 输出编码：h264 → MPEG-TS；h265 / av1 → fMP4（带 EXT-X-MAP）。
class PlayCodec {
  const PlayCodec({
    required this.key,
    required this.label,
    required this.container,
  });

  final String key;
  final String label;

  /// mpegts / fmp4（与服务端实际封装一致）。
  final String container;
}

const List<PlayQualityPreset> playQualityPresets = <PlayQualityPreset>[
    PlayQualityPreset(
      key: 'web480',
      label: '480p',
      height: 480,
      videoBitrateKbps: 1400,
    ),
    PlayQualityPreset(
      key: 'web720',
      label: '720p',
      height: 720,
      videoBitrateKbps: 2800,
    ),
    PlayQualityPreset(
      key: 'web1080',
      label: '1080p',
      height: 1080,
      videoBitrateKbps: 5000,
    ),
];

const List<PlayCodec> playCodecs = <PlayCodec>[
    PlayCodec(
      key: 'h264',
      label: 'H.264',
      container: 'mpegts',
    ),
    PlayCodec(
      key: 'h265',
      label: 'H.265',
      container: 'fmp4',
    ),
    PlayCodec(
      key: 'av1',
      label: 'AV1',
      container: 'fmp4',
    ),
];

const String defaultPlayPreset = 'web720';
const String defaultPlayCodec = 'h264';
const int playAudioBitrateKbps = 128;

PlayQualityPreset? playQualityPresetOf(String key) {
  for (final p in playQualityPresets) {
    if (p.key == key) return p;
  }
  return null;
}

PlayCodec? playCodecOf(String key) {
  for (final c in playCodecs) {
    if (c.key == key) return c;
  }
  return null;
}
