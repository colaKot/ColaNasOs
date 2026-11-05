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
    this.copy = false,
    this.bitrates = const <String, int>{},
  });

  final String key;
  final String label;
  final int height;

  /// H.264 下的码率（兼容旧调用方：下拉框不带编码时显示这个）。
  final int videoBitrateKbps;

  /// 原画 = 不转码，直接复制流。此时码率无意义。
  final bool copy;

  /// 各编码下的目标码率（kbps）。H.265 / AV1 同画质更省流量。
  final Map<String, int> bitrates;

  /// 该编码下这一档的码率；认不出的编码回落到 H.264 的值。
  int bitrateFor(String codecKey) => bitrates[codecKey] ?? videoBitrateKbps;

  /// 供下拉框展示的码率短标签（如 2.8 Mbps）；原画返回「不转码」。
  String bitrateLabelFor(String codecKey) {
    if (copy) return '不转码';
    final kbps = bitrateFor(codecKey);
    if (kbps <= 0) return '';
    final mbps = kbps / 1000;
    return '${mbps.toStringAsFixed(mbps >= 10 ? 0 : 1)} Mbps';
  }

  /// 兼容旧调用：按 H.264 显示。
  String get bitrateLabel => bitrateLabelFor('h264');
}

/// 输出编码：h264 → MPEG-TS；h265 / av1 → fMP4（带 EXT-X-MAP）。
class PlayCodec {
  const PlayCodec({
    required this.key,
    required this.label,
    required this.container,
    this.bitrateFactor = 1,
  });

  final String key;
  final String label;

  /// mpegts / fmp4（与服务端实际封装一致）。
  final String container;

  /// 同画质下相对 H.264 的码率系数（1.0 / 0.6 / 0.5），用于估算流量。
  final double bitrateFactor;
}

const List<PlayQualityPreset> playQualityPresets = <PlayQualityPreset>[
    PlayQualityPreset(
      key: 'original',
      label: '原画',
      height: 0,
      videoBitrateKbps: 0,
      copy: true,
      bitrates: <String, int>{
        'h264': 0,
        'h265': 0,
        'av1': 0,
      },
    ),
    PlayQualityPreset(
      key: '2160p_15m',
      label: '4K',
      height: 2160,
      videoBitrateKbps: 15000,
      copy: false,
      bitrates: <String, int>{
        'h264': 15000,
        'h265': 9000,
        'av1': 7000,
      },
    ),
    PlayQualityPreset(
      key: '1440p_10m',
      label: '2K 10M',
      height: 1440,
      videoBitrateKbps: 10000,
      copy: false,
      bitrates: <String, int>{
        'h264': 10000,
        'h265': 6000,
        'av1': 4800,
      },
    ),
    PlayQualityPreset(
      key: '1440p_8m',
      label: '2K 8M',
      height: 1440,
      videoBitrateKbps: 8000,
      copy: false,
      bitrates: <String, int>{
        'h264': 8000,
        'h265': 4800,
        'av1': 3800,
      },
    ),
    PlayQualityPreset(
      key: '1440p_5m',
      label: '2K 5M',
      height: 1440,
      videoBitrateKbps: 5000,
      copy: false,
      bitrates: <String, int>{
        'h264': 5000,
        'h265': 3000,
        'av1': 2400,
      },
    ),
    PlayQualityPreset(
      key: '1440p_3m',
      label: '2K 3M',
      height: 1440,
      videoBitrateKbps: 3000,
      copy: false,
      bitrates: <String, int>{
        'h264': 3000,
        'h265': 1800,
        'av1': 1400,
      },
    ),
    PlayQualityPreset(
      key: '1080p_8m',
      label: '1080P 8M',
      height: 1080,
      videoBitrateKbps: 8000,
      copy: false,
      bitrates: <String, int>{
        'h264': 8000,
        'h265': 4800,
        'av1': 3800,
      },
    ),
    PlayQualityPreset(
      key: '1080p_5m',
      label: '1080P 5M',
      height: 1080,
      videoBitrateKbps: 5000,
      copy: false,
      bitrates: <String, int>{
        'h264': 5000,
        'h265': 3000,
        'av1': 2400,
      },
    ),
    PlayQualityPreset(
      key: '1080p_3m',
      label: '1080P 3M',
      height: 1080,
      videoBitrateKbps: 3000,
      copy: false,
      bitrates: <String, int>{
        'h264': 3000,
        'h265': 1800,
        'av1': 1400,
      },
    ),
    PlayQualityPreset(
      key: '1080p_2m',
      label: '1080P 2M',
      height: 1080,
      videoBitrateKbps: 2000,
      copy: false,
      bitrates: <String, int>{
        'h264': 2000,
        'h265': 1200,
        'av1': 900,
      },
    ),
    PlayQualityPreset(
      key: '720p_3m',
      label: '720P 3M',
      height: 720,
      videoBitrateKbps: 3000,
      copy: false,
      bitrates: <String, int>{
        'h264': 3000,
        'h265': 1800,
        'av1': 1400,
      },
    ),
    PlayQualityPreset(
      key: '720p_2m',
      label: '720P 2M',
      height: 720,
      videoBitrateKbps: 2000,
      copy: false,
      bitrates: <String, int>{
        'h264': 2000,
        'h265': 1200,
        'av1': 900,
      },
    ),
    PlayQualityPreset(
      key: '720p_1m',
      label: '720P 1M',
      height: 720,
      videoBitrateKbps: 1000,
      copy: false,
      bitrates: <String, int>{
        'h264': 1000,
        'h265': 600,
        'av1': 480,
      },
    ),
    PlayQualityPreset(
      key: '480p_1m',
      label: '480P 1M',
      height: 480,
      videoBitrateKbps: 1000,
      copy: false,
      bitrates: <String, int>{
        'h264': 1000,
        'h265': 600,
        'av1': 480,
      },
    ),
];

const List<PlayCodec> playCodecs = <PlayCodec>[
    PlayCodec(
      key: 'h264',
      label: 'H.264 / AVC',
      container: 'mpegts',
      bitrateFactor: 1,
    ),
    PlayCodec(
      key: 'h265',
      label: 'H.265 / HEVC',
      container: 'fmp4',
      bitrateFactor: 0.6,
    ),
    PlayCodec(
      key: 'av1',
      label: 'AV1',
      container: 'fmp4',
      bitrateFactor: 0.5,
    ),
];

const String defaultPlayPreset = '1080p_3m';
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
