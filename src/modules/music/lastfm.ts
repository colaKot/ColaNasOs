import crypto from 'node:crypto';
import { sql } from 'kysely';
import { proxyFetch } from '../../../kernel/proxy-fetch';
import { foldHan } from './search-equiv';
import type { KernelApi } from '../../../kernel/types';

/**
 * Last.fm 公开数据源（歌手热门曲目 / 专辑热度）。
 *
 * 只读公开数据，**不需要用户登录授权**，但需要开发者自己申请的 API Key
 * （https://www.last.fm/api/account/create）。Key 存在 `music_settings` 里，
 * 由设置页写入；没配就当没这个源，调用方降级到本地播放量，不报错、不阻塞页面。
 *
 * 三条硬约束（都是踩过的坑）：
 * - 出站统一走 `kernel/proxy-fetch`：Last.fm 在境外，国内直连经常超时；设置页配的
 *   代理会自动生效，不用另配网络。
 * - **必须缓存**：官方建议的免费额度很宽松，但它按 IP 限流，短时间高频并发会被
 *   临时封。所以按方法分别给 24h（专辑）/ 7d（歌手热门）落库缓存，失败不写缓存。
 * - 归一化匹配用 `foldHan`（简繁折叠）：库里是「晴天」、Last.fm 上是「晴天」或
 *   「晴天 (Live)」，直接等值比对命中率极低。
 */

const API_ROOT = 'https://ws.audioscrobbler.com/2.0/';
const UA = 'ColaNasOs/1.0 (personal NAS music metadata)';
const TIMEOUT_MS = 8000;

/** 歌手热门缓存 7 天、专辑热度 24 小时（官方建议 24h 起） */
export const TTL_ARTIST_TOP = 7 * 24 * 3600;
export const TTL_ALBUM_INFO = 24 * 3600;
/** 查不到 / 网络不通时的负缓存：10 分钟内不再打网络，否则每次开页面都等超时 */
const TTL_CROWD_MISS = 10 * 60;
/** 同一个 key 同时只跑一次后台补抓 */
const crowdInFlight = new Set<string>();

export interface FetchResponse {
  ok: boolean;
  status: number;
  headers: { get(name: string): string | null };
  json(): Promise<unknown>;
}

export type FetchLike = (url: string, init?: Record<string, unknown>) => Promise<FetchResponse>;

const defaultFetch: FetchLike = (url, init) =>
  proxyFetch(url, init) as unknown as Promise<FetchResponse>;

let fetchImpl: FetchLike = defaultFetch;

/** 冒烟专用：替换出站请求实现；传 null 恢复真实 proxyFetch */
export function __setLastfmFetch(fn: FetchLike | null): void {
  fetchImpl = fn ?? defaultFetch;
}

// ---------------------------------------------------------------- 配置

export const SETTING_LASTFM_KEY = 'lastfm.api_key';
export const SETTING_LASTFM_SECRET = 'lastfm.secret';

export async function readMusicSetting(k: KernelApi, key: string): Promise<string> {
  const res = await sql<{ value: string }>`
    select value from music_settings where key = ${key}
  `.execute(k.db);
  return String(res.rows[0]?.value ?? '').trim();
}

export async function writeMusicSetting(
  k: KernelApi,
  key: string,
  value: string,
): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  await sql`
    insert into music_settings (key, value, updated_at)
    values (${key}, ${value}, ${now})
    on conflict(key) do update set value = excluded.value, updated_at = excluded.updated_at
  `.execute(k.db);
}

export async function lastfmApiKey(k: KernelApi): Promise<string> {
  const fromDb = await readMusicSetting(k, SETTING_LASTFM_KEY);
  if (fromDb) return fromDb;
  // 环境变量兜底：容器 / 脚本部署时不想开界面填 key 也能量
  return String(process.env.LASTFM_API_KEY ?? '').trim();
}

// ---------------------------------------------------------------- 缓存

interface CacheRow {
  payload: string;
  fetched_at: number;
}

async function readCache(k: KernelApi, key: string, ttl: number): Promise<unknown | null> {
  const res = await sql<CacheRow>`
    select payload, fetched_at from music_lastfm_cache where key = ${key}
  `.execute(k.db);
  const row = res.rows[0];
  if (!row) return null;
  if (Math.floor(Date.now() / 1000) - Number(row.fetched_at) > ttl) return null;
  try {
    return JSON.parse(row.payload);
  } catch {
    return null;
  }
}

async function writeCache(k: KernelApi, key: string, payload: unknown): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  await sql`
    insert into music_lastfm_cache (key, payload, fetched_at)
    values (${key}, ${JSON.stringify(payload)}, ${now})
    on conflict(key) do update set payload = excluded.payload, fetched_at = excluded.fetched_at
  `.execute(k.db);
}

/** 设置页「清理热门缓存」用：删掉全部缓存行，下次访问重新拉 */
export async function clearLastfmCache(k: KernelApi): Promise<number> {
  const res = await sql`delete from music_lastfm_cache`.execute(k.db);
  return Number(res.numAffectedRows ?? 0);
}

// ---------------------------------------------------------------- 请求

async function callApi(
  apiKey: string,
  method: string,
  params: Record<string, string>,
  timeoutMs = TIMEOUT_MS,
): Promise<{ ok: boolean; data: unknown; status: number; error?: string }> {
  const q = new URLSearchParams({ method, api_key: apiKey, format: 'json', ...params });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(`${API_ROOT}?${q.toString()}`, {
      signal: controller.signal,
      headers: { 'user-agent': UA, accept: 'application/json' },
    });
    if (!res.ok) return { ok: false, data: null, status: res.status };
    const data = await res.json();
    // Last.fm 的业务错误是 200 里带 `error` 字段（查无此歌手 / key 无效都是这条）
    const err = (data as { error?: number; message?: string } | null)?.error;
    if (err != null) {
      return {
        ok: false,
        data: null,
        status: res.status,
        error: String((data as { message?: string }).message ?? `lastfm error ${err}`),
      };
    }
    return { ok: true, data, status: res.status };
  } catch {
    return {
      ok: false,
      data: null,
      status: 0,
      error: controller.signal.aborted ? 'timeout' : 'network',
    };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------- 匹配

/**
 * 曲名归一化：简繁折叠 + 小写 + 去掉括号后缀（Live / Remaster / 伴奏 / 电视剧版）
 * + 去掉一切非字母数字汉字。Last.fm 的曲名经常带这些尾巴，库里没有。
 */
export function normTrackName(raw: unknown): string {
  let s = String(raw ?? '');
  // 括号内容（中英文括号都要）：`晴天 (Live)` / `晴天【伴奏】`
  s = s.replace(/[([【（][^)】）]*[)】）]/g, ' ');
  s = s.replace(
    /\s*-\s*(live|remaster(ed)?|remix|acoustic|instrumental|demo|edit|version|mono|stereo)\b.*$/i,
    '',
  );
  return foldHan(s.toLowerCase()).replace(/[^a-z0-9\u4e00-\u9fff]+/g, '');
}

export interface LastfmTopTrack {
  name: string;
  playcount: number;
  listeners: number;
  rank: number;
}

export interface ArtistTopResult {
  /** 是否配置了 API Key；false 时 items 恒空，调用方据此降级 */
  configured: boolean;
  cached: boolean;
  error?: string;
  items: LastfmTopTrack[];
}

function parseTopTracks(data: unknown): LastfmTopTrack[] {
  const raw = (data as { toptracks?: { track?: unknown } } | null)?.toptracks?.track;
  const rows = Array.isArray(raw) ? raw : raw ? [raw] : [];
  const out: LastfmTopTrack[] = [];
  for (const item of rows as Record<string, unknown>[]) {
    const name = String(item?.name ?? '').trim();
    if (!name) continue;
    const attr = item?.['@attr'] as Record<string, unknown> | undefined;
    out.push({
      name,
      playcount: Number(item?.playcount ?? 0) || 0,
      listeners: Number(item?.listeners ?? 0) || 0,
      rank: Number(attr?.rank ?? out.length + 1) || out.length + 1,
    });
  }
  return out;
}

/** 歌手热门曲目（默认 100 首，够覆盖绝大多数歌手；带 7 天落库缓存） */
export async function artistTopTracks(
  k: KernelApi,
  artist: string,
  limit = 100,
): Promise<ArtistTopResult> {
  const name = String(artist ?? '').trim();
  const apiKey = await lastfmApiKey(k);
  if (!apiKey) return { configured: false, cached: false, items: [] };
  if (!name) return { configured: true, cached: false, items: [] };

  const cacheKey = `artist.toptracks:${name.toLowerCase()}:${limit}`;
  const hit = await readCache(k, cacheKey, TTL_ARTIST_TOP);
  if (hit) {
    const items = parseTopTracks(hit);
    if (items.length > 0) return { configured: true, cached: true, items };
  }

  const res = await callApi(apiKey, 'artist.gettoptracks', {
    artist: name,
    limit: String(Math.min(1000, Math.max(1, limit))),
  });
  if (!res.ok) {
    // 查无此歌手不写缓存（可能只是名字写法不对，用户改了就能查到）
    return { configured: true, cached: false, items: [], error: res.error };
  }
  await writeCache(k, cacheKey, res.data);
  return { configured: true, cached: false, items: parseTopTracks(res.data) };
}

export interface AlbumCrowd {
  configured: boolean;
  cached: boolean;
  /** 专辑累计播放次数（Last.fm 口径） */
  playcount: number;
  listeners: number;
  url: string;
  summary: string;
  image: string;
  tags: string[];
}

/** 专辑热度（24h 缓存）；拿不到就全 0，页面照常渲染 */
/**
 * 详情页热度数据的统一取法。以前页面要等 Last.fm 的完整 8 秒超时才出内容，
 * 而且失败不缓存 —— 同一个专辑每点一次都卡 8 秒。
 * 现在：命中缓存直接回；未命中前台只等 1.2 秒，超时/失败就先回空热度，
 * 后台用完整超时补抓并写缓存；确定性失败写 10 分钟负缓存。
 */
async function crowdLookup(
  k: KernelApi,
  apiKey: string,
  opts: {
    cacheKey: string;
    method: string;
    params: Record<string, string>;
    parse: (data: unknown, cached: boolean) => AlbumCrowd;
    empty: AlbumCrowd;
  },
): Promise<AlbumCrowd> {
  const cached = await readCache(k, opts.cacheKey, TTL_ALBUM_INFO);
  if (cached) return opts.parse(cached, true);

  const missKey = `miss:${opts.cacheKey}`;
  if (await readCache(k, missKey, TTL_CROWD_MISS)) {
    return { ...opts.empty, configured: true, cached: true };
  }

  // 关键：**完全不在前台等网络**。缓存没命中就后台慢慢抓，
  // 页面立刻拿本地信息渲染；抓到后写缓存，客户端静默刷新时就能读到。
  if (!crowdInFlight.has(opts.cacheKey)) {
    crowdInFlight.add(opts.cacheKey);
    void (async () => {
      try {
        const res = await callApi(apiKey, opts.method, opts.params);
        if (res.ok) {
          await writeCache(k, opts.cacheKey, res.data);
        } else {
          // 查无此专辑 / key 无效 / 网络超时都做负缓存，别让每次点开都重试
          await writeCache(k, missKey, { __miss: true });
        }
      } catch {
        /* 后台补抓失败不影响页面 */
      } finally {
        crowdInFlight.delete(opts.cacheKey);
      }
    })();
  }
  return { ...opts.empty, configured: true, cached: false };
}

export async function albumCrowd(
  k: KernelApi,
  artist: string,
  album: string,
): Promise<AlbumCrowd> {
  const empty: AlbumCrowd = {
    configured: false,
    cached: false,
    playcount: 0,
    listeners: 0,
    url: '',
    summary: '',
    image: '',
    tags: [],
  };
  const apiKey = await lastfmApiKey(k);
  if (!apiKey) return empty;
  const a = String(artist ?? '').trim();
  const b = String(album ?? '').trim();
  if (!b) return empty;

  const cacheKey = `album.info:${a.toLowerCase()}:${b.toLowerCase()}`;
  return crowdLookup(k, apiKey, {
    cacheKey,
    method: 'album.getinfo',
    params: { artist: a, album: b },
    parse: parseAlbumCrowd,
    empty,
  });
}

function parseAlbumCrowd(data: unknown, cached: boolean): AlbumCrowd {
  const album = (data as { album?: Record<string, unknown> } | null)?.album;
  if (!album) {
    return {
      configured: true,
      cached,
      playcount: 0,
      listeners: 0,
      url: '',
      summary: '',
      image: '',
      tags: [],
    };
  }
  const images = Array.isArray(album.image) ? (album.image as Record<string, unknown>[]) : [];
  const largest =
    [...images].reverse().find((i) => String(i?.['#text'] ?? '').trim() !== '') ?? {};
  const tagsRaw = (album.tags as { tag?: unknown } | undefined)?.tag;
  const tagRows = Array.isArray(tagsRaw) ? tagsRaw : tagsRaw ? [tagsRaw] : [];
  return {
    configured: true,
    cached,
    playcount: Number(album.playcount ?? 0) || 0,
    listeners: Number(album.listeners ?? 0) || 0,
    url: String(album.url ?? ''),
    summary: String((album.wiki as { summary?: string } | undefined)?.summary ?? '')
      // Last.fm 的 wiki 尾巴固定带一段「Read more on Last.fm」+ 版权声明
      .replace(/\s*<a href="https:\/\/www\.last\.fm.*$/s, '')
      .replace(/<[^>]+>/g, '')
      .trim(),
    image: String(largest?.['#text'] ?? ''),
    tags: tagRows
      .map((t) => String((t as Record<string, unknown>)?.name ?? '').trim())
      .filter((x) => x !== '')
      .slice(0, 6),
  };
}

/**
 * 歌手热门 → 「归一化曲名 → 排名」映射。多个 Last.fm 条目归一后重名时取排名靠前的。
 * 也给出该曲的 Last.fm 播放量，用于列表里的热度徽标。
 */
export function rankMap(top: LastfmTopTrack[]): Map<string, LastfmTopTrack> {
  const out = new Map<string, LastfmTopTrack>();
  for (const t of top) {
    const key = normTrackName(t.name);
    if (!key) continue;
    const prev = out.get(key);
    if (!prev || t.rank < prev.rank) out.set(key, t);
  }
  return out;
}

/** 歌手整体的听众 / 播放量 / 简介（歌手页头部用，24h 缓存） */
export async function artistCrowd(k: KernelApi, artist: string): Promise<AlbumCrowd> {
  const empty: AlbumCrowd = {
    configured: false,
    cached: false,
    playcount: 0,
    listeners: 0,
    url: '',
    summary: '',
    image: '',
    tags: [],
  };
  const name = String(artist ?? '').trim();
  const apiKey = await lastfmApiKey(k);
  if (!apiKey) return empty;
  if (!name) return { ...empty, configured: true };

  const cacheKey = `artist.info:${name.toLowerCase()}`;
  return crowdLookup(k, apiKey, {
    cacheKey,
    method: 'artist.getinfo',
    params: { artist: name },
    parse: parseArtistCrowd,
    empty,
  });
}

function parseArtistCrowd(data: unknown, cached: boolean): AlbumCrowd {
  const artist = (data as { artist?: Record<string, unknown> } | null)?.artist;
  if (!artist) {
    return {
      configured: true,
      cached,
      playcount: 0,
      listeners: 0,
      url: '',
      summary: '',
      image: '',
      tags: [],
    };
  }
  const stats = artist.stats as { listeners?: unknown; playcount?: unknown } | undefined;
  const bio = artist.bio as { summary?: string } | undefined;
  const images = Array.isArray(artist.image) ? (artist.image as Record<string, unknown>[]) : [];
  const largest =
    [...images].reverse().find((i) => String(i?.['#text'] ?? '').trim() !== '') ?? {};
  const tagsRaw = (artist.tags as { tag?: unknown } | undefined)?.tag;
  const tagRows = Array.isArray(tagsRaw) ? tagsRaw : tagsRaw ? [tagsRaw] : [];
  return {
    configured: true,
    cached,
    playcount: Number(stats?.playcount ?? 0) || 0,
    listeners: Number(stats?.listeners ?? 0) || 0,
    url: String(artist.url ?? ''),
    summary: String(bio?.summary ?? '')
      .replace(/\s*<a href="https:\/\/www\.last\.fm.*$/s, '')
      .replace(/<[^>]+>/g, '')
      .trim(),
    image: String(largest?.['#text'] ?? ''),
    tags: tagRows
      .map((t) => String((t as Record<string, unknown>)?.name ?? '').trim())
      .filter((x) => x !== '')
      .slice(0, 6),
  };
}

// ================================================================
// 账号绑定 + Scrobble（写操作，需要 api_sig 签名）
// ================================================================
//
// 读取公开数据只要 API Key；**代表用户写数据**（scrobble）需要 session key，
// 而 session key 只能走 Last.fm 自己的授权流程拿到：
//
//   auth.getToken → 浏览器打开 last.fm/api/auth → 用户点同意
//     → Last.fm 带着 token 重定向到我们注册的回调地址
//     → 回调里用 token 换 auth.getSession → 长期 session key
//
// 流程不是 OAuth 2.0：没有 client_secret 换 code 那一步，全靠 **MD5 签名**
// （参数按 ASCII 排序拼成 key1value1key2value2… + API Secret 取 MD5）。

/** Key + Secret（Secret 只在服务端用，永远不回客户端） */
export async function lastfmCreds(
  k: KernelApi,
): Promise<{ apiKey: string; secret: string }> {
  const apiKey =
    (await readMusicSetting(k, SETTING_LASTFM_KEY)) ||
    String(process.env.LASTFM_API_KEY ?? '').trim();
  const secret =
    (await readMusicSetting(k, SETTING_LASTFM_SECRET)) ||
    String(process.env.LASTFM_API_SECRET ?? '').trim();
  return { apiKey, secret };
}

/**
 * 计算 api_sig。
 *
 * 规则：除 `format` / `api_sig` 外的所有参数按参数名 ASCII 升序，
 * 依次拼 `key + value`，末尾直接接 API Secret，取 MD5（小写 32 位十六进制）。
 */
export function lastfmSig(params: Record<string, string>, secret: string): string {
  const keys = Object.keys(params)
    .filter((key) => key !== 'format' && key !== 'api_sig' && key !== 'callback')
    .sort();
  let raw = '';
  for (const key of keys) raw += key + params[key];
  return crypto.createHash('md5').update(raw + secret, 'utf8').digest('hex');
}

interface SignedResult {
  ok: boolean;
  data: unknown;
  status: number;
  error?: string;
}

/** 带签名的 POST（写操作统一走这里，Last.fm 要求非 GET 请求带 api_sig） */
async function callApiSigned(
  apiKey: string,
  secret: string,
  method: string,
  params: Record<string, string>,
): Promise<SignedResult> {
  const all: Record<string, string> = { method, api_key: apiKey, ...params };
  const form = new URLSearchParams({
    ...all,
    api_sig: lastfmSig(all, secret),
    format: 'json',
  });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetchImpl(API_ROOT, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'user-agent': UA,
        'content-type': 'application/x-www-form-urlencoded',
        accept: 'application/json',
      },
      body: form.toString(),
    });
    const data = await res.json();
    const err = (data as { error?: number; message?: string } | null)?.error;
    if (err != null) {
      return {
        ok: false,
        data: null,
        status: res.status,
        error: String((data as { message?: string }).message ?? `lastfm error ${err}`),
      };
    }
    if (!res.ok) return { ok: false, data: null, status: res.status, error: `HTTP ${res.status}` };
    return { ok: true, data, status: res.status };
  } catch {
    return { ok: false, data: null, status: 0, error: 'network' };
  } finally {
    clearTimeout(timer);
  }
}

/** 第一步：拿临时 token，拼出浏览器授权地址 */
export async function lastfmAuthStart(
  k: KernelApi,
): Promise<{ ok: boolean; token?: string; url?: string; error?: string }> {
  const { apiKey, secret } = await lastfmCreds(k);
  if (!apiKey || !secret) return { ok: false, error: 'missing_credentials' };
  const res = await callApiSigned(apiKey, secret, 'auth.getToken', {});
  if (!res.ok) return { ok: false, error: res.error ?? 'auth.getToken failed' };
  const token = String((res.data as { token?: string } | null)?.token ?? '').trim();
  if (!token) return { ok: false, error: 'empty token' };
  return {
    ok: true,
    token,
    url: `https://www.last.fm/api/auth/?api_key=${encodeURIComponent(apiKey)}&token=${encodeURIComponent(token)}`,
  };
}

/** 第三步：用回调里的 token 换长期 session key */
export async function lastfmAuthSession(
  k: KernelApi,
  token: string,
): Promise<{ ok: boolean; sessionKey?: string; userName?: string; error?: string }> {
  const { apiKey, secret } = await lastfmCreds(k);
  if (!apiKey || !secret) return { ok: false, error: 'missing_credentials' };
  const res = await callApiSigned(apiKey, secret, 'auth.getSession', { token });
  if (!res.ok) return { ok: false, error: res.error ?? 'auth.getSession failed' };
  const session = (res.data as { session?: { key?: string; name?: string } } | null)?.session;
  const sessionKey = String(session?.key ?? '').trim();
  if (!sessionKey) return { ok: false, error: 'empty session' };
  return { ok: true, sessionKey, userName: String(session?.name ?? '') };
}

// ---------------------------------------------------------------- 账户表

export interface LastfmAccount {
  ownerId: string;
  sessionKey: string;
  userName: string;
}

export async function lastfmAccountOf(
  k: KernelApi,
  ownerId: string,
): Promise<LastfmAccount | null> {
  const res = await sql<{ owner_id: string; session_key: string; username: string }>`
    select owner_id, session_key, username from music_lastfm_accounts where owner_id = ${ownerId}
  `.execute(k.db);
  const row = res.rows[0];
  if (!row || !String(row.session_key ?? '').trim()) return null;
  return {
    ownerId: row.owner_id,
    sessionKey: String(row.session_key),
    userName: String(row.username ?? ''),
  };
}

export async function saveLastfmAccount(
  k: KernelApi,
  ownerId: string,
  sessionKey: string,
  userName: string,
): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  await sql`
    insert into music_lastfm_accounts (owner_id, session_key, username, updated_at)
    values (${ownerId}, ${sessionKey}, ${userName}, ${now})
    on conflict(owner_id) do update set
      session_key = excluded.session_key,
      username = excluded.username,
      updated_at = excluded.updated_at
  `.execute(k.db);
}

export async function unlinkLastfmAccount(k: KernelApi, ownerId: string): Promise<void> {
  await sql`delete from music_lastfm_accounts where owner_id = ${ownerId}`.execute(k.db);
}

/**
 * 回调是浏览器直接打开的（不带 JWT），所以用临时 token 反查「是哪个用户发起的」。
 * 存 `music_settings` 就够了：一次绑定只留一行，成功后删掉。
 */
export async function savePendingToken(
  k: KernelApi,
  token: string,
  ownerId: string,
): Promise<void> {
  await writeMusicSetting(k, `lastfm.pending.${token}`, ownerId);
}

/** 只读不消费：给「我已完成授权」这条兜底路径校验 token 归属 */
export async function peekPendingToken(k: KernelApi, token: string): Promise<string> {
  return readMusicSetting(k, `lastfm.pending.${token}`);
}

export async function takePendingToken(k: KernelApi, token: string): Promise<string> {
  const key = `lastfm.pending.${token}`;
  const ownerId = await readMusicSetting(k, key);
  if (!ownerId) return '';
  await writeMusicSetting(k, key, '');
  return ownerId;
}

// ---------------------------------------------------------------- Scrobble

export interface ScrobbleInput {
  artist: string;
  track: string;
  album?: string;
  /** 播放开始时间（Unix 秒） */
  timestamp: number;
  /** 秒，可选；带上能让 Last.fm 正确判断播放时长 */
  durationSec?: number;
}

/**
 * 上报一次播放。
 *
 * 用户侧的阈值判断（30s 且 > 50%）由客户端做 —— 服务端只负责签名与转发，
 * 不做业务判断，避免「换客户端重新调一遍阈值」。
 */
export async function lastfmScrobble(
  k: KernelApi,
  sessionKey: string,
  input: ScrobbleInput,
): Promise<{ ok: boolean; accepted: number; ignored: number; error?: string }> {
  const { apiKey, secret } = await lastfmCreds(k);
  if (!apiKey || !secret) return { ok: false, accepted: 0, ignored: 0, error: 'missing_credentials' };
  const params: Record<string, string> = {
    artist: input.artist,
    track: input.track,
    timestamp: String(Math.floor(input.timestamp)),
    sk: sessionKey,
  };
  if (input.album) params.album = input.album;
  if (input.durationSec && input.durationSec > 0) {
    params.duration = String(Math.round(input.durationSec));
  }
  const res = await callApiSigned(apiKey, secret, 'track.scrobble', params);
  if (!res.ok) return { ok: false, accepted: 0, ignored: 0, error: res.error };
  const attr = (
    res.data as { scrobbles?: { '@attr'?: { accepted?: number; ignored?: number } } } | null
  )?.scrobbles?.['@attr'];
  return {
    ok: true,
    accepted: Number(attr?.accepted ?? 0) || 0,
    ignored: Number(attr?.ignored ?? 0) || 0,
  };
}

/** 正在播放（可选）：让 Last.fm 主页实时显示当前曲目 */
export async function lastfmNowPlaying(
  k: KernelApi,
  sessionKey: string,
  input: Omit<ScrobbleInput, 'timestamp'>,
): Promise<boolean> {
  const { apiKey, secret } = await lastfmCreds(k);
  if (!apiKey || !secret) return false;
  const params: Record<string, string> = {
    artist: input.artist,
    track: input.track,
    sk: sessionKey,
  };
  if (input.album) params.album = input.album;
  if (input.durationSec && input.durationSec > 0) {
    params.duration = String(Math.round(input.durationSec));
  }
  const res = await callApiSigned(apiKey, secret, 'track.updateNowPlaying', params);
  return res.ok;
}
