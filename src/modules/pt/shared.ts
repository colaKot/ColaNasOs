import path from 'node:path';
import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import { filesRoot, resolveAnyPath } from '../files/fs-root';
import { ensureDaemon } from './daemon';
import type { TransmissionConfig } from './transmission';

/**
 * PT / RSS 共用：下载设置、影视库根目录、下载器解析。
 *
 * 两个模块都要「把种子交给 transmission 并落到某个目录」，以前各写一份：
 * RSS 那份只读 `pt.transmission`（没手填 RPC 就永远「未配置」，内置 daemon 根本用不上），
 * 目录也直接甩给下载器。这里收成一份，两个模块共用同一套判定。
 */

export const DOWNLOAD_KEY = 'pt.download';

export const DEFAULT_DOWNLOAD = {
  movieLibraryId: '',
  tvLibraryId: '',
  siteIds: [] as string[],
  quality: 'all',
  hdr: 'all',
  audioLangs: [] as string[],
  maxSizeBytes: 0,
  minSeeders: 3,
  excludedKeywords: [] as string[],
  scanIntervalMin: 360,
  autoDownload: true,
};

export function normalizeDownload(raw: unknown): typeof DEFAULT_DOWNLOAD {
  const r = (raw || {}) as Record<string, unknown>;
  const arr = (v: unknown, max: number): string[] =>
    Array.isArray(v)
      ? [...new Set(v.map((e) => String(e).trim()).filter(Boolean))].slice(0, max)
      : [];
  const quality = String(r.quality ?? 'all');
  const hdr = String(r.hdr ?? 'all');
  return {
    movieLibraryId: String(r.movieLibraryId ?? '').slice(0, 64),
    tvLibraryId: String(r.tvLibraryId ?? '').slice(0, 64),
    siteIds: arr(r.siteIds, 100),
    quality: QUALITIES.has(quality) ? quality : 'all',
    hdr: HDRS.has(hdr) ? hdr : 'all',
    audioLangs: arr(r.audioLangs, 20),
    maxSizeBytes: Math.max(0, Number(r.maxSizeBytes) || 0),
    minSeeders: Math.max(0, Math.min(1000, Number(r.minSeeders) || 0)),
    excludedKeywords: arr(r.excludedKeywords, 100),
    scanIntervalMin: Math.max(5, Math.min(360, Number(r.scanIntervalMin) || 360)),
    autoDownload: r.autoDownload !== false,
  };
}

const QUALITIES = new Set(['all', '1080p', '1440p', '4k']);
const HDRS = new Set(['all', 'hdr', 'hdr10', 'hdr10plus', 'dolby']);

export function readDownloadSettings(k: KernelApi): typeof DEFAULT_DOWNLOAD {
  return normalizeDownload(k.config.get<Record<string, unknown>>(DOWNLOAD_KEY));
}

/** 影视库根 → 绝对路径（transmission 可见路径）；库不存在或越界返回空串 */
export async function libraryRootDir(k: KernelApi, id: string): Promise<string> {
  if (!id) return '';
  const row = (
    await sql<{ root_path: string }>`
      select root_path from video_libraries where id = ${id}
    `.execute(k.db)
  ).rows[0];
  if (!row?.root_path) return '';
  try {
    return resolveAnyPath(filesRoot(), row.root_path);
  } catch {
    return '';
  }
}

/**
 * 「默认下载目录」：下载设置里配的电影库根，其次剧集库根，
 * 都没配才退到数据目录下的 downloads（内置 daemon 的默认目录）。
 */
export async function defaultDownloadDir(k: KernelApi): Promise<string> {
  const dl = readDownloadSettings(k);
  const movie = await libraryRootDir(k, dl.movieLibraryId);
  if (movie) return movie;
  const tv = await libraryRootDir(k, dl.tvLibraryId);
  if (tv) return tv;
  return path.join(k.paths.dataDir, 'downloads');
}

/** 用户填的目录（文件夹选择器给的通常是绝对路径）→ 绝对路径；空串原样返回 */
export function normalizeDir(input: string): string {
  const s = String(input || '').trim();
  if (!s) return '';
  try {
    return path.resolve(s);
  } catch {
    return s;
  }
}

/**
 * 目录 → 影视库（按 root_path 精确匹配）。
 * RSS 选了「正好是某个库根」的目录时，下载完就能自动入库，不用再手动扫描。
 */
export async function libraryOfDir(
  k: KernelApi,
  dir: string,
): Promise<{ id: string; type: string } | null> {
  const target = normalizeDir(dir).replace(/\\/g, '/').toLowerCase();
  if (!target) return null;
  const rows = (
    await sql<{ id: string; lib_type: string; root_path: string }>`
      select id, lib_type, root_path from video_libraries
    `.execute(k.db)
  ).rows;
  for (const r of rows) {
    const root = normalizeDir(r.root_path).replace(/\\/g, '/').toLowerCase();
    if (root && root === target) return { id: r.id, type: String(r.lib_type || 'movie') };
  }
  return null;
}

let mode: 'embedded' | 'external' | 'none' = 'none';
let probed: { at: number; cfg: TransmissionConfig | null } = { at: 0, cfg: null };

/** 最近一次解析出来的下载器来源（/pt/torrents 用它拼提示语） */
export function downloaderMode(): 'embedded' | 'external' | 'none' {
  return mode;
}

/**
 * 清掉「本机探测」缓存。自动发现的地址连不上（下载器被关了）时调用，
 * 否则 60s 内会一直复用那个死地址。
 */
export function resetTransmissionProbe(): void {
  probed = { at: 0, cfg: null };
  mode = 'none';
}

/**
 * 本机没配置时自动找 transmission：探 127.0.0.1:9091 的 RPC。
 * 409 也算「在」——transmission 首次请求必然 409 + session-id 头。
 * 结果缓存 60s，避免每 5 秒轮询都去敲端口。
 */
async function probeLocalTransmission(): Promise<TransmissionConfig | null> {
  const nowMs = Date.now();
  if (nowMs - probed.at < 60_000) return probed.cfg;
  for (const port of [9091, 9092]) {
    const url = `http://127.0.0.1:${port}/transmission/rpc`;
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 1200);
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ method: 'session-get' }),
        signal: ctl.signal,
      });
      clearTimeout(timer);
      if (res.status === 200 || res.status === 409) {
        probed = { at: nowMs, cfg: { url } };
        return probed.cfg;
      }
    } catch {
      /* 端口没开，继续下一个 */
    }
  }
  probed = { at: nowMs, cfg: null };
  return null;
}

/**
 * 下载器解析顺序：用户手填的 RPC → 随包内置 daemon（自动拉起）→ 本机探测。
 * PT 的扫描/订阅、RSS 的加种都走这里，避免「只在某个入口能用」。
 */
export async function resolveTransmission(k: KernelApi): Promise<TransmissionConfig | null> {
  const configured = k.config.get<TransmissionConfig>('pt.transmission');
  if (configured?.url) {
    mode = 'external';
    return configured;
  }
  const dir = await defaultDownloadDir(k);
  const embedded = await ensureDaemon({ dataDir: k.paths.dataDir, downloadDir: dir });
  if (embedded) {
    mode = 'embedded';
    return { url: embedded };
  }
  const found = await probeLocalTransmission();
  mode = found ? 'external' : 'none';
  return found;
}
