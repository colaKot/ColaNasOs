import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi, ServerModule } from '../../../kernel/types';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { listSubtitles } from '../video/subtitles';
import { PLAYER_SCHEMAS } from './schemas';
import {
  DEFAULT_PLAY_CODEC,
  DEFAULT_PLAY_PRESET,
  isPlayCodec,
  isPlayPreset,
} from './play-quality.generated';
import { Err } from '../../../kernel/errors';

/**
 * videoPlayer（旧工程 `videoPlayer` 模块）：HLS 转码会话 + 字幕烧录。
 *
 *   POST /api/v1/player/sessions       建会话（后台 ffmpeg → HLS）
 *   GET  /api/v1/player/sessions?id=   查状态（含播放地址）
 *   GET  /api/v1/player/hls/:id/:file  m3u8 / 分片（公开，凭会话 UUID）
 *
 * 为什么用 HLS：一次转码产出可顺序拉取的分片，播放器能边下边播，
 * 也便于后续接「转码会话复用」。字幕烧录走 `subtitles` 滤镜，只对外挂字幕生效
 * （内嵌字幕轨的提取留给后续迭代）。
 */
const TAG = ['player'];
const ref = (id: string) => ({ $ref: `${id}#` });

interface SessionRow {
  id: string;
  item_id: string;
  preset: string;
  codec: string | null;
  container: string | null;
  subtitle: string | null;
  status: string;
  segments: number;
  error: string | null;
  created_at: number;
  updated_at: number;
}

const now = () => Math.floor(Date.now() / 1000);
/** 给 m3u8 里的分片与 EXT-X-MAP 加访问令牌（播放器按相对名拉流时不会自己带上） */
function withToken(line: string, token: string): string {
  const t = encodeURIComponent(token);
  if (!line) return line;
  if (line.startsWith('#')) {
    return line.replace(/URI="([^"]+)"/, (_m, uri: string) =>
      `URI="${uri}${uri.includes('?') ? '&' : '?'}t=${t}"`);
  }
  return `${line}${line.includes('?') ? '&' : '?'}t=${t}`;
}

const urlOf = (id: string, token?: string) =>
  `/api/v1/player/hls/${id}/index.m3u8${token ? '?t=' + encodeURIComponent(token) : ''}`;

/** HLS 地址凭**短期签名令牌**访问（不再依赖裸会话 UUID） */
const hlsToken = (k: KernelApi, id: string) =>
  k.auth.sign({ sub: `hls:${id}`, scopes: ['player:read'] }, 6 * 3600);

const toItem = (r: SessionRow, token?: string) => ({
  id: r.id,
  itemId: r.item_id,
  preset: r.preset,
  codec: r.codec,
  container: r.container,
  subtitle: r.subtitle,
  status: r.status,
  segments: Number(r.segments),
  error: r.error,
  url: urlOf(r.id, token),
  createdAt: Number(r.created_at),
  updatedAt: Number(r.updated_at),
});

async function statusOf(k: KernelApi, id: string): Promise<string | null> {
  const rows = (
    await sql<{ status: string }>`select status from player_sessions where id = ${id}`.execute(k.db)
  ).rows;
  return rows[0]?.status ?? null;
}

let pumping = false;

async function pump(k: KernelApi): Promise<void> {
  if (pumping) return;
  pumping = true;
  try {
    for (;;) {
      const rows = (
        await sql<SessionRow>`
          select * from player_sessions where status = 'pending' order by created_at asc limit 1
        `.execute(k.db)
      ).rows;
      const job = rows[0];
      if (!job) break;

      await sql`update player_sessions set status = 'running', updated_at = ${now()} where id = ${job.id}`.execute(
        k.db,
      );
      try {
        const root = filesRoot();
        const rel = await itemPath(k, job.item_id);
        if (!rel) throw new Error('video item not found');
        const src = resolveInRoot(root, rel);
        const dir = path.join(k.paths.dataDir, 'hls', job.id);
        // 库级「响度归一」：转码时加 dynaudnorm，前端不用管音频
        const flag = (
          await sql<{ audio_normalize: number | null }>`
            select l.audio_normalize from video_items i
              join video_libraries l on l.id = i.library_id
             where i.id = ${job.item_id}
          `.execute(k.db)
        ).rows[0];
        const res = await k.media.hls(src, dir, {
          preset: job.preset,
          subtitle: job.subtitle ?? undefined,
          audioFilter: Number(flag?.audio_normalize) === 1 ? 'dynaudnorm' : undefined,
        });
        await sql`
          update player_sessions
          set status = 'done', segments = ${res.segments},
              codec = ${res.codec ?? job.codec ?? 'h264'},
              container = ${res.container ?? 'mpegts'},
              updated_at = ${now()}
          where id = ${job.id}
        `.execute(k.db);
      } catch (err) {
        const message = String((err as Error)?.message || err);
        k.log.warn({ session: job.id, err: message }, 'player hls failed');
        await sql`
          update player_sessions
          set status = 'failed', error = ${message.slice(0, 500)}, updated_at = ${now()}
          where id = ${job.id}
        `.execute(k.db);
      }
    }
  } finally {
    pumping = false;
  }
}

async function itemPath(k: KernelApi, itemId: string): Promise<string | null> {
  // video_items.rel_path 已经包含库目录（相对 files 根），不要再拼 root_path
  const rows = (
    await sql<{
      path: string;
    }>`select rel_path as path from video_items where id = ${itemId}`.execute(k.db)
  ).rows;
  return rows[0]?.path ?? null;
}

export const videoPlayer: ServerModule = {
  id: 'videoPlayer',
  prefix: '/api/v1/player',
  permissions: ['player:read', 'player:write'],

  migrations: [
    {
      id: '041_player_sessions',
      async up(db) {
        await sql`
          create table if not exists player_sessions (
            id text primary key,
            item_id text not null,
            preset text not null default 'web720',
            subtitle text,
            status text not null default 'pending',
            segments integer not null default 0,
            error text,
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_player_sessions_status
          on player_sessions (status, created_at)
        `.execute(db);
      },
    },
    {
      id: '065_player_codec',
      async up(db) {
        // 按编码分档：h265 / av1 走 fMP4（带 EXT-X-MAP），降级后以实际值为准。
        const cols = (
          (await sql`pragma table_info(player_sessions)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        if (!cols.includes('codec')) {
          await sql`alter table player_sessions add column codec text`.execute(db);
        }
        if (!cols.includes('container')) {
          await sql`alter table player_sessions add column container text`.execute(db);
        }
      },
    },
  ],

  async register(app, k) {
    for (const schema of PLAYER_SCHEMAS) app.addSchema(schema);
    await sql`update player_sessions set status = 'pending' where status = 'running'`.execute(k.db);
    pump(k).catch((err) => k.log.warn({ err: String(err) }, 'player pump stopped'));

    app.post(
      '/api/v1/player/sessions',
      secured('player:write', {
        schema: {
          operationId: 'playerSessionCreate',
          tags: TAG,
          summary: '建 HLS 转码会话（可选字幕烧录）',
          body: ref('PlayerSessionCreateBody'),
          response: {
            200: ref('PlayerSessionCreated'),
            400: ref('PlayerErrorResponse'),
            404: ref('PlayerErrorResponse'),
            503: ref('PlayerErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          id?: string;
          preset?: string;
          codec?: string;
          subtitle?: string;
        };
        const item = body.id ? await itemPath(k, body.id) : null;
        if (!item) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });
        if (!k.media.available()) {
          return reply
            .code(503)
            .send({ error: Err.mediaUnavailable, message: '缺少 ffmpeg / media sidecar' });
        }

        const srcAbs = resolveInRoot(filesRoot(), item);
        if (!fs.existsSync(srcAbs)) {
          return reply.code(404).send({ error: Err.notFound, message: 'source file missing' });
        }

        let subtitle: string | null = null;
        if (body.subtitle) {
          // 只接受同目录、且在字幕列表里的文件名（防路径穿越与任意文件读取）
          const hit = listSubtitles(srcAbs).find((s) => s.name === body.subtitle);
          if (!hit)
            return reply.code(400).send({ error: Err.badRequest, message: 'subtitle not found' });
          subtitle = path.join(path.dirname(srcAbs), hit.name);
        }

        const id = crypto.randomUUID();
        const ts = now();
        const codec = isPlayCodec(body.codec) ? body.codec : DEFAULT_PLAY_CODEC;
        const preset = isPlayPreset(body.preset) ? body.preset : DEFAULT_PLAY_PRESET;
        await sql`
          insert into player_sessions (id, item_id, preset, codec, subtitle, status, created_at, updated_at)
          values (${id}, ${body.id}, ${preset}, ${codec},
                  ${subtitle}, 'pending', ${ts}, ${ts})
        `.execute(k.db);
        pump(k).catch((err) => k.log.warn({ err: String(err) }, 'player pump stopped'));
        return { id, url: urlOf(id, hlsToken(k, id)) };
      },
    );

    app.get(
      '/api/v1/player/sessions',
      secured('player:read', {
        schema: {
          operationId: 'playerSessionGet',
          tags: TAG,
          summary: '查询转码会话状态与播放地址',
          querystring: ref('PlayerSessionQuery'),
          response: { 200: ref('PlayerSessionItem'), 404: ref('PlayerErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const rows = (
          await sql<SessionRow>`select * from player_sessions where id = ${q.id ?? ''}`.execute(
            k.db,
          )
        ).rows;
        if (!rows[0])
          return reply.code(404).send({ error: Err.notFound, message: 'session not found' });
        return toItem(rows[0], hlsToken(k, rows[0].id));
      },
    );

    // 公开路由：m3u8 / 分片（见 kernel preHandler 的会话 UUID 说明）
    app.get(
      '/api/v1/player/hls/:session/:file',
      {
        schema: {
          operationId: 'playerHlsFile',
          tags: TAG,
          summary: 'HLS 播放列表与分片（凭会话 UUID）',
          hide: true,
        },
      },
      async (req, reply) => {
        const params = (req.params || {}) as { session?: string; file?: string };
        const session = String(params.session || '');
        const file = String(params.file || '');
        if (
          !/^[0-9a-f-]{36}$/.test(session) ||
          !/^(index\.m3u8|init\.mp4|seg\d{5}\.(ts|m4s))$/.test(file)
        ) {
          return reply.code(404).send({ error: Err.notFound });
        }
        const rows = (
          await sql<{
            status: string;
          }>`select status from player_sessions where id = ${session}`.execute(k.db)
        ).rows;
        if (!rows[0] || rows[0].status !== 'done') {
          return reply.code(404).send({ error: Err.notFound, message: 'session not ready' });
        }

        const abs = path.join(k.paths.dataDir, 'hls', session, file);
        if (!fs.existsSync(abs)) return reply.code(404).send({ error: Err.notFound });
        const body = await fsp.readFile(abs);
        reply
          .header('cache-control', 'no-store')
          .type(
            file.endsWith('.m3u8')
              ? 'application/vnd.apple.mpegurl'
              : file.endsWith('.m4s')
                ? 'video/iso.segment'
                : file.endsWith('.mp4')
                  ? 'video/mp4'
                  : 'video/mp2t',
          );
        if (file.endsWith('.m3u8')) {
          // 分片由播放器按相对名请求，不会带请求头；把令牌写进播放列表（含 EXT-X-MAP）
          const token = hlsToken(k, session);
          const text = body
            .toString('utf8')
            .replace(/\r\n/g, '\n')
            .split('\n')
            .map((line) => withToken(line.replace(/\r$/, ''), token))
            .join('\n');
          return reply.send(text);
        }
        return reply.send(body);
      },
    );
  },
};
