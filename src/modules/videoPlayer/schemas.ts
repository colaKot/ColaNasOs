import { Type } from '@sinclair/typebox';
import {
  DEFAULT_PLAY_CODEC,
  DEFAULT_PLAY_PRESET,
  PLAY_CODECS,
  PLAY_QUALITY_PRESETS,
} from './play-quality.generated';

/** videoPlayer（HLS 转码会话）路由契约 */

/** 档位 / 编码枚举来自 contracts/play-quality.json，禁止在此硬编码（见 tool/gen-play-quality.js） */
const PresetUnion = Type.Union(
  PLAY_QUALITY_PRESETS.map((p) => Type.Literal(p.key)) as any,
  { default: DEFAULT_PLAY_PRESET },
);
const CodecUnion = Type.Union(
  PLAY_CODECS.map((c) => Type.Literal(c.key)) as any,
  { default: DEFAULT_PLAY_CODEC },
);

export const SessionCreateBody = Type.Object(
  {
    id: Type.String({ minLength: 1, description: '影视条目 id' }),
    preset: Type.Optional(PresetUnion),
    /**
     * 输出编码：h264 → MPEG-TS；h265 / av1 → fMP4（带 EXT-X-MAP）。
     * sidecar 在该编码不可用时自动降级回 h264，实际编码见会话的 `codec`。
     */
    codec: Type.Optional(CodecUnion),
    subtitle: Type.Optional(
      Type.String({ description: '同目录外挂字幕文件名（如 S01E01.zh.srt）；给定时烧录进画面' }),
    ),
    /**
     * 客户端级音频覆盖：不传 = 跟随库级「响度归一」开关（video_libraries.audio_normalize）。
     * 客户端设置页只在用户偏离默认值时才带上这两个字段。
     */
    audioNormalize: Type.Optional(
      Type.Boolean({ description: '响度归一（优先于库级开关）：true = 强制开，false = 强制关' }),
    ),
    audioDownmix: Type.Optional(
      Type.Boolean({ description: '降混双声道：5.1 / 7.1 压成 stereo' }),
    ),
    audioIndex: Type.Optional(
      Type.Integer({ minimum: 0, description: '选第几条音轨转码（默认 0）' }),
    ),
    forceSdr: Type.Optional(
      Type.Boolean({ description: '强制 HDR→SDR；不传时由服务端按片源标记自动判定' }),
    ),
  },
  { $id: 'PlayerSessionCreateBody' },
);

export const SessionCreated = Type.Object(
  { id: Type.String(), url: Type.String() },
  { $id: 'PlayerSessionCreated' },
);

export const SessionItem = Type.Object(
  {
    id: Type.String(),
    itemId: Type.String(),
    preset: Type.String(),
    codec: Type.Optional(Type.String({ description: 'h264 / h265 / av1（降级后以实际值为准）' })),
    container: Type.Optional(Type.String({ description: 'mpegts / fmp4' })),
    subtitle: Type.Union([Type.String(), Type.Null()]),
    status: Type.Union([
      Type.Literal('pending'),
      Type.Literal('running'),
      Type.Literal('done'),
      Type.Literal('failed'),
      Type.Literal('canceled'),
    ]),
    segments: Type.Integer(),
    error: Type.Union([Type.String(), Type.Null()]),
    url: Type.String(),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
    audioIndex: Type.Optional(Type.Integer({ description: '转码选用的音轨序号' })),
    hdrToSdr: Type.Optional(Type.Boolean({ description: '是否做 HDR→SDR 转换' })),
  },
  { $id: 'PlayerSessionItem' },
);

export const SessionQuery = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'PlayerSessionQuery' },
);

export const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'PlayerErrorResponse' },
);

export const PLAYER_SCHEMAS = [
  SessionCreateBody,
  SessionCreated,
  SessionItem,
  SessionQuery,
  ErrorResponse,
];
