#!/usr/bin/env node
/**
 * 画质档位单一真源生成器（改进 5.6 / 6.4）。
 *
 * 输入：contracts/play-quality.json（画质档位 / 编码 / 默认值 / 音频码率）
 * 输出：
 *   - apps/colanas_os/lib/core/play_quality.dart     客户端档位常量（转码弹窗读它）
 *   - src/modules/videoPlayer/play-quality.generated.ts 服务端 preset / codec 枚举来源
 *   - sidecars/media/play-quality.generated.json      media sidecar 的缩放高度与编码表
 *
 * 目的：档位表只写一处，客户端、路由契约、ffmpeg 参数不再各自硬编码。
 *
 * 用法：
 *   node tool/gen-play-quality.js            生成
 *   node tool/gen-play-quality.js --check    校验磁盘与契约一致
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const src = path.join(root, 'contracts', 'play-quality.json');
const checkOnly = process.argv.includes('--check');

const spec = JSON.parse(fs.readFileSync(src, 'utf-8'));

const dartString = (s) => `'${String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;

function presetDart(p) {
  const b = p.bitrates || {};
  return [
    '    PlayQualityPreset(',
    `      key: ${dartString(p.key)},`,
    `      label: ${dartString(p.label)},`,
    `      height: ${p.height},`,
    `      videoBitrateKbps: ${p.videoBitrateKbps},`,
    `      copy: ${p.copy === true},`,
    `      bitrates: <String, int>{`,
    ...['h264', 'h265', 'av1'].map(
      (c) => `        ${dartString(c)}: ${Number(b[c] ?? 0)},`,
    ),
    '      },',
    '    ),',
  ].join('\n');
}

function codecDart(c) {
  return [
    '    PlayCodec(',
    `      key: ${dartString(c.key)},`,
    `      label: ${dartString(c.label)},`,
    `      container: ${dartString(c.container)},`,
    `      bitrateFactor: ${Number(c.bitrateFactor ?? 1)},`,
    '    ),',
  ].join('\n');
}

function genDart() {
  const lines = [
    '// AUTO-GENERATED. DO NOT EDIT.',
    '// source: contracts/play-quality.json',
    '// regenerate: npm run gen:play-quality',
    '',
    '/// 播放画质档位：与 player session 的 `preset` 枚举同源，客户端不再自己列表。',
    'class PlayQualityPreset {',
    '  const PlayQualityPreset({',
    '    required this.key,',
    '    required this.label,',
    '    required this.height,',
    '    required this.videoBitrateKbps,',
    '    this.copy = false,',
    '    this.bitrates = const <String, int>{},',
    '  });',
    '',
    '  final String key;',
    '  final String label;',
    '  final int height;',
    '',
    '  /// H.264 下的码率（兼容旧调用方：下拉框不带编码时显示这个）。',
    '  final int videoBitrateKbps;',
    '',
    '  /// 原画 = 不转码，直接复制流。此时码率无意义。',
    '  final bool copy;',
    '',
    '  /// 各编码下的目标码率（kbps）。H.265 / AV1 同画质更省流量。',
    '  final Map<String, int> bitrates;',
    '',
    '  /// 该编码下这一档的码率；认不出的编码回落到 H.264 的值。',
    '  int bitrateFor(String codecKey) => bitrates[codecKey] ?? videoBitrateKbps;',
    '',
    '  /// 只有码率的文本（如 `1.4 Mbps`）；原画返回「不转码」。',
    '  String bitrateLabelFor(String codecKey) {',
    "    if (copy) return '不转码';",
    '    final kbps = bitrateFor(codecKey);',
    "    if (kbps <= 0) return '';",
    "    return '${mbpsText(kbps)} Mbps';",
    '  }',
    '',
    '  /// 菜单 / 下拉框里唯一该显示的文案：`1080P 1.4Mbps`。',
    '  ///',
    '  /// 以前 UI 是 `label` + `bitrateLabelFor` 两段拼起来（`1080P 3M · 1.4 Mbps`），',
    '  /// 同一档位出现两个码率，看起来像重复行；现在 `label` 只留分辨率，',
    '  /// 码率只显示当前编码下真正生效的那个。原画 = 不转码，不显示码率。',
    '  String labelFor(String codecKey) {',
    '    if (copy) return label;',
    '    final kbps = bitrateFor(codecKey);',
    '    if (kbps <= 0) return label;',
    "    return '$label ${mbpsText(kbps)}Mbps';",
    '  }',
    '',
    '  /// 兼容旧调用：按 H.264 显示。',
    "  String get bitrateLabel => bitrateLabelFor('h264');",
    '}',
    '',
    '/// 输出编码：h264 → MPEG-TS；h265 / av1 → fMP4（带 EXT-X-MAP）。',
    'class PlayCodec {',
    '  const PlayCodec({',
    '    required this.key,',
    '    required this.label,',
    '    required this.container,',
    '    this.bitrateFactor = 1,',
    '  });',
    '',
    '  final String key;',
    '  final String label;',
    '',
    '  /// mpegts / fmp4（与服务端实际封装一致）。',
    '  final String container;',
    '',
    '  /// 同画质下相对 H.264 的码率系数（1.0 / 0.6 / 0.5），用于估算流量。',
    '  final double bitrateFactor;',
    '}',
    '',
    'const List<PlayQualityPreset> playQualityPresets = <PlayQualityPreset>[',
    ...spec.presets.map(presetDart),
    '];',
    '',
    'const List<PlayCodec> playCodecs = <PlayCodec>[',
    ...spec.codecs.map(codecDart),
    '];',
    '',
    `const String defaultPlayPreset = ${dartString(spec.defaultPreset)};`,
    `const String defaultPlayCodec = ${dartString(spec.defaultCodec)};`,
    `const int playAudioBitrateKbps = ${spec.audioBitrateKbps};`,
    '',
    '/// kbps → 紧凑文本：900 → `0.9`、1400 → `1.4`、7000 → `7`、15000 → `15`。',
    '///',
    '/// 公开：源码率（按文件大小 / 时长算）也用同一套写法，别两处各写一个格式化。',
    'String mbpsText(int kbps) {',
    '  final s = (kbps / 1000).toStringAsFixed(1);',
    "  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;",
    '}',
    '',
    'PlayQualityPreset? playQualityPresetOf(String key) {',
    '  for (final p in playQualityPresets) {',
    '    if (p.key == key) return p;',
    '  }',
    '  return null;',
    '}',
    '',
    'PlayCodec? playCodecOf(String key) {',
    '  for (final c in playCodecs) {',
    '    if (c.key == key) return c;',
    '  }',
    '  return null;',
    '}',
    '',
  ];
  return lines.join('\n');
}

function genTs() {
  const lines = [
    '// AUTO-GENERATED. DO NOT EDIT.',
    '// source: contracts/play-quality.json',
    '// regenerate: npm run gen:play-quality',
    '',
    'export const PLAY_QUALITY_PRESETS = [',
    ...spec.presets.map(
      (p) =>
        `  { key: ${dartString(p.key)}, label: ${dartString(p.label)}, height: ${p.height}, videoBitrateKbps: ${p.videoBitrateKbps}, copy: ${p.copy === true}, bitrates: ${JSON.stringify(p.bitrates || {})} },`,
    ),
    '] as const;',
    '',
    "export type PlayPreset = (typeof PLAY_QUALITY_PRESETS)[number]['key'];",
    '',
    'export const PLAY_CODECS = [',
    ...spec.codecs.map(
      (c) =>
        `  { key: ${dartString(c.key)}, label: ${dartString(c.label)}, container: ${dartString(c.container)}, bitrateFactor: ${Number(c.bitrateFactor ?? 1)} },`,
    ),
    '] as const;',
    '',
    "export type PlayCodec = (typeof PLAY_CODECS)[number]['key'];",
    '',
    `export const DEFAULT_PLAY_PRESET: PlayPreset = ${dartString(spec.defaultPreset)};`,
    `export const DEFAULT_PLAY_CODEC: PlayCodec = ${dartString(spec.defaultCodec)};`,
    `export const PLAY_AUDIO_BITRATE_KBPS = ${spec.audioBitrateKbps};`,
    '',
    'export function isPlayPreset(v: unknown): v is PlayPreset {',
    '  return PLAY_QUALITY_PRESETS.some((p) => p.key === v);',
    '}',
    '',
    'export function isPlayCodec(v: unknown): v is PlayCodec {',
    '  return PLAY_CODECS.some((c) => c.key === v);',
    '}',
    '',
  ];
  return lines.join('\n');
}

function genSidecarJson() {
  return `${JSON.stringify(
    {
      defaultPreset: spec.defaultPreset,
      defaultCodec: spec.defaultCodec,
      audioBitrateKbps: spec.audioBitrateKbps,
      presets: spec.presets,
      codecs: spec.codecs,
    },
    null,
    2,
  )}\n`;
}

const outputs = [
  [path.join(root, 'apps', 'colanas_os', 'lib', 'core', 'play_quality.dart'), genDart()],
  [path.join(root, 'src', 'modules', 'videoPlayer', 'play-quality.generated.ts'), genTs()],
  [path.join(root, 'sidecars', 'media', 'play-quality.generated.json'), genSidecarJson()],
];

let bad = 0;
for (const [file, content] of outputs) {
  const rel = path.relative(root, file);
  if (checkOnly) {
    const current = fs.existsSync(file) ? fs.readFileSync(file, 'utf-8') : '';
    if (current !== content) {
      console.error(`[gen-play-quality] 不一致：${rel}（请运行 npm run gen:play-quality）`);
      bad += 1;
    }
  } else {
    fs.writeFileSync(file, content);
    console.log(`[gen-play-quality] 写入 ${rel}`);
  }
}
if (checkOnly) {
  if (bad) process.exit(1);
  console.log('[gen-play-quality] 一致');
}
