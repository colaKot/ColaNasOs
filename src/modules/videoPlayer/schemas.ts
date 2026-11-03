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
