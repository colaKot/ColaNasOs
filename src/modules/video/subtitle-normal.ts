import { proxyFetch } from '../../../kernel/proxy-fetch';
import fs from 'node:fs';
import path from 'node:path';
import { decodeSubtitle, SUB_STATE, unzipFirstSubtitle, writeSubtitleBeside } from './subtitle-fetch';

/**
 * 普通影视（非日本片）自动字幕。
 *
 * 数据源优先级：Assrt（伪射手）→ OpenSubtitles → 迅雷（免配置兜底）。
 * 命中即停，不做跨源合并 —— 同一部片挂两三份字幕只会让播放器挑错。
 *
 * 这里只做「按片名 / 年份 / 季集匹配后下载第一份可用字幕」，
 * 所有网络失败都退回状态码，不抛异常打断整轮扫描。
 */

const UA = 'Mozilla/5.0 (compatible; ColaNasOs/1.0)';
const SUB_EXT = new Set(['.srt', '.ass', '.ssa', '.vtt']);

const NOISE = new Set([
  'bluray', 'blu', 'ray', 'bdrip', 'brrip', 'webrip', 'webdl', 'web', 'dl', 'hdtv',
  'hdrip', 'dvdrip', 'dvd', 'remux', 'uhd', 'fhd', 'hd', 'sd', 'hdr', 'hdr10', 'sdr',
  'dolby', 'vision', 'dv', 'x264', 'x265', 'h264', 'h265', 'hevc', 'avc', 'av1',
  'aac', 'ac3', 'eac3', 'dts', 'dtshd', 'truehd', 'atmos', 'flac', 'ddp', 'dd',
  'proper', 'repack', 'rerip', 'internal', 'limited', 'extended', 'unrated',
  'remastered', 'imax', 'fps', 'mbps', 'kbps', 'chs', 'cht', 'gb', 'big5',
  'chinese', 'zh', 'cn', 'sc', 'tc', 'eng', 'english', 'sub', 'subs', 'subbed',
  'dubbed', 'complete', 'part', 'vol', 'sample', 'trailer', 'cd1', 'cd2',
]);

const CJK_RE = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/;
const THAI_RE = /[\u0e00-\u0e7f]/g;
const CJK_GLOBAL_RE = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/g;

export interface NormalMeta {
  filename: string;
  /** 刮削标题（有就用它，命中率比文件名高） */
  nfoName?: string | null;
  year?: number | null;
  imdbId?: string | null;
}

export interface ParsedName {
  title: string;
  year: number;
  season: number;
  episode: number;
  isEpisode: boolean;
}

/** 同目录下是否已有同名字幕（任意字幕格式） */
export function findSubtitleBeside(absVideo: string): string | null {
  try {
    const dir = path.dirname(absVideo);
    const stem = path.parse(absVideo).name.toLowerCase();
    for (const name of fs.readdirSync(dir)) {
      if (!SUB_EXT.has(path.extname(name).toLowerCase())) continue;
      if (path.parse(name).name.toLowerCase() === stem) return path.join(dir, name);
    }
  } catch {
    /* 目录不可读 = 没有 */
  }
  return null;
}

/** 从文件名 / 刮削标题拆出片名、年份、季集。解析不出来返回 null。 */
export function parseMediaName(meta: NormalMeta): ParsedName | null {
  const nfo = String(meta.nfoName || '').trim();
  const raw = nfo || String(meta.filename || '').trim();
  if (!raw) return null;

  let s = raw.replace(/\.[A-Za-z0-9]{1,6}$/, '');
  s = s.replace(/\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)|（([^）]*)）/g, (_m, a, b, c, d) => {
    const inner = a || b || c || d || '';
    const ym = /(?:19|20)\d{2}/.exec(inner);
    return ym ? ` ${ym[0]} ` : ' ';
  });
  s = s.replace(/[._]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!s) return null;

  let season = 0;
  let episode = 0;
  const se =
    /(?:^|[\s-])S(\d{1,2})\s*E(\d{1,4})(?![0-9])/i.exec(s) ||
    /(?:^|[\s-])(\d{1,2})x(\d{2,3})(?![0-9])/i.exec(s) ||
    /第\s*(\d{1,3})\s*[集话話]/.exec(s);
  if (se) {
    if (se.length >= 3) {
      season = Number(se[1]) || 0;
      episode = Number(se[2]) || 0;
    } else {
      episode = Number(se[1]) || 0;
    }
  }

  let year = 0;
  const ym = /(?:^|[^0-9])((?:19|20)\d{2})(?![0-9])/.exec(s);
  if (ym) year = Number(ym[1]);

  let cut = s.length;
  if (se) cut = Math.min(cut, se.index);
  for (const m of s.matchAll(/[A-Za-z][A-Za-z0-9+.]{1,12}/g)) {
    const w = m[0].toLowerCase().replace(/\.$/, '');
    if (NOISE.has(w) || /^(?:x|h)26[45]$/.test(w)) {
      cut = Math.min(cut, m.index ?? s.length);
      break;
    }
  }
  let head = s.slice(0, cut).trim();
  // 去掉结尾的 -GROUP
  head = head.replace(/\s*[-–—]\s*[A-Za-z0-9@]{2,24}$/, '').trim();
  const title = head
    .split(/\s+/)
    .filter((w) => {
      const lw = w.toLowerCase().replace(/^[-_]+|[-_]+$/g, '');
      if (!lw) return false;
      if (NOISE.has(lw)) return false;
      if (/^(?:19|20)\d{2}$/.test(lw)) return false;
      if (/^\d{3,4}[pi]$/.test(lw)) return false;
      if (/^\d+(?:\.\d+)?(?:fps|mbps|kbps|bit)$/.test(lw)) return false;
      return true;
    })
    .join(' ')
    .trim();
  if (!title || /^[\d\s]+$/.test(title)) return null;

  return {
    title,
    year: year || Number(meta.year) || 0,
    season,
    episode,
    isEpisode: episode > 0,
  };
}

function normTokens(text: string): string[] {
  return String(text || '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .split(' ')
    .map((t) => t.trim())
    .filter((t) => t.length > 1);
}

function titleMatches(parsed: ParsedName, text: string): boolean {
  const target = normTokens(parsed.title);
  if (target.length === 0) return false;
  const cand = new Set(normTokens(text));
  let hit = 0;
  for (const t of target) if (cand.has(t)) hit += 1;
  return hit / target.length >= 0.6;
}

function yearMatches(parsed: ParsedName, text: string): boolean {
  if (!parsed.year) return true;
  const m = /(?:^|[^0-9])((?:19|20)\d{2})(?![0-9])/.exec(String(text || ''));
  if (!m) return true;
  return Math.abs(Number(m[1]) - parsed.year) <= 1;
}

function episodeMatches(parsed: ParsedName, text: string): boolean {
  if (!parsed.episode) return true;
  const s = String(text || '');
  const m =
    /(?:^|[^0-9])S(\d{1,2})\s*E(\d{1,4})(?![0-9])/i.exec(s) ||
    /(?:^|[^0-9])(\d{1,2})x(\d{2,3})(?![0-9])/i.exec(s) ||
    /第\s*(\d{1,3})\s*[集话話]/.exec(s);
  if (!m) return false;
  if (m.length >= 3) {
    const ep = Number(m[2]) || 0;
    if (ep !== parsed.episode) return false;
    if (parsed.season && (Number(m[1]) || 0) && Number(m[1]) !== parsed.season) return false;
    return true;
  }
  return (Number(m[1]) || 0) === parsed.episode;
}

function looksChinese(text: string): boolean {
  const t = String(text || '').toLowerCase();
  return CJK_RE.test(t) || /\b(chs|cht|zh|chi|chinese|简|繁|中字|双语|国语)\b/.test(t);
}

function looksThaiSubtitle(text: string): boolean {
  const thai = (String(text || '').match(THAI_RE) || []).length;
  if (thai < 20) return false;
  const cjk = (String(text || '').match(CJK_GLOBAL_RE) || []).length;
  return thai > cjk;
}

function detectFormat(text: string): string | null {
  const t = String(text || '').trim();
  if (!t) return null;
  if (t.includes('-->')) return /^\s*WEBVTT/i.test(t) ? '.vtt' : '.srt';
  if (/^\s*\[Script Info\]/im.test(t) && /^\s*\[Events\]/im.test(t)) return '.ass';
  return null;
}

interface Candidate {
  provider: string;
  name: string;
  chinese: boolean;
  score: number;
  /** 下载描述：provider 自己解释 */
  payload: Record<string, unknown>;
}

async function fetchJson(url: string, init: RequestInit = {}): Promise<any | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  try {
    // 走系统代理：字幕源（assrt / opensubtitles / 迅雷）都在境外或有地域限制
    const res = await proxyFetch(url, {
      ...init,
      signal: controller.signal,
      headers: {
        'user-agent': UA,
        accept: 'application/json',
        ...(init.headers as Record<string, string> | undefined),
      },
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function fetchBuffer(url: string): Promise<Buffer | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30_000);
  try {
    // 走系统代理：字幕源（assrt / opensubtitles / 迅雷）都在境外或有地域限制
    const res = await proxyFetch(url, {
      signal: controller.signal,
      redirect: 'follow',
      headers: { 'user-agent': UA },
    });
    if (!res.ok) return null;
    return Buffer.from(await res.arrayBuffer());
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** 任意下载内容 → 字幕文本 + 扩展名（zip 自动解包） */
function bufferToSubtitle(buffer: Buffer): { text: string; ext: string } | null {
  if (buffer.length === 0) return null;
  if (buffer[0] === 0x50 && buffer[1] === 0x4b) {
    const entry = unzipFirstSubtitle(buffer);
    if (!entry) return null;
    const text = decodeSubtitle(entry.data);
    const ext = detectFormat(text);
    return ext ? { text, ext } : null;
  }
  const text = decodeSubtitle(buffer);
  const ext = detectFormat(text);
  return ext ? { text, ext } : null;
}

async function searchAssrt(token: string, parsed: ParsedName): Promise<Candidate[]> {
  const json = await fetchJson(
    `https://api.assrt.net/v1/sub/search?token=${encodeURIComponent(token)}&q=${encodeURIComponent(
      parsed.title,
    )}&cnt=15&pos=0`,
  );
  const subs = json?.sub?.subs;
  if (!Array.isArray(subs)) return [];
  const out: Candidate[] = [];
  for (const it of subs) {
    const id = Number(it?.id) || 0;
    if (!id) continue;
    const text = [it.native_name, it.videoname, it.title, it.filename].filter(Boolean).join(' ');
    if (!titleMatches(parsed, text) || !yearMatches(parsed, text)) continue;
    if (!episodeMatches(parsed, text)) continue;
    const lang = String(it?.lang?.desc || '');
    const chinese = looksChinese(lang) || looksChinese(it.native_name);
    out.push({
      provider: 'assrt',
      name: String(it.native_name || it.videoname || parsed.title),
      chinese,
      score: (Number(it.vote_score) || 0) + (chinese ? 100 : 0),
      payload: { id },
    });
  }
  out.sort((a, b) => b.score - a.score);
  return out;
}

async function downloadAssrt(token: string, id: number): Promise<Buffer | null> {
  const json = await fetchJson(
    `https://api.assrt.net/v1/sub/detail?token=${encodeURIComponent(token)}&id=${id}`,
  );
  const sub = json?.sub?.subs?.[0];
  if (!sub) return null;
  const files = Array.isArray(sub.filelist) ? sub.filelist : [];
  const ranked = files
    .filter((f: any) => f?.url && SUB_EXT.has(path.extname(String(f.f || '')).toLowerCase()))
    .sort((a: any, b: any) => {
      const ea = path.extname(String(a.f || '')).toLowerCase();
      const eb = path.extname(String(b.f || '')).toLowerCase();
      return (ea === '.srt' ? 0 : 1) - (eb === '.srt' ? 0 : 1);
    });
  const url = String(ranked[0]?.url || sub.url || '');
  if (!url) return null;
  return fetchBuffer(url.startsWith('http://') ? `https://${url.slice(7)}` : url);
}

async function searchOpenSubtitles(apiKey: string, parsed: ParsedName): Promise<Candidate[]> {
  const params = new URLSearchParams({
    languages: 'zh-cn,zh-tw',
    order_by: 'download_count',
    order_direction: 'desc',
    type: parsed.isEpisode ? 'episode' : 'movie',
  });
  params.set('query', parsed.title);
  if (parsed.year) params.set('year', `${parsed.year}`);
  if (parsed.isEpisode) {
    if (parsed.season) params.set('season_number', `${parsed.season}`);
    if (parsed.episode) params.set('episode_number', `${parsed.episode}`);
  }
  const json = await fetchJson(`https://api.opensubtitles.com/api/v1/subtitles?${params}`, {
    headers: { 'api-key': apiKey },
  });
  const list = json?.data;
  if (!Array.isArray(list)) return [];
  const out: Candidate[] = [];
  for (const it of list) {
    const at = it?.attributes;
    const fileId = Number(at?.files?.[0]?.file_id) || 0;
    if (!at || !fileId) continue;
    const text = [
      at.feature_details?.title,
      at.feature_details?.original_title,
      at.release,
      at.files?.[0]?.file_name,
    ].filter(Boolean).join(' ');
    if (!titleMatches(parsed, text) || !yearMatches(parsed, text)) continue;
    if (!episodeMatches(parsed, text)) continue;
    const lang = String(at.language || '');
    out.push({
      provider: 'opensubtitles',
      name: String(at.files?.[0]?.file_name || at.release || parsed.title),
      chinese: lang.startsWith('zh'),
      score: (Number(at.download_count) || 0) + (lang === 'zh-cn' ? 500 : 0),
      payload: { fileId },
    });
  }
  out.sort((a, b) => b.score - a.score);
  return out;
}

async function downloadOpenSubtitles(apiKey: string, fileId: number): Promise<Buffer | null> {
  const json = await fetchJson('https://api.opensubtitles.com/api/v1/download', {
    method: 'POST',
    headers: { 'api-key': apiKey, 'content-type': 'application/json' },
    body: JSON.stringify({ file_id: fileId, sub_format: 'srt' }),
  });
  const link = String(json?.link || '');
  return link ? fetchBuffer(link) : null;
}

const XUNLEI_QUERY_ORIGIN = 'https://api-shoulei-ssl.xunlei.com';
const XUNLEI_QUERY_PATH = '/oracle/subtitle';

/** 字幕检索地址统一在这里生成，查询串不散落在各个调用点。 */
export function xunleiSubtitleUrl(keyword: string): string {
  const url = new URL(XUNLEI_QUERY_PATH, XUNLEI_QUERY_ORIGIN);
  url.search = `name=${encodeURIComponent(String(keyword || '').trim())}`;
  return url.toString();
}

/** 检索词按「季集 → 年份 → 纯标题」逐级放宽，第一级命中就不再往下试。 */
function subtitleQueries(parsed: ParsedName): string[] {
  const queries: string[] = [];
  if (parsed.isEpisode) {
    const season = String(parsed.season || 0).padStart(2, '0');
    const episode = String(parsed.episode || 0).padStart(2, '0');
    queries.push(parsed.season
      ? `${parsed.title} S${season}E${episode}`
      : `${parsed.title} E${episode}`);
  } else if (parsed.year) {
    queries.push(`${parsed.title} ${parsed.year}`);
  }
  queries.push(parsed.title);
  return queries;
}

async function searchXunlei(parsed: ParsedName): Promise<Candidate[]> {
  const found = new Map<string, Candidate>();
  for (const keyword of subtitleQueries(parsed)) {
    const json = await fetchJson(xunleiSubtitleUrl(keyword));
    const rows = json?.code === undefined || Number(json.code) === 0 ? json?.data : null;
    if (!Array.isArray(rows)) continue;

    for (const row of rows) {
      const url = String(row?.url || '').trim();
      if (!url || found.has(url)) continue;

      const words = [row.name, row.simple_name, Array.isArray(row.languages) ? row.languages.join(' ') : '']
        .filter(Boolean)
        .join(' ');
      if (!titleMatches(parsed, words) || !episodeMatches(parsed, words)) continue;

      const langs: string[] = Array.isArray(row.languages)
        ? row.languages.map((x: unknown) => String(x))
        : [];
      const chinese =
        langs.some((l) => CJK_RE.test(l) || /^zh/i.test(l)) ||
        looksChinese(row.simple_name) ||
        looksChinese(row.name);
      const simplified =
        langs.some((l) => l.includes('简')) ||
        /\bchs\b|zh[-_]?cn/i.test(String(row.name));

      found.set(url, {
        provider: 'xunlei',
        name: String(row.name || row.simple_name || ''),
        chinese,
        score: (chinese ? 100 : 0) + (simplified ? 20 : 0),
        payload: { url },
      });
    }
    if (found.size > 0) break;
  }
  return [...found.values()].sort((a, b) => b.score - a.score);
}

export interface NormalSubtitleOptions {
  assrtToken?: string;
  openSubtitlesKey?: string;
  xunlei?: boolean;
}

export interface NormalSubtitleResult {
  state: number;
  reason: string;
  provider?: string;
}

/**
 * 给一条普通影视补字幕。成功时字幕已写到视频同目录（与视频同名）。
 * 返回 `SUB_STATE` 状态码，调用方直接落库。
 */
export async function fetchNormalSubtitle(
  absVideo: string,
  meta: NormalMeta,
  opts: NormalSubtitleOptions = {},
): Promise<NormalSubtitleResult> {
  const parsed = parseMediaName(meta);
  if (!parsed) return { state: SUB_STATE.NO_CODE, reason: 'no_title' };

  const providers: Array<() => Promise<Buffer | null>> = [];
  const label: Array<string> = [];

  if (opts.assrtToken) {
    label.push('assrt');
    providers.push(async () => {
      for (const c of (await searchAssrt(opts.assrtToken!, parsed)).slice(0, 2)) {
        const buf = await downloadAssrt(opts.assrtToken!, Number(c.payload.id) || 0);
        if (buf) return buf;
      }
      return null;
    });
  }
  if (opts.openSubtitlesKey) {
    label.push('opensubtitles');
    providers.push(async () => {
      const cands = (await searchOpenSubtitles(opts.openSubtitlesKey!, parsed)).slice(0, 2);
      for (const c of cands) {
        const buf = await downloadOpenSubtitles(
          opts.openSubtitlesKey!,
          Number(c.payload.fileId) || 0,
        );
        if (buf) return buf;
      }
      return null;
    });
  }
  if (opts.xunlei !== false) {
    label.push('xunlei');
    providers.push(async () => {
      for (const c of (await searchXunlei(parsed)).slice(0, 2)) {
        const buf = await fetchBuffer(String(c.payload.url || ''));
        if (buf) return buf;
      }
      return null;
    });
  }

  if (providers.length === 0) {
    return { state: SUB_STATE.FAILED, reason: 'no_source_configured' };
  }

  for (let i = 0; i < providers.length; i += 1) {
    try {
      const buf = await providers[i]();
      if (!buf) continue;
      const sub = bufferToSubtitle(buf);
      if (!sub) continue;
      if (looksThaiSubtitle(sub.text)) continue;
      writeSubtitleBeside(absVideo, sub.text, sub.ext);
      return { state: SUB_STATE.OK, reason: 'ok', provider: label[i] };
    } catch {
      /* 单个源失败继续下一个 */
    }
  }
  return { state: SUB_STATE.NOT_FOUND, reason: `not_found(${label.join(',')})` };
}
