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
  return [
    '    PlayQualityPreset(',
    `      key: ${dartString(p.key)},`,
    `      label: ${dartString(p.label)},`,
    `      height: ${p.height},`,
    `      videoBitrateKbps: ${p.videoBitrateKbps},`,
    '    ),',
  ].join('\n');
}

function codecDart(c) {
  return [
    '    PlayCodec(',
    `      key: ${dartString(c.key)},`,
    `      label: ${dartString(c.label)},`,
    `      container: ${dartString(c.container)},`,
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
    '  });',
    '',
    '  final String key;',
    '  final String label;',
    '  final int height;',
    '  final int videoBitrateKbps;',
    '',
    '  /// 供下拉框展示的码率短标签（如 2.8 Mbps）。',
    '  String get bitrateLabel {',
    '    final mbps = videoBitrateKbps / 1000;',
    "    return '${mbps.toStringAsFixed(mbps >= 10 ? 0 : 1)} Mbps';",
    '  }',
    '}',
    '',
    '/// 输出编码：h264 → MPEG-TS；h265 / av1 → fMP4（带 EXT-X-MAP）。',
    'class PlayCodec {',
    '  const PlayCodec({',
    '    required this.key,',
    '    required this.label,',
    '    required this.container,',
    '  });',
    '',
    '  final String key;',
    '  final String label;',
    '',
    '  /// mpegts / fmp4（与服务端实际封装一致）。',
    '  final String container;',
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
        `  { key: ${dartString(p.key)}, label: ${dartString(p.label)}, height: ${p.height}, videoBitrateKbps: ${p.videoBitrateKbps} },`,
    ),
    '] as const;',
    '',
    "export type PlayPreset = (typeof PLAY_QUALITY_PRESETS)[number]['key'];",
    '',
    'export const PLAY_CODECS = [',
    ...spec.codecs.map(
      (c) => `  { key: ${dartString(c.key)}, label: ${dartString(c.label)}, container: ${dartString(c.container)} },`,
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
