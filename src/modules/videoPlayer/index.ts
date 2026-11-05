import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi, ServerModule } from '../../../kernel/types';
import { filesRoot, resolveAnyPath } from '../files/fs-root';
import { isOfflinePath, offlineSmbPrefixes } from '../video/sources';
import { listSubtitles } from '../video/subtitles';
import { embeddedIndex, ensureEmbeddedFile } from '../video/embedded-subs';
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
  /** 客户端级覆盖：1 = 响度归一 / 1 = 降混双声道；null = 跟随库级开关 */
  audio_normalize: number | null;
  audio_downmix: number | null;
  audio_index: number | null;
  force_sdr: number | null;
  /** pump 按片源标记算出的最终 HDR→SDR 决策（供响应回显） */
  hdr_to_sdr: number | null;
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

/** HLS 分片根目录：与 pump() 保持一致地解析 video.transcode.tempDir，配置无效时回落默认目录 */
function hlsRootOf(k: KernelApi): string {
  const tconf = (k.config.get<{ tempDir?: string }>('video.transcode') || {}) as {
    tempDir?: string;
  };
  const customRoot = String(tconf.tempDir || '').trim();
  if (customRoot) {
    try {
      if (fs.statSync(customRoot).isDirectory()) {
        fs.accessSync(customRoot, fs.constants.W_OK);
        return customRoot;
      }
    } catch {
      // 不存在 / 不可写：回落默认目录
    }
  }
  return path.join(k.paths.dataDir, 'hls');
}

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
  audioIndex: Number(r.audio_index ?? 0),
  hdrToSdr: Number(r.hdr_to_sdr) === 1,
});

async function statusOf(k: KernelApi, id: string): Promise<string | null> {
  const rows = (
    await sql<{ status: string }>`select status from player_sessions where id = ${id}`.execute(k.db)
  ).rows;
  return rows[0]?.status ?? null;
}

/**
 * 同时运行的转码会话上限（默认 2）。
 *
 * 以前是严格串行：一条转不动的 4K Dolby Vision 片（实测 AV1 档超时 30 分钟、
 * 失败后还会再试一次）会把队列里所有其它播放请求堵在后面，用户看到的
 * 就是「点了播放，等半个多小时才开始」。两条并行既能让新片立刻开工，
 * 又不至于把 CPU 全部吃满。
 */
const MAX_JOBS = Math.max(1, Math.min(Number(process.env.COLANAS_PLAYER_JOBS) || 2, 4));
const jobs = new Set<string>();
let claiming = false;

async function claimJob(k: KernelApi): Promise<SessionRow | null> {
  const rows = (
    await sql<SessionRow>`
      select * from player_sessions where status = 'pending' order by created_at asc limit 1
    `.execute(k.db)
  ).rows;
  const job = rows[0];
  if (!job) return null;
  // 条件更新：被 supersede 标记成 canceled 的会话不会再被领走
  await sql`
    update player_sessions set status = 'running', updated_at = ${now()}
     where id = ${job.id} and status = 'pending'
  `.execute(k.db);
  return job;
}

async function runJob(k: KernelApi, job: SessionRow): Promise<void> {
  try {
    const root = filesRoot();
    const rel = await itemPath(k, job.item_id);
    if (!rel) throw new Error('video item not found');
    // 库里的片可能来自 SMB 来源（绝对路径，已登记在 extraRoots）。
    // 用 resolveInRoot 会把它们一律判成越界 —— 表现为「点播放 403」、
    // 杜比/HDR 片子尤其需要走转码，这里必须和 video/stream 用同一套解析。
    const src = resolveAnyPath(root, rel);
    if (isOfflinePath(rel, await offlineSmbPrefixes(k.db))) {
      throw new Error('source offline');
    }
    // 转码目录 / 首选解码器来自「影视设置 → 转码设置」；配置无效时静默回落默认值，
    // 不让一个写错的路径把播放整个打死。
    const tconf = (k.config.get<{ tempDir?: string; hwaccel?: string }>('video.transcode') ||
      {}) as { tempDir?: string; hwaccel?: string };
    const dir = path.join(hlsRootOf(k), job.id);
    // 音频处理链：会话上的客户端覆盖优先，未指定才跟随库级 audio_normalize 开关
    const flag = (
      await sql<{ audio_normalize: number | null }>`
        select l.audio_normalize from video_items i
          join video_libraries l on l.id = i.library_id
         where i.id = ${job.item_id}
      `.execute(k.db)
    ).rows[0];
    const normalize =
      job.audio_normalize == null
        ? Number(flag?.audio_normalize) === 1
        : Number(job.audio_normalize) === 1;
    // 片源标记：pump 据此自动判定 HDR→SDR；forceSdr 只是强制开
    const media = (
      await sql<{
        is_4k: number | null; hdr10: number | null; hdr10plus: number | null;
        hlg: number | null; dolby_vision: number | null; dolby_atmos: number | null;
        video_codec: string | null; audio_codec: string | null;
      }>`
        select is_4k, hdr10, hdr10plus, hlg, dolby_vision, dolby_atmos,
               video_codec, audio_codec
          from video_items where id = ${job.item_id}
      `.execute(k.db)
    ).rows[0];
    const on = (v: unknown) => Number(v) === 1;
    const hdrToSdr =
      Number(job.force_sdr) === 1 ||
      on(media?.dolby_vision) || on(media?.hdr10) ||
      on(media?.hdr10plus) || on(media?.hlg);
    const audioIndex = Number(job.audio_index ?? 0);
    await sql`update player_sessions set hdr_to_sdr = ${hdrToSdr ? 1 : 0} where id = ${job.id}`.execute(
      k.db,
    );
    const filters: string[] = [];
    if (normalize) filters.push('dynaudnorm');
    // 降混双声道：aformat 把 5.1 / 7.1 压成 stereo，单声道不会再被升混
    if (Number(job.audio_downmix) === 1) filters.push('aformat=channel_layouts=stereo');
    const res = await k.media.hls(src, dir, {
      preset: job.preset,
      codec: job.codec ?? undefined,
      subtitle: job.subtitle ?? undefined,
      audioFilter: filters.length ? filters.join(',') : undefined,
      hwaccel: String(tconf.hwaccel || 'auto'),
      audioIndex,
      hdrToSdr,
      // 「原画」能否直接 copy 取决于片源：AV1/HEVC 复制进 TS 解不出来
      srcVideoCodec: media?.video_codec ?? undefined,
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
    // 主动取消（被新会话抢占）：这是预期状态，不该显示成转码失败
    const canceled = (err as { code?: string })?.code === 'E_CANCELED';
    if (!canceled) k.log.warn({ session: job.id, err: message }, 'player hls failed');
    await sql`
      update player_sessions
      set status = ${canceled ? 'canceled' : 'failed'}, error = ${canceled ? 'superseded' : message.slice(0, 500)}, updated_at = ${now()}
      where id = ${job.id}
    `.execute(k.db);
  }
}

async function pump(k: KernelApi): Promise<void> {
  if (claiming) return;
  claiming = true;
  try {
    while (jobs.size < MAX_JOBS) {
      const job = await claimJob(k);
      if (!job) break;
      jobs.add(job.id);
      void runJob(k, job)
        .catch((err) => k.log.warn({ session: job.id, err: String(err) }, 'player job crashed'))
        .finally(() => {
          jobs.delete(job.id);
          // 空出槽位后继续取下一个（新任务可能刚被插入）
          void pump(k);
        });
    }
  } finally {
    claiming = false;
  }
}

/**
 * 新会话建好时，把同一部片还在排队 / 正在转的旧会话取消掉。
 * 用户换档（AV1 → 480p）时旧编码没必要继续跑，否则新会话只能排它后面。
 */
async function supersedeOlder(k: KernelApi, itemId: string): Promise<void> {
  const rows = (
    await sql<{ id: string; status: string }>`
      select id, status from player_sessions
       where item_id = ${itemId} and status in ('pending', 'running')
    `.execute(k.db)
  ).rows;
  for (const row of rows) {
    await sql`
      update player_sessions
      set status = 'canceled', error = 'superseded', updated_at = ${now()}
      where id = ${row.id}
    `.execute(k.db);
    if (row.status === 'running') {
      await k.media.cancel(path.join(hlsRootOf(k), row.id));
    }
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
    {
      id: '105_player_audio',
      async up(db) {
        // 客户端级音频覆盖：null = 跟随库级 audio_normalize 开关，1/0 = 本会话强制开/关。
        // 「降混双声道」没有库级开关，只有客户端设置，所以单独一列。
        const cols = (
          (await sql`pragma table_info(player_sessions)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        if (!cols.includes('audio_normalize')) {
          await sql`alter table player_sessions add column audio_normalize integer`.execute(db);
        }
        if (!cols.includes('audio_downmix')) {
          await sql`alter table player_sessions add column audio_downmix integer`.execute(db);
        }
      },
    },
    {
      id: '129_player_audio_index',
      async up(db) {
        // 音轨选择 + HDR→SDR：audio_index / force_sdr 是建会话时的输入，
        // hdr_to_sdr 是 pump 按片源标记算出的最终决策（响应回显用）。
        const cols = (
          (await sql`pragma table_info(player_sessions)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        if (!cols.includes('audio_index')) {
          await sql`alter table player_sessions add column audio_index integer not null default 0`.execute(db);
        }
        if (!cols.includes('force_sdr')) {
          await sql`alter table player_sessions add column force_sdr integer not null default 0`.execute(db);
        }
        if (!cols.includes('hdr_to_sdr')) {
          await sql`alter table player_sessions add column hdr_to_sdr integer not null default 0`.execute(db);
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
          audioNormalize?: boolean;
          audioDownmix?: boolean;
          audioIndex?: number;
          forceSdr?: boolean;
        };
        const item = body.id ? await itemPath(k, body.id) : null;
        if (!item) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });
        if (!k.media.available()) {
          return reply
            .code(503)
            .send({ error: Err.mediaUnavailable, message: '缺少 ffmpeg / media sidecar' });
        }

        const srcAbs = resolveAnyPath(filesRoot(), item);
        if (isOfflinePath(item, await offlineSmbPrefixes(k.db))) {
          return reply.code(404).send({ error: Err.notFound, message: 'source offline' });
        }
        if (!fs.existsSync(srcAbs)) {
          return reply.code(404).send({ error: Err.notFound, message: 'source file missing' });
        }

        let subtitle: string | null = null;
        if (body.subtitle) {
          const emb = embeddedIndex(body.subtitle);
          if (emb !== null) {
            // 内嵌字幕轨：先抽成 SRT（缓存），再交给字幕烧录滤镜
            const mt =
              (
                await sql<{ mtime: number }>`
                  select mtime from video_items where id = ${body.id as string}
                `.execute(k.db)
              ).rows[0]?.mtime ?? 0;
            const extracted = await ensureEmbeddedFile(k, srcAbs, mt, emb);
            if (!extracted)
              return reply.code(400).send({ error: Err.badRequest, message: 'subtitle not found' });
            subtitle = extracted;
          } else {
            // 只接受同目录、且在字幕列表里的文件名（防路径穿越与任意文件读取）
            const hit = listSubtitles(srcAbs).find((s) => s.name === body.subtitle);
            if (!hit)
              return reply.code(400).send({ error: Err.badRequest, message: 'subtitle not found' });
            subtitle = path.join(path.dirname(srcAbs), hit.name);
          }
        }

        const id = crypto.randomUUID();
        const ts = now();
        const codec = isPlayCodec(body.codec) ? body.codec : DEFAULT_PLAY_CODEC;
        const preset = isPlayPreset(body.preset) ? body.preset : DEFAULT_PLAY_PRESET;
        // null 表示「没指定」= 跟随库级开关；只有布尔值才落 0/1
        const audioNormalize =
          typeof body.audioNormalize === 'boolean' ? (body.audioNormalize ? 1 : 0) : null;
        const audioDownmix = typeof body.audioDownmix === 'boolean' ? (body.audioDownmix ? 1 : 0) : null;
        const n = Number(body.audioIndex);
        const audioIndex = Number.isInteger(n) && n >= 0 ? n : 0;
        const forceSdr = body.forceSdr === true ? 1 : 0;
        // 同参数会话复用：pump 是串行的，重复点播放会不断往队列里塞「全片转码」，
        // 后面所有片都得等前面跑完。done 的直接秒开，pending/running 共用同一份
        // 产物边转边播。
        const dupe = (
          await sql<SessionRow>`
            select * from player_sessions
             where item_id = ${body.id} and preset = ${preset} and codec = ${codec}
               and coalesce(audio_index, 0) = ${audioIndex}
               and coalesce(force_sdr, 0) = ${forceSdr}
               and coalesce(subtitle, '') = ${subtitle ?? ''}
               and status in ('pending', 'running', 'done')
               and created_at > ${ts - 7 * 86400}
             order by created_at desc limit 1
          `.execute(k.db)
        ).rows[0];
        if (dupe) {
          // 内核重启可能留下 pending 会话、没有 pump 在跑，顺手补一次
          pump(k).catch((err) => k.log.warn({ err: String(err) }, 'player pump stopped'));
          return { id: dupe.id, url: urlOf(dupe.id, hlsToken(k, dupe.id)) };
        }
        // 换档 / 重试：同一部片还在排队或正在转的旧会话先取消，
        // 否则新会话只能排在它后面（4K 转不动的片实测能把队列堵 50 分钟）。
        await supersedeOlder(k, body.id as string);
        await sql`
          insert into player_sessions
            (id, item_id, preset, codec, subtitle, audio_normalize, audio_downmix,
             audio_index, force_sdr, hdr_to_sdr, status, created_at, updated_at)
          values (${id}, ${body.id}, ${preset}, ${codec},
                  ${subtitle}, ${audioNormalize}, ${audioDownmix},
                  ${audioIndex}, ${forceSdr}, ${forceSdr}, 'pending', ${ts}, ${ts})
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
        // 边转边播：EVENT 播放列表在第一个分片落盘时就可读，
        // 只要会话没失败就放行，不再等 status=done。
        if (!rows[0] || rows[0].status === 'failed' || rows[0].status === 'canceled') {
          return reply.code(404).send({ error: Err.notFound, message: 'session not ready' });
        }
        const sessionStatus = rows[0].status;

        // 与 pump() 共用同一套 tempDir 解析；配置变更过的会话再回落默认目录兜底
        let abs = path.join(hlsRootOf(k), session, file);
        if (!fs.existsSync(abs)) {
          const fallback = path.join(k.paths.dataDir, 'hls', session, file);
          if (fs.existsSync(fallback)) abs = fallback;
        }

        const isPlaylist = file === 'index.m3u8';
        let body: Buffer | null;
        // 首片还没落盘时**短暂等一下**：直接返回空 EVENT 播放列表，很多播放器
        // （实测 Web 的 hls.js）拿到「没有任何分片」就停在黑屏，而 ffmpeg 其实
        // 1~2 秒后就有首片了。等最多 15s，能等到就直接给真实播放列表。
        const deadline = Date.now() + 15_000;
        for (;;) {
          try {
            body = await fsp.readFile(abs);
          } catch {
            body = null;
          }
          const ready = isPlaylist
            ? body !== null && body.toString('utf8').includes('#EXTINF')
            : body !== null;
          if (ready) break;
          const stillWorking =
            sessionStatus === 'pending' || sessionStatus === 'running';
          if (!isPlaylist || !stillWorking || Date.now() >= deadline) break;
          // 会话可能在这期间失败 / 被取消，别死等
          const st = await statusOf(k, session);
          if (st === 'failed' || st === 'canceled') break;
          await new Promise((resolve) => setTimeout(resolve, 200));
        }

        if (body === null) {
          // 转码刚启动、首片还没落盘：给一个空的 EVENT 播放列表。
          // hls.js 会按 live 语义定时刷新，分片一出现就能播；
          // 直接 404 会让它判定 fatal，整页变成播放错误。
          if (isPlaylist &&
              (sessionStatus === 'pending' || sessionStatus === 'running')) {
            reply
              .header('cache-control', 'no-store')
              .type('application/vnd.apple.mpegurl');
            return reply.send(
              '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n' +
                '#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n',
            );
          }
          return reply.code(404).send({ error: Err.notFound });
        }
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
