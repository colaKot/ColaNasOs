import fs from 'node:fs';
import path from 'node:path';
import { TextDecoder } from 'node:util';

/**
 * 外挂字幕（零依赖）：`.srt` / `.ass` / `.ssa` / `.vtt` → 结构化 cue 与 WebVTT。
 *
 * 发现规则：与影片**同目录、同主名**的字幕；语言后缀跟在主名之后（`Movie.zh-Hans.srt`）。
 *   例：`Breaking Bad/S01E01.mkv` → `S01E01.srt` / `S01E01.zh.srt` / `S01E01.eng.ass`
 *
 * 解析边界：
 *   - 单文件 ≤ 5 MB、cue ≤ 5000 条，超界截断（不影响播放，只是后面的行不返回）
 *   - ASS 只取 `[Events]` 的 `Dialogue:`，按 `Format:` 的列名定位 Start / End / Text
 *   - 文本里的样式标签（`<i>`、`{\an8}`）一律剥离，`\N` 转真换行
 *   - 编码依次尝试 UTF-8 / GB18030 / Big5（`TextDecoder` 内置，不引第三方库）
 */

export type SubtitleFormat = 'srt' | 'ass' | 'ssa' | 'vtt';

export interface SubtitleFile {
  /** 同目录下的文件名（含扩展名），作为取内容的键 */
  name: string;
  /** 主名之后的后缀，如 `zh-Hans`；没有则为 null */
  lang: string | null;
  format: SubtitleFormat;
  size: number;
}

export interface SubtitleCue {
  startMs: number;
  endMs: number;
  text: string;
}

export const MAX_SUBTITLE_BYTES = 5 * 1024 * 1024;
export const MAX_CUES = 5000;

const FORMATS: ReadonlySet<string> = new Set(['srt', 'ass', 'ssa', 'vtt']);

/** 列出同目录同主名的字幕文件（按语言、文件名排序） */
export function listSubtitles(absVideo: string): SubtitleFile[] {
  const dir = path.dirname(absVideo);
  const ext = path.extname(absVideo);
  const base = path.basename(absVideo, ext);
  const baseLower = base.toLowerCase();

  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }

  const found: SubtitleFile[] = [];
  for (const name of names) {
    const nameExt = path.extname(name);
    const format = nameExt.slice(1).toLowerCase();
    if (!FORMATS.has(format)) continue;

    const stem = name.slice(0, name.length - nameExt.length);
    const stemLower = stem.toLowerCase();
    if (stemLower !== baseLower && !stemLower.startsWith(`${baseLower}.`)) continue;

    let size: number;
    try {
      size = fs.statSync(path.join(dir, name)).size;
    } catch {
      continue;
    }
    found.push({
      name,
      lang: stem.length > base.length ? stem.slice(base.length + 1) : null,
      format: format as SubtitleFormat,
      size,
    });
  }

  found.sort((a, b) => {
    const byLang = (a.lang ?? '').localeCompare(b.lang ?? '');
    return byLang !== 0 ? byLang : a.name.localeCompare(b.name);
  });
  return found;
}

/** 时间串 → 毫秒；`1:02:03,500` 与 `0:00:01.50`（ASS 厘秒）都认 */
function parseTime(raw: string): number | null {
  const m = /(\d{1,3}):(\d{1,2}):(\d{1,2})[,.](\d{1,3})/.exec(raw);
  if (!m) return null;
  const fracRaw = m[4];
  const frac =
    fracRaw.length === 1 ? Number(fracRaw) * 100 : fracRaw.length === 2 ? Number(fracRaw) * 10 : Number(fracRaw);
  const seconds = (Number(m[1]) * 60 + Number(m[2])) * 60 + Number(m[3]);
  return seconds * 1000 + frac;
}

function decodeEntities(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
}

/** 去掉 SRT / VTT 的 HTML 标签与 ASS 的覆盖标签 */
function stripTags(text: string): string {
  return decodeEntities(text.replace(/<[^>]*>/g, '').replace(/\{[^}]*\}/g, '')).trim();
}

/** SRT 与 WebVTT 的 cue 结构一致：`00:00:01,000 --> 00:00:04,000` */
export function parseCueBlocks(raw: string): SubtitleCue[] {
  const cues: SubtitleCue[] = [];
  const normalized = raw.replace(/\r\n?/g, '\n');
  for (const block of normalized.split(/\n{2,}/)) {
    if (cues.length >= MAX_CUES) break;
    const lines = block
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    if (lines.length < 2) continue;

    const arrowAt = lines.findIndex((line) => line.includes('-->'));
    if (arrowAt < 0) continue;

    const [fromRaw, toRaw] = lines[arrowAt].split('-->');
    const startMs = parseTime(fromRaw ?? '');
    const endMs = parseTime(toRaw ?? '');
    if (startMs === null || endMs === null) continue;

    const text = stripTags(lines.slice(arrowAt + 1).join('\n'));
    if (!text) continue;
    cues.push({ startMs, endMs, text });
  }
  return cues;
}

/** ASS / SSA：只取 `[Events]` 的 Dialogue，按 `Format:` 列名定位字段 */
export function parseAss(raw: string): SubtitleCue[] {
  const cues: SubtitleCue[] = [];
  let inEvents = false;
  let columns: string[] = [];

  for (const line of raw.replace(/\r\n?/g, '\n').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      inEvents = /^\[events\]$/i.test(trimmed);
      columns = [];
      continue;
    }
    if (!inEvents) continue;

    if (/^format\s*:/i.test(trimmed)) {
      columns = trimmed
        .slice(trimmed.indexOf(':') + 1)
        .split(',')
        .map((col) => col.trim().toLowerCase());
      continue;
    }
    if (!/^dialogue\s*:/i.test(trimmed)) continue;
    if (cues.length >= MAX_CUES) break;

    const payload = trimmed.slice(trimmed.indexOf(':') + 1);
    const parts = payload.split(',');
    const startAt = columns.indexOf('start');
    const endAt = columns.indexOf('end');
    const textAt = columns.indexOf('text');
    if (startAt < 0 || endAt < 0 || textAt < 0) continue;

    // Text 是最后一列，内部允许逗号；列序异常时退化为单列取值
    const text =
      textAt === columns.length - 1 ? parts.slice(textAt).join(',') : (parts[textAt] ?? '');
    const startMs = parseTime(parts[startAt] ?? '');
    const endMs = parseTime(parts[endAt] ?? '');
    if (startMs === null || endMs === null) continue;

    const cleaned = text
      .replace(/\{[^}]*\}/g, '')
      .replace(/\\N/gi, '\n')
      .replace(/\\h/gi, ' ')
      .trim();
    if (!cleaned) continue;
    cues.push({ startMs, endMs, text: cleaned });
  }
  return cues;
}

/** 按格式解析；`vtt` 先去 `WEBVTT` 头，之后与 SRT 同构 */
export function parseSubtitle(raw: string, format: SubtitleFormat): SubtitleCue[] {
  if (format === 'ass' || format === 'ssa') return parseAss(raw);
  if (format === 'vtt') {
    const body = raw.replace(/\r\n?/g, '\n').replace(/^WEBVTT[^\n]*\n/, '');
    return parseCueBlocks(body);
  }
  return parseCueBlocks(raw);
}

function vttTime(ms: number): string {
  const total = Math.max(0, Math.round(ms));
  const hours = Math.floor(total / 3_600_000);
  const minutes = Math.floor((total % 3_600_000) / 60_000);
  const seconds = Math.floor((total % 60_000) / 1000);
  const millis = total % 1000;
  const pad = (n: number, width: number) => String(n).padStart(width, '0');
  return `${pad(hours, 2)}:${pad(minutes, 2)}:${pad(seconds, 2)}.${pad(millis, 3)}`;
}

/** 结构化 cue → WebVTT 文本（播放器可直接加载） */
export function toWebVtt(cues: SubtitleCue[]): string {
  if (cues.length === 0) return 'WEBVTT\n';
  const body = cues
    .map((cue, i) => `${i + 1}\n${vttTime(cue.startMs)} --> ${vttTime(cue.endMs)}\n${cue.text}`)
    .join('\n\n');
  return `WEBVTT\n\n${body}\n`;
}

/** 解码字幕字节：BOM 感知 + UTF-8 / GB18030 / Big5 依次尝试 */
export function decodeSubtitleText(buf: Buffer): string {
  const body =
    buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf ? buf.subarray(3) : buf;
  for (const encoding of ['utf-8', 'gb18030', 'big5']) {
    try {
      return new TextDecoder(encoding, { fatal: true }).decode(body);
    } catch {
      // 换下一种编码
    }
  }
  return body.toString('utf8');
}

/** 读并解析一条字幕：超过上限直接报错，由调用方翻译成 HTTP 错误 */
export function readSubtitle(
  absVideo: string,
  name: string,
): { file: SubtitleFile; cues: SubtitleCue[]; vtt: string } | null {
  const file = listSubtitles(absVideo).find((f) => f.name === name);
  if (!file) return null;
  if (file.size > MAX_SUBTITLE_BYTES) {
    throw Object.assign(new Error('subtitle too large'), { code: 'tooLarge' });
  }

  const raw = decodeSubtitleText(fs.readFileSync(path.join(path.dirname(absVideo), file.name)));
  const cues = parseSubtitle(raw, file.format);
  return { file, cues, vtt: toWebVtt(cues) };
}