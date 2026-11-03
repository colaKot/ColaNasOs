import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

/**
 * 日本片自动字幕：avsubtitles.com 五步链路。
 *
 * 实测要点（少一条就失败）：
 * 1. 搜索 → movie 页 → 字幕列表页，取 **subid 最大**（最新）；
 * 2. `download_page.php` 先种 `PHPSESSID`；
 * 3. 页面里 `let countdown = 6`，**必须等过倒计时**再请求下载，否则 302 到 error_403；
 * 4. `download_sub.php` 必须带 **Referer=download_page**，返回 application/zip；
 * 5. 未登录每天 **5 个**上限（返回纯文本 "cannot download more than 5 subtitles a day"）
 *    ⇒ 遇到就整轮中止，不要继续重试。
 *
 * zip 用内置 zlib 解（不引第三方依赖）：只取第一个 .srt/.ass/.vtt。
 */
export const SUB_STATE = {
  PENDING: 0,
  OK: 1,
  NO_CODE: 2,
  NOT_FOUND: 3,
  NO_CHINESE: 4,
  FAILED: 5,
} as const;

export type SubState = (typeof SUB_STATE)[keyof typeof SUB_STATE];

export interface SubtitleResult {
  state: SubState;
  reason: string;
  /** 命中每日上限：调用方应中止整轮 */
  limitReached?: boolean;
  text?: string;
}

interface ZipEntry {
  name: string;
  data: Buffer;
}

export function unzipFirstSubtitle(buffer: Buffer): ZipEntry | null {
  let eocd = -1;
  const min = Math.max(0, buffer.length - 70_000);
  for (let i = buffer.length - 22; i >= min; i -= 1) {
    if (buffer.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return null;

  const count = buffer.readUInt16LE(eocd + 10);
  let off = buffer.readUInt32LE(eocd + 16);
  for (let i = 0; i < count; i += 1) {
    if (off + 46 > buffer.length || buffer.readUInt32LE(off) !== 0x02014b50) break;
    const method = buffer.readUInt16LE(off + 10);
    const compSize = buffer.readUInt32LE(off + 20);
    const nameLen = buffer.readUInt16LE(off + 28);
    const extraLen = buffer.readUInt16LE(off + 30);
    const commentLen = buffer.readUInt16LE(off + 32);
    const localOff = buffer.readUInt32LE(off + 42);
    const name = buffer.toString('utf8', off + 46, off + 46 + nameLen);

    if (/\.(srt|ass|ssa|vtt)$/i.test(name) && localOff + 30 <= buffer.length) {
      const localNameLen = buffer.readUInt16LE(localOff + 26);
      const localExtraLen = buffer.readUInt16LE(localOff + 28);
      const start = localOff + 30 + localNameLen + localExtraLen;
      const raw = buffer.subarray(start, start + compSize);
      try {
        const data = method === 0 ? Buffer.from(raw) : zlib.inflateRawSync(raw);
        return { name, data };
      } catch {
        return null;
      }
    }
    off += 46 + nameLen + extraLen + commentLen;
  }
  return null;
}

/** 字幕编码：BOM（UTF-16LE）→ UTF-8 校验 → GBK 兜底 */
export function decodeSubtitle(buffer: Buffer): string {
  if (buffer.length >= 2 && buffer[0] === 0xff && buffer[1] === 0xfe) {
    return buffer.subarray(2).toString('utf16le');
  }
  const utf8 = buffer.toString('utf8');
  if (!utf8.includes('\uFFFD')) return utf8.replace(/^\uFEFF/, '');
  try {
    return new TextDecoder('gbk').decode(buffer);
  } catch {
    return utf8;
  }
}

const LIMIT_RE = /cannot download more than \d+ subtitles a day/i;

export interface FetchSubtitleOptions {
  base?: string;
  /** 已登录的 PHPSESSID（未登录也能下，但每天 5 个） */
  cookie?: string;
  timeoutMs?: number;
  /** 倒计时等待上限；测试传 0 */
  waitMs?: number;
  fetchImpl?: typeof fetch;
}

async function get(
  url: string,
  opts: FetchSubtitleOptions,
  extra: Record<string, string> = {},
): Promise<{ text: string; buffer: Buffer; headers: Headers } | null> {
  const doFetch = opts.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(2000, opts.timeoutMs ?? 12_000));
  try {
    const res = await doFetch(url, {
      signal: controller.signal,
      redirect: 'manual',
      headers: {
        'user-agent': 'Mozilla/5.0 (compatible; ColaNasOs/1.0)',
        ...(opts.cookie ? { cookie: opts.cookie } : {}),
        ...extra,
      },
    });
    if (res.status >= 300 && res.status < 400) return null;
    if (!res.ok) return null;
    const buffer = Buffer.from(await res.arrayBuffer());
    return { text: buffer.toString('utf8'), buffer, headers: res.headers };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** 从搜索页取 movie 详情链接（取第一个匹配片号的） */
export function pickMovieLink(html: string, code: string): string | null {
  const norm = code.toUpperCase().replace(/[^A-Z0-9]/g, '');
  const re = /<a[^>]+href="(\/movie[\d]+[^"]*)"[^>]*>([\s\S]{0,200}?)<\/a>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const text = m[2].toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (text.includes(norm)) return m[1];
  }
  // 兜底：页面里链接本身含片号
  const direct = /href="(\/movie[\d]+[^"]*)"/i.exec(html);
  return direct ? direct[1] : null;
}

/** 字幕列表里取 subid 最大的中文条目 */
export function pickLatestChineseSub(html: string): { subId: string; href: string } | null {
  const re = /href="([^"]*\/subtitles\/[^"]*zh\/(\d+)[^"]*)"/gi;
  let best: { subId: string; href: string } | null = null;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const id = Number(m[2]);
    if (!best || id > Number(best.subId)) best = { subId: m[2], href: m[1] };
  }
  return best;
}

/**
 * 抓一条字幕。`waitMs` 是倒计时等待（默认 6500ms；测试可设 0）。
 * 返回 `limitReached` 时调用方必须中止整轮。
 */
export async function fetchSubtitle(
  code: string,
  opts: FetchSubtitleOptions = {},
): Promise<SubtitleResult> {
  const base = (opts.base || 'https://avsubtitles.com').replace(/\/$/, '');
  const clean = String(code || '')
    .toUpperCase()
    .trim();
  if (!clean) return { state: SUB_STATE.NO_CODE, reason: 'no_code' };

  const search = await get(`${base}/search_results.php?search=${encodeURIComponent(clean)}`, opts);
  if (!search) return { state: SUB_STATE.FAILED, reason: 'search_failed' };
  if (LIMIT_RE.test(search.text)) {
    return { state: SUB_STATE.FAILED, reason: 'daily_limit', limitReached: true };
  }

  const movieHref = pickMovieLink(search.text, clean);
  if (!movieHref) return { state: SUB_STATE.NOT_FOUND, reason: 'movie_not_found' };

  const movie = await get(`${base}${movieHref}`, opts);
  if (!movie) return { state: SUB_STATE.FAILED, reason: 'movie_page_failed' };

  const sub = pickLatestChineseSub(movie.text);
  if (!sub) return { state: SUB_STATE.NO_CHINESE, reason: 'no_chinese_sub' };

  const subPage = await get(`${base}${sub.href}`, opts);
  if (!subPage) return { state: SUB_STATE.FAILED, reason: 'sub_page_failed' };

  const subId = /name="subid"\s+value="(\d+)"/i.exec(subPage.text)?.[1] ?? sub.subId;
  const revId = /name="revid"\s+value="(\d+)"/i.exec(subPage.text)?.[1] ?? '';
  const countdown = Number(/countdown\s*=\s*(\d+)/i.exec(subPage.text)?.[1] ?? 6);

  const downloadPage = `${base}/download_page.php?subid=${subId}&revid=${revId}`;
  const dpage = await get(downloadPage, opts);
  if (!dpage) return { state: SUB_STATE.FAILED, reason: 'download_page_failed' };

  // 倒计时没走完直接下 → 302 / error_403
  const wait =
    opts.waitMs ?? (Number.isFinite(countdown) ? Math.max(0, countdown) * 1000 + 500 : 6500);
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));

  const file = await get(`${base}/download_sub.php?subid=${subId}&revid=${revId}`, opts, {
    referer: downloadPage,
  });
  if (!file) return { state: SUB_STATE.FAILED, reason: 'download_failed' };
  if (LIMIT_RE.test(file.text)) {
    return { state: SUB_STATE.FAILED, reason: 'daily_limit', limitReached: true };
  }

  const entry = unzipFirstSubtitle(file.buffer);
  if (!entry) return { state: SUB_STATE.FAILED, reason: 'zip_invalid' };
  const text = decodeSubtitle(entry.data);
  if (!text.trim()) return { state: SUB_STATE.FAILED, reason: 'empty_subtitle' };

  return { state: SUB_STATE.OK, reason: 'ok', text };
}

/** 落盘：与视频同名同目录（保留原扩展名） */
export function writeSubtitleBeside(videoAbs: string, text: string, ext = '.srt'): string {
  const target = path.join(
    path.dirname(videoAbs),
    `${path.basename(videoAbs, path.extname(videoAbs))}${ext}`,
  );
  fs.writeFileSync(target, text, 'utf-8');
  return target;
}
