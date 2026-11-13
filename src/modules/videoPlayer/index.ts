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
import { mergePlaylists, playlistDurationMs, type PlaylistPart } from './playlist';
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
/**
 * 所有端统一的默认提前转码时长（分钟）。
 * 不传 `leadMinutes` 的客户端 / SDK / 直接 API 调用都落这个值；
 * 只有显式传 0 才回到「整片一次转完」的旧行为。
 */
const DEFAULT_LEAD_MINUTES = 3;
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
  /** 提前转码时长（毫秒）；0 = 用户显式选了整片一次转完（老会话默认值） */
  lead_ms: number | null;
  /**
   * 这个会话从片源第几毫秒起转（0 = 片头）。
   *
   * 进度条拖到「还没转出来」的位置时会建一个从中途起转的会话：产物播放列表的
   * 时间轴 0 就是 start_ms，客户端自己加偏移显示成片源时间。
   */
  start_ms: number | null;
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
  k.auth.sign({ sub: `hls:${id}`, scopes: ['video:read'] }, 6 * 3600);

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

/**
 * 播放中「这一轮实际用上的编码」。
 *
 * sidecar 在首片落盘时会写 `<hls 目录>/.session.json`（见 sidecars/media/main.js
 * 的 watch 看门狗）。为什么不在建会话时就定死：用户选了 AV1，但机器上 AV1 编码器
 * 起不来时 sidecar 会**静默降级**回 H.264，只有首片真的落盘才知道跑的是哪条路径。
 * 而 `player_sessions.codec` 要到整片转完才更新 —— 不读这个文件，播放中界面就会
 * 一直显示 AV1，用户看到的现象是「我选了 AV1，为什么实际是 264」。
 */
function actualCodecOf(k: KernelApi, id: string): { codec?: string; container?: string } {
  const roots = [sessionDirOf(k, id), path.join(k.paths.dataDir, 'hls', id)];
  for (const root of roots) {
    // 分段续转时 `.session.json` 写在 pN 子目录里，根目录下没有
    const dirs = [root];
    try {
      for (const n of fs.readdirSync(root)) {
        if (/^p\d+$/.test(n)) dirs.push(path.join(root, n));
      }
    } catch {
      // 目录还没建
    }
    for (const dir of dirs) {
      try {
        const j = JSON.parse(fs.readFileSync(path.join(dir, '.session.json'), 'utf8')) as {
          codec?: unknown;
          container?: unknown;
        };
        if (typeof j?.codec === 'string' && j.codec) {
          return {
            codec: j.codec,
            container: typeof j.container === 'string' ? j.container : undefined,
          };
        }
      } catch {
        // 还没出片 / 文件被清掉了：保持会话行里的请求值
      }
    }
  }
  return {};
}

const toItem = (
  r: SessionRow,
  token?: string,
  transcodedMs = 0,
) => ({
  id: r.id,
  itemId: r.item_id,
  preset: r.preset,
  codec: r.codec,
  container: r.container,
  subtitle: r.subtitle,
  status: r.status,
  segments: Number(r.segments),
  transcodedMs,
  leadMs: Number(r.lead_ms ?? 0),
  startedMs: Number(r.start_ms ?? 0),
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

/** 会话产物目录（与 HLS 路由共用同一套 tempDir 解析） */
const sessionDirOf = (k: KernelApi, id: string) => path.join(hlsRootOf(k), id);

/**
 * 分段续转：按 p0 / p1 / ... 顺序读出各段自己的播放列表。
 * 只有真正写出 #EXTINF 的段才算数（ffmpeg 可能正在写半截文件）。
 */
function partsOf(k: KernelApi, id: string): PlaylistPart[] {
  // tempDir 改过配置的库：产物可能留在旧目录，和 HLS 路由的回落顺序保持一致
  const roots = [sessionDirOf(k, id), path.join(k.paths.dataDir, 'hls', id)];
  for (const root of roots) {
    let names: string[];
    try {
      names = fs.readdirSync(root).filter((n) => /^p\d+$/.test(n));
    } catch {
      continue;
    }
    names.sort((a, b) => Number(a.slice(1)) - Number(b.slice(1)));
    const out: PlaylistPart[] = [];
    for (const name of names) {
      try {
        const text = fs.readFileSync(path.join(root, name, 'index.m3u8'), 'utf8');
        if (text.includes('#EXTINF')) out.push({ name, text });
      } catch {
        // 这一段还在落盘，先不算
      }
    }
    if (out.length > 0) return out;
  }
  return [];
}

const transcodedMsOf = (parts: PlaylistPart[]) =>
  parts.reduce((sum, p) => sum + playlistDurationMs(p.text), 0);

/**
 * 静态点播播放列表：**按片源时长预列全部分片名**，`PLAYLIST-TYPE:VOD` + ENDLIST。
 *
 * 为什么不直接把 ffmpeg 边写边追加的 EVENT 列表丢给播放器：
 * EVENT 没有 ENDLIST，播放器按直播语义处理，会从**末尾**几片起播、并一直等新片；
 * 而且首片没落盘时列表是空的，播放器第一次 open 直接失败，第二次（会话已有分片）
 * 才正常 —— 就是「第一次打不开、重开就好」。
 * 点播列表让播放器从 seg00000 开始按序拉；某一片还没转出来时，由分片路由
 * 负责等待（见下），播放器不会碰到「空的 m3u8」。
 *
 * 分片名与 pump 的分段续转对齐：每段 leadMs/6s 片、各自独立编号，
 * 用 `?part=pN` 指到对应子目录；跨段插 DISCONTINUITY。
 * fMP4 只在开头声明一次 MAP（指向 p0 的 init.mp4，各段内容相同）。
 */
async function buildStaticVodPlaylist(
  k: KernelApi,
  session: string,
  row: SessionRow,
  token: string,
): Promise<string | null> {
  const totalMs = await sourceDurationMsOf(k, row.item_id);
  const actual = actualCodecOf(k, session);
  const codec = actual.codec || row.codec || 'h264';
  const container =
    actual.container || row.container || (codec === 'h264' ? 'mpegts' : 'fmp4');
  const fmp4 = container === 'fmp4';
  const ext = fmp4 ? 'm4s' : 'ts';
  const leadMs = Math.max(0, Number(row.lead_ms) || 0);
  // 0 = 用户显式选「整片一次转完」，单目录不分段
  const segPerPart = leadMs > 0 ? Math.max(1, Math.ceil(leadMs / 6000)) : 0;
  const startMs = Math.max(0, Number(row.start_ms) || 0);
  const remainMs = Math.max(0, totalMs - startMs);
  // 片源时长还没入库（刚扫描完 / 探测失败）时也不能退回 EVENT 列表：
  // 用已转出的片数先给一个可播列表，后续分片由播放器按序拉取。
  const totalSegs =
    remainMs > 0
      ? Math.max(1, Math.ceil(remainMs / 6000))
      : Math.max(1, Number(row.segments) || 1);
  const t = encodeURIComponent(token);

  const lines = [
    '#EXTM3U',
    `#EXT-X-VERSION:${fmp4 ? 7 : 3}`,
    '#EXT-X-TARGETDURATION:6',
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:VOD',
    '#EXT-X-START:TIME-OFFSET=0',
  ];
  // fMP4 只声明**一次** MAP，指向 p0 的 init.mp4。
  //
  // 分段续转每段各跑一次 ffmpeg，但编码参数固定，实测同一会话 20+ 段的
  // init.mp4 MD5 完全相同 —— 本来就是同一份初始化信息。以前每段重新声明
  // MAP，libmpv 跨段却不会重新拉 p1 的 init（日志里 p1 请求从 seg00001 起，
  // 完全没有 init.mp4 请求），按新 MAP 重置 demuxer 后拿不到初始化段，
  // 直接报 Failed to recognize file format。只写一次就没有这个歧义。
  if (fmp4) {
    lines.push(`#EXT-X-MAP:URI="init.mp4${segPerPart > 0 ? '?part=p0&' : '?'}t=${t}"`);
  }
  // DISCONTINUITY 仍按段插入：各段 PTS 从 0 重新开始，播放器需要它。
  let lastPart: string | null = null;
  for (let i = 0; i < totalSegs; i += 1) {
    const part = segPerPart > 0 ? `p${Math.floor(i / segPerPart)}` : '';
    const local = segPerPart > 0 ? i % segPerPart : i;
    const q = part ? `?part=${part}&t=${t}` : `?t=${t}`;
    if (part !== lastPart) {
      if (lastPart !== null) lines.push('#EXT-X-DISCONTINUITY');
      lastPart = part;
    }
    const dur = i === totalSegs - 1 ? Math.max(0.1, (remainMs - i * 6000) / 1000) : 6;
    lines.push(`#EXTINF:${dur.toFixed(3)},`);
    lines.push(`seg${String(local).padStart(5, '0')}.${ext}${q}`);
  }
  lines.push('#EXT-X-ENDLIST');
  return `${lines.join('\n')}\n`;
}

const segmentCountOf = (parts: PlaylistPart[]) =>
  parts.reduce((sum, p) => sum + (p.text.match(/#EXTINF/g) || []).length, 0);

async function sourceDurationMsOf(k: KernelApi, itemId: string): Promise<number> {
  const rows = (
    await sql<{ duration: number | null }>`
      select duration from video_items where id = ${itemId}
    `.execute(k.db)
  ).rows;
  return Math.max(0, Number(rows[0]?.duration) || 0);
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

/**
 * 播放器最近的轮询位置（会话 id → 最后一次带 pos 的查询）。
 *
 * 续转原来只靠 `pos + 半个 leadMs >= 已转出末尾` 一个条件：播放器一旦因为缺片
 * 卡住，pos 就不再前进，于是永远等不到续转 —— 实测「播 3 分钟就死、重开会话
 * 又死一次、13 个会话全卡在 paused」。这里记下真实播放位置，转完一段就能自己
 * 判断要不要接着预取，不必等下一次轮询把条件凑满。
 */
const lastPoll = new Map<string, { at: number; pos: number }>();
/** 超过这个时间没轮询就当没人看了（关页 / 换片），不再预取 */
const POLL_ACTIVE_MS = 120_000;
/** 已转出末尾领先播放位置多少算「够用」。1.5 段留给转码 ~40s 的余量 */
const AHEAD_FACTOR = 1.5;

/** 只领先播放位置有限几段：既不断流，也不会没人看时一路把整片烧完 */
function shouldKeepAhead(pos: number, transcodedMs: number, leadMs: number): boolean {
  if (leadMs <= 0) return false;
  return transcodedMs - pos <= Math.round(leadMs * AHEAD_FACTOR);
}

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
    const requestedCodec = job.codec ?? 'h264';
    const effectiveCodec = requestedCodec;
    const audioIndex = Number(job.audio_index ?? 0);
    await sql`update player_sessions set hdr_to_sdr = ${hdrToSdr ? 1 : 0} where id = ${job.id}`.execute(
      k.db,
    );
    const filters: string[] = [];
    if (normalize) filters.push('dynaudnorm');
    // 降混双声道：aformat 把 5.1 / 7.1 压成 stereo，单声道不会再被升混
    if (Number(job.audio_downmix) === 1) filters.push('aformat=channel_layouts=stereo');
    // 分段续转：leadMs=0（用户显式选整片）时完全走原来的「一次转完整片」单目录路径；
    // >0（默认 3 分钟）时每段一个 pN 子目录，ffmpeg 只转 [已转出位置, +leadMs) 这一截。
    const leadMs = Math.max(0, Number(job.lead_ms) || 0);
    // 起转位置：>0 表示这个会话是从片源中途开始的（进度条跳到了未转码的位置）。
    // 每段都是「从片头算」的绝对位置，所以 seekMs 一律是 startMs + 已转出长度。
    const startMs = Math.max(0, Number(job.start_ms) || 0);
    const parts = leadMs > 0 ? partsOf(k, job.id) : [];
    const alreadyMs = transcodedMsOf(parts);
    const transcodedMs = startMs + alreadyMs;
    const totalMs = leadMs > 0 ? await sourceDurationMsOf(k, job.item_id) : 0;
    const outDir = leadMs > 0 ? path.join(dir, `p${parts.length}`) : dir;
    const res = await k.media.hls(src, outDir, {
      preset: job.preset,
      codec: effectiveCodec,
      subtitle: job.subtitle ?? undefined,
      audioFilter: filters.length ? filters.join(',') : undefined,
      hwaccel: String(tconf.hwaccel || 'auto'),
      audioIndex,
      hdrToSdr,
      // 「原画」能否直接 copy 取决于片源：AV1/HEVC 复制进 TS 解不出来
      srcVideoCodec: media?.video_codec ?? undefined,
      seekMs: leadMs > 0 || startMs > 0 ? transcodedMs : undefined,
      limitMs: leadMs > 0 ? leadMs : undefined,
    });
    k.log.info(
      {
        session: job.id,
        encoder: res.encoder,
        decoder: res.decoder,
        pipeline: res.pipeline,
        vendor: res.vendor,
        dvProfile: res.source?.dvProfile ?? 0,
        hdrKind: res.source?.hdrKind ?? 'none',
        hi10p: res.source?.hi10p ?? false,
        codec: res.codec,
        ms: res.ms,
      },
      'player hls done',
    );
    // 这一段转完：片源还没到头就标 paused，等播放位置靠近了再续下一段。
    // 这样用户看 10 分钟就关掉，服务端最多只多转一个 leadMs，不会再烧整片。
    const doneParts = leadMs > 0 ? partsOf(k, job.id) : [];
    // 已转出的是「片源里的绝对位置」：起点偏移 + 各段时长之和。
    const doneMs = startMs + transcodedMsOf(doneParts);
    const more = leadMs > 0 && totalMs > 0 && doneMs < totalMs - 1000; 
    // 播放器还在轮询、且播放位置离已转出末尾不远 → 直接接着转下一段。
    // 这是「播 3 分钟必死」的解药：以前要等 pos 追到末尾前 90s 才续，而播放器
    // 缺片卡住时 pos 根本不动，两边互等 —— 现在由转码侧主动往前铺一段。
    const poll = lastPoll.get(job.id);
    const keepGoing =
      more &&
      !!poll &&
      Date.now() - poll.at < POLL_ACTIVE_MS &&
      shouldKeepAhead(poll.pos, doneMs, leadMs);
    const segments = leadMs > 0 ? segmentCountOf(doneParts) : res.segments;
    await sql`
      update player_sessions
      set status = ${more ? (keepGoing ? 'pending' : 'paused') : 'done'}, segments = ${segments},
          codec = ${res.codec ?? effectiveCodec},
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
      // 分段会话的 ffmpeg 写在 pN 子目录里，取消要精确指向那一段
      const parts = partsOf(k, row.id);
      const dir = parts.length
        ? path.join(sessionDirOf(k, row.id), parts[parts.length - 1].name)
        : sessionDirOf(k, row.id);
      await k.media.cancel(dir);
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

/**
 * HLS 分片目录的保留时长。
 *
 * 转码产物是**大件**：4K 档实测一小时片子 6~7GB。以前没有任何清理逻辑，
 * 一台天天看片的机器几个月就能堆几十 GB（2026-11-07 实测 28GB / 21 个会话）。
 * 保留策略：
 *   - 已结束（done / failed / canceled）→ 6 小时，够看完一遍 + 当天回头重看；
 *   - paused（用户中间暂停、等着续播）→ 24 小时，隔天回来还能接着播；
 *   - running / pending 但 24 小时没动过（内核中途崩过留下的）→ 当垃圾清掉。
 */
const HLS_TTL_DONE_SEC = 6 * 3600;
const HLS_TTL_PAUSED_SEC = 24 * 3600;
const HLS_TTL_STALE_SEC = 24 * 3600;
/** 扫盘间隔：半小时一次，开销就是一次 select + 几个 rm */
const HLS_SWEEP_MS = 30 * 60 * 1000;

async function sweepHls(k: KernelApi): Promise<number> {
  const t = now();
  const rows = (
    await sql<{ id: string }>`
      select id from player_sessions
       where (status in ('done', 'failed', 'canceled') and updated_at < ${t - HLS_TTL_DONE_SEC})
          or (status = 'paused' and updated_at < ${t - HLS_TTL_PAUSED_SEC})
          or (status in ('pending', 'running') and created_at < ${t - HLS_TTL_STALE_SEC})
    `.execute(k.db)
  ).rows;
  const root = hlsRootOf(k);

  for (const row of rows) {
    await fsp.rm(path.join(root, row.id), { recursive: true, force: true }).catch(() => undefined);
    await sql`delete from player_sessions where id = ${row.id}`.execute(k.db);
  }

  // 孤儿目录：会话行已经不在了（手工删过库 / 旧版本从没清理过），按最后修改时间收
  try {
    const alive = new Set(
      (await sql<{ id: string }>`select id from player_sessions`.execute(k.db)).rows.map(
        (r) => r.id,
      ),
    );
    const names = await fsp.readdir(root).catch(() => [] as string[]);
    for (const name of names) {
      if (alive.has(name)) continue;
      const dir = path.join(root, name);
      const st = await fsp.stat(dir).catch(() => null);
      if (!st || !st.isDirectory()) continue;
      if (t * 1000 - st.mtimeMs < HLS_TTL_STALE_SEC * 1000) continue;
      await fsp.rm(dir, { recursive: true, force: true }).catch(() => undefined);
    }
  } catch {
    // hls 根还不存在 / 没权限：下次再说，别让清理把启动搞挂
  }

  if (rows.length > 0) k.log.info({ removed: rows.length }, 'player hls sessions swept');
  return rows.length;
}

export const videoPlayer: ServerModule = {
  id: 'videoPlayer',
  prefix: '/api/v1/player',
  permissions: ['video:read', 'video:write'],

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
    {
      id: '135_player_lead',
      async up(db) {
        // 提前转码时长（毫秒）。列默认值 / 老数据 0 = 整片一次转完，行为不变；
        // 新会话建会话时显式写 lead_ms（不传参数 = 3 分钟），不受这个旧列默认影响。
        const cols = (
          (await sql`pragma table_info(player_sessions)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        if (!cols.includes('lead_ms')) {
          await sql`alter table player_sessions add column lead_ms integer not null default 0`.execute(db);
        }
      },
    },
    {
      id: '141_player_start',
      async up(db) {
        // 起转偏移（毫秒）：进度条拖到「还没转出来」的位置时，从中途另起一个会话。
        // 默认 0 = 从片头转，老行为不变（老会话的产物时间轴本来就以片头为准）。
        const cols = (
          (await sql`pragma table_info(player_sessions)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        if (!cols.includes('start_ms')) {
          await sql`alter table player_sessions add column start_ms integer not null default 0`.execute(db);
        }
      },
    },
  ],

  async register(app, k) {
    for (const schema of PLAYER_SCHEMAS) app.addSchema(schema);
    // 重叠模式（开发实例 + 另一个实例在跑）：会话表与分片目录都是共享的，
    // 重置 running 会打断正式版正在转的会话，pump 也会领走它的任务。
    if (k.background.enabled) {
      await sql`update player_sessions set status = 'pending' where status = 'running'`.execute(k.db);
      pump(k).catch((err) => k.log.warn({ err: String(err) }, 'player pump stopped'));
      // 清过期分片：启动先扫一遍（把上次的垃圾收掉），之后每半小时一次
      sweepHls(k).catch((err) => k.log.warn({ err: String(err) }, 'player hls sweep failed'));
      setInterval(() => {
        sweepHls(k).catch((err) => k.log.warn({ err: String(err) }, 'player hls sweep failed'));
      }, HLS_SWEEP_MS).unref?.();
    } else {
      k.log.info('[dev] 重叠模式：跳过播放器会话领取与 HLS 分片清理');
    }

    app.post(
      '/api/v1/player/sessions',
      secured('video:write', {
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
        // 重叠模式不创建转码会话：会话表共享，正式版的 pump 会把它领走执行
        if (!k.background.enabled) {
          return reply
            .code(503)
            .send({ error: Err.unavailable, message: '开发实例已跳过后台转码（检测到另一个实例）' });
        }
        const body = (req.body || {}) as {
          id?: string;
          preset?: string;
          codec?: string;
          subtitle?: string;
          audioNormalize?: boolean;
          audioDownmix?: boolean;
          audioIndex?: number;
          forceSdr?: boolean;
          leadMinutes?: number;
          startMs?: number;
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
        // 提前转码时长：分钟 → 毫秒。不传 / 非法值 = 3 分钟（所有端统一默认）；
        // 显式 0 才是用户选了「整片一次转完」，走原来的单目录路径。
        const rawLead =
          body.leadMinutes == null ? DEFAULT_LEAD_MINUTES : Number(body.leadMinutes);
        const leadMin =
          Number.isFinite(rawLead) && rawLead >= 0
            ? Math.min(60, Math.round(rawLead))
            : DEFAULT_LEAD_MINUTES;
        const leadMs = leadMin * 60_000;
        // 起转偏移：进度条跳到还没转出来位置时客户端会带上它。
        // 夹到 [0, 片源时长 - 1s]，别让一个离谱的值建出一个空会话。
        const srcMs = await sourceDurationMsOf(k, body.id as string);
        const rawStart = Math.max(0, Math.round(Number(body.startMs) || 0));
        const startMs =
          srcMs > 0 ? Math.min(rawStart, Math.max(0, srcMs - 1000)) : rawStart;
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
               and coalesce(lead_ms, 0) = ${leadMs}
               and coalesce(start_ms, 0) = ${startMs}
               and status in ('pending', 'running', 'paused', 'done')
               and created_at > ${ts - 7 * 86400}
             order by created_at desc limit 1
          `.execute(k.db)
        ).rows[0];
        if (dupe) {
          // 内核重启可能留下 pending 会话、没有 pump 在跑，顺手补一次
          pump(k).catch((err) => k.log.warn({ err: String(err) }, 'player pump stopped'));
          // 点播列表按片长预列全部分片，不需要等首片；返回地址即可起播
          return {
            id: dupe.id,
            url: urlOf(dupe.id, hlsToken(k, dupe.id)),
            startedMs: Number(dupe.start_ms ?? 0),
          };
        }
        // 换档 / 重试：同一部片还在排队或正在转的旧会话先取消，
        // 否则新会话只能排在它后面（4K 转不动的片实测能把队列堵 50 分钟）。
        await supersedeOlder(k, body.id as string);
        await sql`
          insert into player_sessions
            (id, item_id, preset, codec, subtitle, audio_normalize, audio_downmix,
             audio_index, force_sdr, hdr_to_sdr, lead_ms, start_ms, status, created_at, updated_at)
          values (${id}, ${body.id}, ${preset}, ${codec},
                  ${subtitle}, ${audioNormalize}, ${audioDownmix},
                  ${audioIndex}, ${forceSdr}, ${forceSdr}, ${leadMs}, ${startMs}, 'pending', ${ts}, ${ts})
        `.execute(k.db);
        pump(k).catch((err) => k.log.warn({ err: String(err) }, 'player pump stopped'));
        // 不再等首片：播放列表是即时生成的静态 VOD 列表，播放器按序拉分片，
        // 还没转出来的那一片由分片路由等待（点播放到出画面不再有 20s 空转）。
        return { id, url: urlOf(id, hlsToken(k, id)), startedMs: startMs };
      },
    );

    app.get(
      '/api/v1/player/sessions',
      secured('video:read', {
        schema: {
          operationId: 'playerSessionGet',
          tags: TAG,
          summary: '查询转码会话状态与播放地址',
          querystring: ref('PlayerSessionQuery'),
          response: { 200: ref('PlayerSessionItem'), 404: ref('PlayerErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; pos?: number };
        const pos = Math.max(0, Number(q.pos) || 0);
        const rows = (
          await sql<SessionRow>`select * from player_sessions where id = ${q.id ?? ''}`.execute(
            k.db,
          )
        ).rows;
        if (!rows[0])
          return reply.code(404).send({ error: Err.notFound, message: 'session not found' });
        const row = rows[0];
        // 记下真实播放位置：转码侧据此判断要不要提前铺下一段
        lastPoll.set(row.id, { at: Date.now(), pos });
        if (lastPoll.size > 64) {
          for (const [id, v] of lastPoll) {
            if (Date.now() - v.at > 30 * 60_000) lastPoll.delete(id);
          }
        }
        const leadMs = Math.max(0, Number(row.lead_ms) || 0);
        const startMs = Math.max(0, Number(row.start_ms) || 0);
        const parts = leadMs > 0 ? partsOf(k, row.id) : [];
        // 对内对外都按「片源绝对位置」算：起转偏移 + 各段时长之和。
        const doneMs = transcodedMsOf(parts);
        const transcodedMs = startMs + doneMs;
        // 分段续转的「续」：满足下面任意一条就把 paused 会话放回队列再转一段。
        //   a) 播放位置快追到已转出末尾（老行为，省 CPU）
        //   b) 播放位置还在预取窗口内（shouldKeepAhead）
        // 只留 (a) 就是本次线上事故的死锁点：播放器缺片卡住后 pos 不再前进，
        // (a) 永远不成立，p1 永远不产出。没人轮询时两条都不成立，仍不会空转。
        if (leadMs > 0 && row.status === 'paused' && doneMs > 0) {
          const total = await sourceDurationMsOf(k, row.item_id);
          const threshold = Math.max(30_000, Math.round(leadMs / 2));
          if (
            transcodedMs < total - 1000 &&
            (pos + threshold >= transcodedMs || shouldKeepAhead(pos, transcodedMs, leadMs))
          ) {
            await sql`
              update player_sessions set status = 'pending', updated_at = ${now()}
               where id = ${row.id} and status = 'paused'
            `.execute(k.db);
            row.status = 'pending';
            pump(k).catch((err) => k.log.warn({ err: String(err) }, 'player pump stopped'));
          }
        }
        // 转码中：把 sidecar 自报的实际编码带出来（降级是静默的，不读就看不出来）
        if (row.status === 'running' || row.status === 'pending' || row.status === 'paused') {
          const actual = actualCodecOf(k, row.id);
          if (actual.codec && actual.codec !== row.codec) {
            row.codec = actual.codec;
            if (actual.container) row.container = actual.container;
            await sql`
              update player_sessions set codec = ${row.codec}, container = ${row.container ?? null}
               where id = ${row.id}
            `.execute(k.db);
          }
        }
        return toItem(row, hlsToken(k, row.id), transcodedMs);
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
        // 分片路由可能把会话推回 pending，需要可写
        let liveStatus = sessionStatus;

        const query = (req.query || {}) as { part?: string };
        // 分段续转：URI 里带 `?part=pN`，分片从对应子目录取。
        // 白名单卡死，避免拿这个参数做目录穿越。
        const part = /^p\d{1,3}$/.test(String(query.part || '')) ? String(query.part) : '';
        const scoped = (root: string) => (part ? path.join(root, part) : root);

        // 与 pump() 共用同一套 tempDir 解析；配置变更过的会话再回落默认目录兜底
        let abs = path.join(scoped(path.join(hlsRootOf(k), session)), file);
        if (!fs.existsSync(abs)) {
          const fallback = path.join(scoped(path.join(k.paths.dataDir, 'hls', session)), file);
          if (fs.existsSync(fallback)) abs = fallback;
        }

        const isPlaylist = file === 'index.m3u8';
        // 点播列表：立刻返回一份按片长预列全部分片的 VOD 列表，不等任何分片落盘。
        // 播放器从 seg00000 起播，某个分片还没转出来时由下面的分片路由等待。
        if (isPlaylist) {
          const full = (
            await sql<SessionRow>`select * from player_sessions where id = ${session}`.execute(k.db)
          ).rows[0];
          if (full) {
            const vod = await buildStaticVodPlaylist(k, session, full, hlsToken(k, session));
            if (vod) {
              // 装机版排障线索：列表是静态生成的，光看请求日志看不出
              // 到底给了多少片、用哪个容器、是不是分段的。
              k.log.info(
                {
                  session,
                  codec: full.codec,
                  container: full.container,
                  leadMs: full.lead_ms,
                  startMs: full.start_ms,
                  segments: (vod.match(/#EXTINF/g) || []).length,
                  parts: (vod.match(/#EXT-X-DISCONTINUITY/g) || []).length + 1,
                },
                '[player] 静态 VOD 播放列表已生成',
              );
              reply.header('cache-control', 'no-store').type('application/vnd.apple.mpegurl');
              return reply.send(vod);
            }
          }
        }
        // 片源时长缺失时的兜底：仍用 ffmpeg 直出的 EVENT 列表（老行为）
        // 有 pN 分段时，播放列表由服务端实时拼：各段独立的 init / 分片 +
        // 接缝处 DISCONTINUITY，末尾不写 ENDLIST（后面还会续段）。
        const parts = isPlaylist ? partsOf(k, session) : [];
        let body: Buffer | null =
          isPlaylist && parts.length > 0 ? Buffer.from(mergePlaylists(parts), 'utf8') : null;
        // 首片还没落盘时**最多等 2 秒**就回一个空的 EVENT 播放列表。
        //
        // 为什么只等 2s：实测播放器（mpv / libmpv）打开 m3u8 时，服务端只要
        // 3~5 秒没有吐出任何字节，它就自己放弃并报
        // `tcp: ffurl_read returned 0xffffff76` + `Failed to open ...m3u8`。
        // 之前这里等 25s（后来 10s），第一次打开必然踩到 —— 表现为「第一次播
        // 必定失败、关掉重开就好」（第二次会话已有分片，秒回）。
        // 空 EVENT 列表是合法的「还没内容、请按 targetduration 轮询」，
        // hls.js 与 mpv 都会自己再拉，分片一出现就起播。
        if (body === null) {
          // 播放器要的是「下一段」的分片（pN，N = 已转出段数）→ 缓冲见底了。
          // 只等客户端 poll 上报 pos 会死锁：播放器此刻正卡在缺片上、pos 不前进，
          // 续转条件永远凑不满（实测 `seg00016.ts?part=p1` 连等两次 30s）。
          // 这里由服务端直接把它推回队列。
          if (!isPlaylist && part && liveStatus === 'paused') {
            const have = partsOf(k, session);
            if (part === `p${have.length}`) {
              await sql`
                update player_sessions set status = 'pending', updated_at = ${now()}
                 where id = ${session} and status = 'paused'
              `.execute(k.db);
              liveStatus = 'pending';
              pump(k).catch((err) => k.log.warn({ err: String(err) }, 'player pump stopped'));
            }
          }
          // 播放列表（兜底路径）最多等 2s；普通分片等 10s。
          // **init.mp4 例外，等 30s**：fMP4 初始化段是解码器的前置条件，拿不到它
          // 不是「缓冲一下」，而是整场播放直接 fatal。4K DV 源首段实测 20~29s
          // 才产出，10s 就把 init 判超时了（Failed to recognize file format）。
          const waitMs = isPlaylist ? 2_000 : file === 'init.mp4' ? 30_000 : 10_000;
          const deadline = Date.now() + waitMs;
          for (;;) {
            try {
              body = await fsp.readFile(abs);
            } catch {
              body = null;
            }
            const ready = isPlaylist
              ? body !== null && body.toString('utf8').includes('#EXTINF')
              : body !== null && body.length > 0;
            if (ready) break;
            const stillWorking = liveStatus === 'pending' || liveStatus === 'running';
            if ((isPlaylist && !stillWorking) || Date.now() >= deadline) break;
            // 会话可能在这期间失败 / 被取消，别死等
            const st = await statusOf(k, session);
            if (st === 'failed' || st === 'canceled') break;
            if (st === 'pending' || st === 'running') liveStatus = st;
            await new Promise((resolve) => setTimeout(resolve, 200));
          }
        }

        if (body === null) {
          // 分片等不到：写一条日志，否则只能看到 404，判断不出是转码太慢、
          // 会话被取消，还是播放器要了一个根本不会产出的分片。
          if (!isPlaylist) {
            k.log.warn(
              { session, file, part, status: sessionStatus },
              '[player] 分片等待超时',
            );
          }
          // 转码刚启动、首片还没落盘：给一个空的 EVENT 播放列表。
          // hls.js 会按 live 语义定时刷新，分片一出现就能播；
          // 直接 404 会让它判定 fatal，整页变成播放错误。
          if (isPlaylist &&
              (liveStatus === 'pending' || liveStatus === 'running')) {
            reply
              .header('cache-control', 'no-store')
              .type('application/vnd.apple.mpegurl');
            return reply.send(
              '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n' +
                '#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n' +
                '#EXT-X-START:TIME-OFFSET=0\n',
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
          const lines = body
            .toString('utf8')
            .replace(/\r\n/g, '\n')
            .split('\n')
            .map((line) => withToken(line.replace(/\r$/, ''), token));
          // 单段会话（ffmpeg 直出的 index.m3u8）同样要求从 0 秒起播，
          // 否则 EVENT 列表会被当成直播，播放器从最后几片开始然后一直等新片。
          if (!lines.some((line) => line.startsWith('#EXT-X-START'))) {
            const at = lines.findIndex((line) => line.trim() === '#EXTM3U');
            lines.splice(at < 0 ? 0 : at + 1, 0, '#EXT-X-START:TIME-OFFSET=0');
          }
          return reply.send(lines.join('\n'));
        }
        return reply.send(body);
      },
    );
  },
};
