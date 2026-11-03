// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/play-quality.json
// regenerate: npm run gen:play-quality

export const PLAY_QUALITY_PRESETS = [
  { key: 'web480', label: '480p', height: 480, videoBitrateKbps: 1400 },
  { key: 'web720', label: '720p', height: 720, videoBitrateKbps: 2800 },
  { key: 'web1080', label: '1080p', height: 1080, videoBitrateKbps: 5000 },
] as const;

export type PlayPreset = (typeof PLAY_QUALITY_PRESETS)[number]['key'];

export const PLAY_CODECS = [
  { key: 'h264', label: 'H.264', container: 'mpegts' },
  { key: 'h265', label: 'H.265', container: 'fmp4' },
  { key: 'av1', label: 'AV1', container: 'fmp4' },
] as const;

export type PlayCodec = (typeof PLAY_CODECS)[number]['key'];

export const DEFAULT_PLAY_PRESET: PlayPreset = 'web720';
export const DEFAULT_PLAY_CODEC: PlayCodec = 'h264';
export const PLAY_AUDIO_BITRATE_KBPS = 128;

export function isPlayPreset(v: unknown): v is PlayPreset {
  return PLAY_QUALITY_PRESETS.some((p) => p.key === v);
}

export function isPlayCodec(v: unknown): v is PlayCodec {
  return PLAY_CODECS.some((c) => c.key === v);
}
