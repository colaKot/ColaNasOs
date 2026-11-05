// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/play-quality.json
// regenerate: npm run gen:play-quality

export const PLAY_QUALITY_PRESETS = [
  { key: 'original', label: '原画', height: 0, videoBitrateKbps: 0, copy: true, bitrates: {"h264":0,"h265":0,"av1":0} },
  { key: '2160p_15m', label: '4K', height: 2160, videoBitrateKbps: 15000, copy: false, bitrates: {"h264":15000,"h265":9000,"av1":7000} },
  { key: '1440p_10m', label: '2K 10M', height: 1440, videoBitrateKbps: 10000, copy: false, bitrates: {"h264":10000,"h265":6000,"av1":4800} },
  { key: '1440p_8m', label: '2K 8M', height: 1440, videoBitrateKbps: 8000, copy: false, bitrates: {"h264":8000,"h265":4800,"av1":3800} },
  { key: '1440p_5m', label: '2K 5M', height: 1440, videoBitrateKbps: 5000, copy: false, bitrates: {"h264":5000,"h265":3000,"av1":2400} },
  { key: '1440p_3m', label: '2K 3M', height: 1440, videoBitrateKbps: 3000, copy: false, bitrates: {"h264":3000,"h265":1800,"av1":1400} },
  { key: '1080p_8m', label: '1080P 8M', height: 1080, videoBitrateKbps: 8000, copy: false, bitrates: {"h264":8000,"h265":4800,"av1":3800} },
  { key: '1080p_5m', label: '1080P 5M', height: 1080, videoBitrateKbps: 5000, copy: false, bitrates: {"h264":5000,"h265":3000,"av1":2400} },
  { key: '1080p_3m', label: '1080P 3M', height: 1080, videoBitrateKbps: 3000, copy: false, bitrates: {"h264":3000,"h265":1800,"av1":1400} },
  { key: '1080p_2m', label: '1080P 2M', height: 1080, videoBitrateKbps: 2000, copy: false, bitrates: {"h264":2000,"h265":1200,"av1":900} },
  { key: '720p_3m', label: '720P 3M', height: 720, videoBitrateKbps: 3000, copy: false, bitrates: {"h264":3000,"h265":1800,"av1":1400} },
  { key: '720p_2m', label: '720P 2M', height: 720, videoBitrateKbps: 2000, copy: false, bitrates: {"h264":2000,"h265":1200,"av1":900} },
  { key: '720p_1m', label: '720P 1M', height: 720, videoBitrateKbps: 1000, copy: false, bitrates: {"h264":1000,"h265":600,"av1":480} },
  { key: '480p_1m', label: '480P 1M', height: 480, videoBitrateKbps: 1000, copy: false, bitrates: {"h264":1000,"h265":600,"av1":480} },
] as const;

export type PlayPreset = (typeof PLAY_QUALITY_PRESETS)[number]['key'];

export const PLAY_CODECS = [
  { key: 'h264', label: 'H.264 / AVC', container: 'mpegts', bitrateFactor: 1 },
  { key: 'h265', label: 'H.265 / HEVC', container: 'fmp4', bitrateFactor: 0.6 },
  { key: 'av1', label: 'AV1', container: 'fmp4', bitrateFactor: 0.5 },
] as const;

export type PlayCodec = (typeof PLAY_CODECS)[number]['key'];

export const DEFAULT_PLAY_PRESET: PlayPreset = '1080p_3m';
export const DEFAULT_PLAY_CODEC: PlayCodec = 'h264';
export const PLAY_AUDIO_BITRATE_KBPS = 128;

export function isPlayPreset(v: unknown): v is PlayPreset {
  return PLAY_QUALITY_PRESETS.some((p) => p.key === v);
}

export function isPlayCodec(v: unknown): v is PlayCodec {
  return PLAY_CODECS.some((c) => c.key === v);
}
