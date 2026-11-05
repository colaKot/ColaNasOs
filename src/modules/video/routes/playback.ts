import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { secured } from '../../../../kernel/route';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { writePoster } from '../ffmpeg';
import { isOfflinePath, offlineSmbPrefixes } from '../sources';
import { Err } from '../../../../kernel/errors';
import { TAG } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/**
 * 片源兼容性：Web/PC 直链解不了 DV/HDR/HEVC/AV1 等，提示客户端改走 HLS 转码。
 * 只读 video_items 行，列缺失一律按「不需要转码」兜底，不抛错。
 */
function compatOf(row: unknown): {
  needTranscode: boolean;
  reasons: string[];
  videoCodec: string | null;
  audioCodec: string | null;
  container: string | null;
  width: number | null;
  height: number | null;
  is4k: boolean;
} {
  const r = (row || {}) as Record<string, unknown>;
  const on = (v: unknown) => Number(v) === 1;
  const vc = r.video_codec == null ? '' : String(r.video_codec).toLowerCase();
  const ac = r.audio_codec == null ? '' : String(r.audio_codec).toLowerCase();
  const width = r.width == null ? null : Number(r.width);
  const height = r.height == null ? null : Number(r.height);
  // 容器（按扩展名）：浏览器只能解 MP4 / WebM 这类，MKV / AVI 一律 demux 失败。
  // 桌面端 mpv 能直接播，所以这里只回传容器，是否强制转码由客户端按平台判断。
  const rel = String(r.rel_path || '');
  const dot = rel.lastIndexOf('.');
  const container = dot > 0 ? rel.slice(dot + 1).toLowerCase() : null;

  const dv = on(r.dolby_vision);
  const hdr10 = on(r.hdr10);
  const hdr10plus = on(r.hdr10plus);
  const hlg = on(r.hlg);
  const atmos = on(r.dolby_atmos) || ac.includes('atmos');
  const is4k = on(r.is_4k) || (width ?? 0) >= 3840 || (height ?? 0) >= 2160;
  const hevc = /hevc|h265/.test(vc);
  const av1 = /av1/.test(vc);
  const vp9 = /vp9/.test(vc);
  const h264 = /h264|avc/.test(vc);
  const badAudio = /eac3|ac3|truehd|dts|mlp/.test(ac);

  const needTranscode =
    dv || hdr10 || hdr10plus || hlg ||
    hevc || av1 || vp9 || (is4k && vc !== '' && !h264) ||
    badAudio || atmos;

  // reasons 只描述片源特征，固定词表，别 invent
  const reasons: string[] = [];
  if (dv) reasons.push('dolbyVision');
  if (hdr10) reasons.push('hdr10');
  if (hdr10plus) reasons.push('hdr10plus');
  if (hlg) reasons.push('hlg');
  if (hevc) reasons.push('hevc');
  if (av1) reasons.push('av1');
  if (dv || hdr10 || hdr10plus || hlg) reasons.push('10bit'); // HDR/DV 均为 10-bit
  if (/eac3|ac3/.test(ac)) reasons.push('eac3');
  if (/truehd|mlp/.test(ac)) reasons.push('truehd');
  if (atmos) reasons.push('atmos');

  return {
    needTranscode,
    reasons,
    videoCodec: r.video_codec == null ? null : String(r.video_codec),
    audioCodec: r.audio_codec == null ? null : String(r.audio_codec),
    container,
    width,
    height,
    is4k,
  };
}

/** 海报 / 播放 */
export async function registerVideoPlayback(app: FastifyInstance, k: KernelApi, h: VideoHelpers): Promise<void> {
  /** 正在后台生成的海报（按输出路径去重：同一个条目多个请求只抽一次） */
  const posterPending = new Set<string>();

  /**
   * 网络盘上的首帧放到后台生成。
   *
   * 为什么不让请求等：抽帧槽位只有 2 个（`withPosterSlot`），而 UNC 上抽一帧要先把
   * 文件头几个 MB 读过来；一个列表页十几张卡同时来，槽位立刻被占满，
   * 「打开库」就变成等几十秒出图（2026-11-03 反馈）。
   * 现在第一次访问先给 404（前端显示占位），后台抽完落盘，刷新一次图就有了。
   */
  const queuePoster = (out: string, abs: string, durationMs: number | null): void => {
    if (posterPending.has(out)) return;
    posterPending.add(out);
    void writePoster(abs, out, durationMs)
      .catch(() => false)
      .finally(() => posterPending.delete(out));
  };

  /** UNC 路径（`\\host\share\...`）：这种来源的读盘代价比本地盘高两个数量级 */
  const isNetworkPath = (rel: string): boolean => /^[\\/]{2}/.test(String(rel || ''));

  // ---------------------------------------------------------------- 海报 / 播放

    app.get(
      '/api/v1/video/poster',
      secured('video:read', {
        schema: {
          operationId: 'videoPoster',
          tags: TAG,
          summary: '影片海报（首次访问生成，之后走文件缓存）',
          querystring: h.ref('VideoIdQuery'),
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadAnyItem(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'item not found' });
        // SMB 离线：直接 404，不碰网络盘（同步 stat 死机会把整个内核拖住）
        if (isOfflinePath(row.rel_path, await offlineSmbPrefixes(k.db))) {
          return reply.code(404).send({ error: Err.notFound, message: 'source offline' });
        }

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
        // 异步存在性检查：网络盘挂掉时不会阻塞事件循环
        try {
          await fsp.access(abs);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }

        // 图片条目：海报就是原图（前端网格通常还会走 /files/thumb 缩略图）
        if (String(row.media_type || '') === 'image') {
          reply
            .type(String(row.container || 'application/octet-stream'))
            .header('cache-control', 'public, max-age=86400');
          return reply.send(fs.createReadStream(abs));
        }

        const hash = crypto
          .createHash('sha1')
          .update(`${row.rel_path}:${row.mtime}`)
          .digest('hex')
          .slice(0, 32);
        const out = path.join(k.paths.dataDir, 'posters', `${hash}.jpg`);

        if (!fs.existsSync(out)) {
          fs.mkdirSync(path.dirname(out), { recursive: true });
          if (isNetworkPath(row.rel_path)) {
            queuePoster(out, abs, row.duration);
            return reply.code(404).send({ error: Err.notFound, message: 'poster generating' });
          }
          const ok = await writePoster(abs, out, row.duration);
          if (!ok) {
            return reply.code(404).send({ error: Err.notFound, message: 'poster unavailable' });
          }
        }

        reply.type('image/jpeg').header('cache-control', 'public, max-age=86400');
        return reply.send(fs.createReadStream(out));
      },
    );

    app.get(
      '/api/v1/video/stream-url',
      secured('video:read', {
        schema: {
          operationId: 'videoStreamUrl',
          tags: TAG,
          summary: '生成带短期令牌的播放地址（可直接交给外部播放器）',
          querystring: h.ref('VideoIdQuery'),
          response: { 200: h.ref('VideoStreamUrlResponse'), 404: h.ref('VideoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadItem(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });

        // 外部播放器无法带 Authorization 头：签一个只含 video:read 的令牌。
        //
        // 有效期 12 小时（原 5 分钟）：5 分钟连「暂停去洗个澡」都撑不过 ——
        // 暂停期间连接被回收后 ffmpeg 重连就是 401，表现为「看一半断了」。
        // 自用 NAS 场景下这个令牌只能读一部片，长一点的风险远小于体验损失；
        // 客户端另有「令牌过期即静默重签 + 从原位置续播」的兜底。
        const expiresInSec = 12 * 3600;
        const token = k.auth.sign({ sub: 'video-stream', scopes: ['video:read'] }, expiresInSec);
        return {
          url: `/api/v1/video/stream?id=${encodeURIComponent(row.id)}&token=${encodeURIComponent(token)}`,
          expiresInSec,
          compat: compatOf(row),
        };
      },
    );

}
