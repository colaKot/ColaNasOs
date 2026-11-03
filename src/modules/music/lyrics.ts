import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';

/**
 * 歌词读取（零依赖）：
 *   - **LRC 旁挂**：同目录同名 `.lrc`（优先，用户可覆盖内嵌歌词）
 *   - **内嵌 ID3v2**：mp3 的 `USLT`（v2.2 为 `ULT`），编码 0 latin1 / 1 UTF-16+BOM / 2 UTF-16BE / 3 UTF-8
 *   - **内嵌 Vorbis comment**：flac 的 `LYRICS` / `UNSYNCEDLYRICS`；ogg / opus 的同名注释键
 *   - **内嵌 MP4 元数据**：m4a / mp4 的 `©lyr`（`ilst` 下的 `data` atom）
 *
 * LRC 支持 `[mm:ss.xx]` 一行多时间戳、`[offset:±ms]` 与 `[ti:/ar:/al:/by:]` 元信息；
 * 内嵌歌词里带时间戳时同样按 LRC 解析（不少工具就是这么存同步歌词的）。
 *
 * **双语对照**：同目录的 `<base>.<lang>.lrc`（如 `Alpha.en.lrc` / `Alpha.zh-CN.lrc`）
 * 被当作译文，按时间轴对齐后贴到每行的 `translation` 上；时间对不上或数量不一致时不贴。
 *
 * m4a 的 `moov` 可能落在文件尾部（未做 faststart 的封装），头部没命中的这类格式会再读一次尾部。
 */

export type LyricsSource = 'lrc' | 'embedded' | 'none';

export interface LyricsLine {
  /** 毫秒；无时间戳（纯文本歌词）时缺省 */
  timeMs?: number;
  text: string;
  /** 译文（来自旁挂 `<base>.<lang>.lrc`，已按时间轴对齐；没有译文时缺省） */
  translation?: string;
}

export interface LyricsResult {
  source: LyricsSource;
  /** 是否逐行同步（有时间戳） */
  synced: boolean;
  title?: string;
  artist?: string;
  album?: string;
  by?: string;
  lines: LyricsLine[];
}

/** 单次响应上限：行数与单行长度都设闸，避免异常文件把响应撑爆 */
const MAX_LINES = 3000;
const MAX_LINE_CHARS = 500;
/** 只读文件头部：ID3 / Vorbis 都在文件前部 */
export const MAX_HEAD_BYTES = 4 * 1024 * 1024;

const EMPTY: LyricsResult = { source: 'none', synced: false, lines: [] };

const TIME_TAG = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
const META_TAG = /^\[(ti|ar|al|by|offset):(.*)\]$/i;

function trimLine(text: string): string {
  const t = text.replace(/\s+/g, ' ').trim();
  return t.length > MAX_LINE_CHARS ? `${t.slice(0, MAX_LINE_CHARS)}…` : t;
}

/** LRC 文本 → 结构化歌词；没有时间戳时退化为纯文本行 */
export function parseLrc(raw: string): LyricsResult {
  const meta: Record<string, string> = {};
  let offsetMs = 0;
  const lines: LyricsLine[] = [];
  let sawTime = false;
  const plain: string[] = [];

  for (const rawLine of raw.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;

    const metaMatch = META_TAG.exec(line);
    if (metaMatch) {
      const key = metaMatch[1].toLowerCase();
      const value = metaMatch[2].trim();
      if (key === 'offset') {
        const n = Number(value);
        if (Number.isFinite(n)) offsetMs = Math.trunc(n);
      } else {
        meta[key] = value;
      }
      continue;
    }

    TIME_TAG.lastIndex = 0;
    const times: number[] = [];
    let match: RegExpExecArray | null;
    while ((match = TIME_TAG.exec(line)) !== null) {
      const min = Number(match[1]);
      const sec = Number(match[2]);
      const fracRaw = match[3] ?? '';
      // 两位是 1/100 秒，三位是毫秒
      const frac =
        fracRaw.length === 0 ? 0 : fracRaw.length >= 3 ? Number(fracRaw) : Number(fracRaw) * 10;
      times.push(min * 60_000 + sec * 1000 + frac);
    }

    const text = trimLine(line.replace(TIME_TAG, '').trim());
    if (times.length === 0) {
      if (text) plain.push(text);
      continue;
    }
    sawTime = true;
    if (!text) continue;
    for (const t of times) lines.push({ timeMs: Math.max(0, t + offsetMs), text });
  }

  if (!sawTime) {
    return {
      source: 'embedded',
      synced: false,
      ...metaKeys(meta),
      lines: plain.slice(0, MAX_LINES).map((text) => ({ text })),
    };
  }

  lines.sort((a, b) => (a.timeMs ?? 0) - (b.timeMs ?? 0));
  return {
    source: 'embedded',
    synced: true,
    ...metaKeys(meta),
    lines: lines.slice(0, MAX_LINES),
  };
}

function metaKeys(
  meta: Record<string, string>,
): Pick<LyricsResult, 'title' | 'artist' | 'album' | 'by'> {
  return {
    title: meta.ti || undefined,
    artist: meta.ar || undefined,
    album: meta.al || undefined,
    by: meta.by || undefined,
  };
}

// ---------------------------------------------------------------- 双语对照

/** 译文旁挂文件的语言标签：`<base>.zh-CN.lrc` / `<base>.en.lrc` */
const LANG_TAG = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$/;
/** 译文与原文的时间轴允许误差；LRC 打轴常有百毫秒级出入 */
const TRANSLATION_TOLERANCE_MS = 1200;

function normalizeLang(tag: string | undefined): string {
  return (tag ?? '').trim().toLowerCase().replace(/_/g, '-');
}

/**
 * 列出同目录下可作译文的旁挂 LRC（`<base>.<lang>.lrc`）。
 * 指定 `lang` 时精确匹配优先、同语种次之；未指定时中文优先、英文次之。
 */
export function translationLrcCandidates(abs: string, lang?: string): string[] {
  const dir = path.dirname(abs);
  const base = path.basename(abs, path.extname(abs));
  const prefix = `${base}.`.toLowerCase();
  const prefixLen = base.length + 1;
  const wanted = normalizeLang(lang);

  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }

  const score = (tag: string): number => {
    const t = normalizeLang(tag);
    if (wanted) {
      if (t === wanted) return 0;
      if (t.split('-')[0] === wanted.split('-')[0]) return 1;
    } else {
      const head = t.split('-')[0];
      if (head === 'zh') return 0;
      if (head === 'en') return 1;
    }
    return 2;
  };

  const found: { name: string; tag: string }[] = [];
  for (const name of names) {
    if (!name.toLowerCase().endsWith('.lrc')) continue;
    if (!name.toLowerCase().startsWith(prefix)) continue;
    const tag = name.slice(prefixLen, name.length - 4);
    if (!LANG_TAG.test(tag)) continue;
    found.push({ name, tag });
  }

  return found
    .sort((a, b) => score(a.tag) - score(b.tag) || a.tag.localeCompare(b.tag))
    .map((v) => path.join(dir, v.name));
}

/**
 * 把译文贴到原文上（返回新数组，不改入参）。
 * 同步歌词按最近时间轴配对（误差 ≤ 1.2s）；纯文本歌词按行号配对。
 * 一行都没对上时返回原文，避免把不相关的 LRC 当译文。
 */
export function attachTranslation(
  lines: LyricsLine[],
  translation: LyricsLine[],
  synced: boolean,
): LyricsLine[] {
  if (lines.length === 0 || translation.length === 0) return lines;

  if (!synced) {
    let matched = 0;
    const out = lines.map((line, i) => {
      const text = translation[i]?.text;
      if (!text) return line;
      matched += 1;
      return { ...line, translation: text };
    });
    return matched > 0 ? out : lines;
  }

  const timed = translation
    .filter((l): l is LyricsLine & { timeMs: number } => typeof l.timeMs === 'number')
    .slice()
    .sort((a, b) => a.timeMs - b.timeMs);
  if (timed.length === 0) return lines;

  /** 二分找时间轴上最近的一行 */
  const nearest = (ms: number): LyricsLine & { timeMs: number } => {
    let lo = 0;
    let hi = timed.length - 1;
    let at = 0;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (timed[mid].timeMs <= ms) {
        at = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    const next = timed[at + 1];
    if (next && Math.abs(next.timeMs - ms) < Math.abs(timed[at].timeMs - ms)) return next;
    return timed[at];
  };

  let matched = 0;
  const out = lines.map((line) => {
    if (typeof line.timeMs !== 'number') return line;
    const hit = nearest(line.timeMs);
    if (!hit.text || Math.abs(hit.timeMs - line.timeMs) > TRANSLATION_TOLERANCE_MS) return line;
    matched += 1;
    return { ...line, translation: hit.text };
  });
  return matched > 0 ? out : lines;
}

/** ID3v2 解码(编码字节 + Buffer) → 字符串 */
function decodeId3Text(encoding: number, buf: Buffer): string {
  if (encoding === 1) {
    // UTF-16 + BOM
    if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) {
      return buf.subarray(2).toString('utf16le');
    }
    if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) {
      const body = Buffer.from(buf.subarray(2));
      body.swap16();
      return body.toString('utf16le');
    }
    return buf.toString('utf16le');
  }
  if (encoding === 2) {
    const body = Buffer.from(buf);
    if (body.length % 2 === 1) return body.subarray(0, body.length - 1).toString('utf16le');
    body.swap16();
    return body.toString('utf16le');
  }
  if (encoding === 3) return buf.toString('utf8');
  return buf.toString('latin1');
}

function syncsafe(buf: Buffer, offset: number): number {
  return (
    ((buf[offset] & 0x7f) << 21) |
    ((buf[offset + 1] & 0x7f) << 14) |
    ((buf[offset + 2] & 0x7f) << 7) |
    (buf[offset + 3] & 0x7f)
  );
}

/** USLT 帧体：encoding(1) + lang(3) + 描述(终止符) + 歌词 */
function readUsltBody(body: Buffer): { descriptor: string; lyrics: string } | null {
  if (body.length < 5) return null;
  const encoding = body[0];
  const rest = body.subarray(4); // 跳过 encoding + 3 字节语言
  // 描述字段以 0x00（单字节编码）或 0x00 0x00（UTF-16）结尾
  let split = -1;
  if (encoding === 1 || encoding === 2) {
    for (let i = 0; i + 1 < rest.length; i += 2) {
      if (rest[i] === 0 && rest[i + 1] === 0) {
        split = i + 2;
        break;
      }
    }
  } else {
    split = rest.indexOf(0);
    split = split >= 0 ? split + 1 : -1;
  }
  if (split < 0 || split > rest.length) return null;
  return {
    descriptor: decodeId3Text(encoding, rest.subarray(0, Math.max(0, split - 1))).replace(
      /\0/g,
      '',
    ),
    lyrics: decodeId3Text(encoding, rest.subarray(split)).replace(/\0+$/, ''),
  };
}

/** 从 mp3 头部解析 ID3v2 歌词；没有返回 null */
export function readId3Lyrics(head: Buffer): string | null {
  if (head.length < 10 || head.toString('latin1', 0, 3) !== 'ID3') return null;

  const major = head[3];
  const flags = head[5];
  const tagSize = syncsafe(head, 6);
  const body = head.subarray(10, Math.min(head.length, 10 + tagSize));
  if (body.length === 0) return null;

  let pos = 0;
  // 扩展头（v2.3/2.4）：v2.3 是 4 字节普通长度，v2.4 是 syncsafe
  if (flags & 0x40) {
    if (body.length < 4) return null;
    const extSize = major === 4 ? syncsafe(body, 0) : body.readUInt32BE(0) + 4;
    pos += Math.max(4, extSize);
  }

  let fallback: string | null = null;

  while (pos < body.length) {
    if (major === 2) {
      if (pos + 6 > body.length) break;
      const id = body.toString('latin1', pos, pos + 3);
      if (!/^[A-Z0-9]{3}$/.test(id)) break;
      const size = (body[pos + 3] << 16) | (body[pos + 4] << 8) | body[pos + 5];
      const bodyStart = pos + 6;
      if (bodyStart + size > body.length) break;
      if (id === 'ULT') {
        const parsed = readUsltBody(body.subarray(bodyStart, bodyStart + size));
        if (parsed?.lyrics && !fallback) fallback = parsed.lyrics;
        if (parsed?.lyrics && !parsed.descriptor) return parsed.lyrics;
      }
      pos = bodyStart + size;
      continue;
    }

    if (pos + 10 > body.length) break;
    const id = body.toString('latin1', pos, pos + 4);
    if (!/^[A-Z0-9]{4}$/.test(id)) break;
    const size = major === 4 ? syncsafe(body, pos + 4) : body.readUInt32BE(pos + 4);
    const bodyStart = pos + 10;
    if (size <= 0 || bodyStart + size > body.length) break;

    if (id === 'USLT') {
      const parsed = readUsltBody(body.subarray(bodyStart, bodyStart + size));
      if (parsed?.lyrics) {
        if (!parsed.descriptor) return parsed.lyrics;
        if (!fallback) fallback = parsed.lyrics;
      }
    }
    pos = bodyStart + size;
  }

  return fallback;
}

/** 上限：注释条数与单条长度都设闸，异常文件不至于把解析拖死 */
const MAX_COMMENTS = 512;

/**
 * 读 Vorbis comment 结构（`vendorLen + vendor + count + [len + entry]…`）。
 * flac 的 VORBIS_COMMENT 块从 0 开始；ogg / opus 在各自的包头之后。
 */
function readVorbisComments(
  buf: Buffer,
  offset: number,
): { entries: string[]; end: number } | null {
  if (offset + 4 > buf.length) return null;
  const vendorLen = buf.readUInt32LE(offset);
  let at = offset + 4 + vendorLen;
  if (at + 4 > buf.length) return null;
  const count = buf.readUInt32LE(at);
  at += 4;

  const entries: string[] = [];
  for (let i = 0; i < count && entries.length < MAX_COMMENTS; i += 1) {
    if (at + 4 > buf.length) break;
    const len = buf.readUInt32LE(at);
    at += 4;
    if (at + len > buf.length) break;
    entries.push(buf.toString('utf8', at, at + len));
    at += len;
  }
  return { entries, end: at };
}

/** 注释列表里挑歌词：LYRICS / UNSYNCEDLYRICS 优先，SYNCEDLYRICS 兜底 */
function pickVorbisLyrics(entries: string[]): string | null {
  let fallback: string | null = null;
  for (const entry of entries) {
    const eq = entry.indexOf('=');
    if (eq <= 0) continue;
    const key = entry.slice(0, eq).toUpperCase();
    const value = entry
      .slice(eq + 1)
      .replace(/\0+$/, '')
      .trim();
    if (!value) continue;
    if (key === 'LYRICS' || key === 'UNSYNCEDLYRICS' || key === 'UNSYNCED LYRICS') return value;
    if (key === 'SYNCEDLYRICS' && !fallback) fallback = value;
  }
  return fallback;
}

/** 从 flac 头部解析 Vorbis comment 里的歌词；没有返回 null */
export function readFlacLyrics(head: Buffer): string | null {
  if (head.length < 4 || head.toString('latin1', 0, 4) !== 'fLaC') return null;

  let pos = 4;
  while (pos + 4 <= head.length) {
    const header = head[pos];
    const last = (header & 0x80) !== 0;
    const type = header & 0x7f;
    const length = (head[pos + 1] << 16) | (head[pos + 2] << 8) | head[pos + 3];
    const start = pos + 4;
    const end = start + length;
    if (end > head.length) return null;

    if (type === 4) {
      const block = head.subarray(start, end);
      if (block.length < 8) return null;
      const comments = readVorbisComments(block, 0);
      return comments ? pickVorbisLyrics(comments.entries) : null;
    }

    if (last) break;
    pos = end;
  }
  return null;
}

// ---------------------------------------------------------------- MP4 / M4A

/** iTunes 的歌词 atom 是 `©lyr`（0xA9 = `©`） */
const MP4_LYRIC_ATOM = '\u00a9lyr';

/** 需要向下钻的容器 atom；`meta` 单独处理（多了 4 字节 version/flags） */
const MP4_CONTAINERS = new Set([
  'moov',
  'udta',
  'ilst',
  'trak',
  'mdia',
  'minf',
  'stbl',
  'moof',
  'traf',
]);

/** `©lyr` 的内容是一个 `data` atom：size(4) + 'data' + type(4) + locale(4) + 文本 */
function readMp4DataAtom(buf: Buffer, start: number, end: number): string | null {
  let pos = start;
  while (pos + 8 <= end) {
    const size = buf.readUInt32BE(pos);
    if (size < 8 || pos + size > end) break;
    const type = buf.toString('latin1', pos + 4, pos + 8);
    if (type === 'data' && pos + 16 <= pos + size) {
      const dataType = buf.readUInt32BE(pos + 8) & 0x00ffffff;
      const payload = buf.subarray(pos + 16, pos + size);
      const text = (
        dataType === 2 ? payload.toString('utf16le') : payload.toString('utf8')
      ).replace(/\0+$/, '');
      if (text.trim()) return text;
    }
    pos += size;
  }
  return null;
}

function findMp4LyricAtom(buf: Buffer, start: number, end: number): string | null {
  let pos = start;
  while (pos + 8 <= end) {
    let size = buf.readUInt32BE(pos);
    const type = buf.toString('latin1', pos + 4, pos + 8);
    let headerLen = 8;
    if (size === 1) {
      // 64 位 largesize
      if (pos + 16 > end) break;
      size = Number(buf.readBigUInt64BE(pos + 8));
      headerLen = 16;
    } else if (size === 0) {
      // 延伸到文件末尾
      size = end - pos;
    }
    if (size < headerLen || pos + size > end) break;

    const bodyStart = pos + headerLen;
    const bodyEnd = pos + size;
    if (type === MP4_LYRIC_ATOM) {
      const text = readMp4DataAtom(buf, bodyStart, bodyEnd);
      if (text) return text;
    } else if (MP4_CONTAINERS.has(type)) {
      const hit = findMp4LyricAtom(buf, bodyStart, bodyEnd);
      if (hit) return hit;
    } else if (type === 'meta') {
      // QuickTime 的 meta 没有 version/flags，两种起点都试
      const hit =
        findMp4LyricAtom(buf, bodyStart + 4, bodyEnd) ?? findMp4LyricAtom(buf, bodyStart, bodyEnd);
      if (hit) return hit;
    }
    pos = bodyEnd;
  }
  return null;
}

/** 尾部读取时 buffer 不从 atom 边界开始，先定位 `moov` 再解析 */
function scanMp4ForMoov(buf: Buffer): string | null {
  const needle = Buffer.from('moov', 'latin1');
  let from = 0;
  for (let guard = 0; guard < 32; guard += 1) {
    const at = buf.indexOf(needle, from);
    if (at < 4) break;
    const hit = findMp4LyricAtom(buf, at - 4, buf.length);
    if (hit) return hit;
    from = at + 4;
  }
  return null;
}

/** 从 m4a / mp4 头部解析 `©lyr` 歌词；没有返回 null */
export function readMp4Lyrics(head: Buffer): string | null {
  if (head.length < 8) return null;
  return findMp4LyricAtom(head, 0, head.length) ?? scanMp4ForMoov(head);
}

// ---------------------------------------------------------------- OGG / OPUS

const OGG_HEADER_BYTES = 27;
/** 只看前几个 packet：Vorbis 是 [id, comment, setup…]，Opus 是 [OpusHead, OpusTags] */
const OGG_MAX_PACKETS = 3;

/** 从 ogg 头部解析 Vorbis / Opus 注释里的歌词；不支持的流返回 null */
export function readOggLyrics(head: Buffer): string | null {
  if (head.length < OGG_HEADER_BYTES || head.toString('latin1', 0, 4) !== 'OggS') return null;

  let pos = 0;
  let serial = -1;
  let pending: Buffer[] = [];
  let pendingLen = 0;
  const packets: Buffer[] = [];

  while (pos + OGG_HEADER_BYTES <= head.length && packets.length < OGG_MAX_PACKETS) {
    if (head.toString('latin1', pos, pos + 4) !== 'OggS') break;
    if (head[pos + 4] !== 0) break; // 只认 version 0
    const pageSerial = head.readUInt32LE(pos + 14);
    const segments = head[pos + 26];
    const tableStart = pos + OGG_HEADER_BYTES;
    if (tableStart + segments > head.length) break;

    let payloadAt = tableStart + segments;
    let pageEnd = payloadAt;
    for (let i = 0; i < segments; i += 1) pageEnd += head[tableStart + i];
    if (pageEnd > head.length) break;

    if (serial === -1) serial = pageSerial;
    if (pageSerial === serial) {
      for (let i = 0; i < segments && packets.length < OGG_MAX_PACKETS; i += 1) {
        const lacing = head[tableStart + i];
        pending.push(head.subarray(payloadAt, payloadAt + lacing));
        pendingLen += lacing;
        payloadAt += lacing;
        if (lacing < 255) {
          packets.push(Buffer.concat(pending, pendingLen));
          pending = [];
          pendingLen = 0;
        }
      }
    }
    pos = pageEnd;
  }

  if (packets.length < 2) return null;
  const idPacket = packets[0];
  const commentPacket = packets[1];

  let offset = -1;
  if (idPacket.toString('latin1', 0, 7) === '\u0001vorbis') {
    offset = commentPacket.toString('latin1', 0, 7) === '\u0003vorbis' ? 7 : -1;
  } else if (idPacket.toString('latin1', 0, 8) === 'OpusHead') {
    offset = commentPacket.toString('latin1', 0, 8) === 'OpusTags' ? 8 : -1;
  }
  if (offset < 0) return null;

  const comments = readVorbisComments(commentPacket, offset);
  return comments ? pickVorbisLyrics(comments.entries) : null;
}

async function readHead(abs: string): Promise<Buffer> {
  const handle = await fsp.open(abs, 'r');
  try {
    const buf = Buffer.alloc(MAX_HEAD_BYTES);
    const { bytesRead } = await handle.read(buf, 0, MAX_HEAD_BYTES, 0);
    return buf.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}

/** MP4 容器的 `moov` 常见于文件尾部，头部读不到时再读尾部 */
const TAIL_FORMATS = new Set(['.m4a', '.m4b', '.mp4', '.mov', '.aac']);

/** 读文件尾部 MAX_HEAD_BYTES 字节；文件更短时退化为整文件 */
async function readTail(abs: string): Promise<Buffer | null> {
  try {
    const stat = await fsp.stat(abs);
    const bytes = Math.min(MAX_HEAD_BYTES, stat.size);
    if (bytes <= 0) return null;
    const handle = await fsp.open(abs, 'r');
    try {
      const buf = Buffer.alloc(bytes);
      const start = Math.max(0, stat.size - bytes);
      const { bytesRead } = await handle.read(buf, 0, bytes, start);
      return buf.subarray(0, bytesRead);
    } finally {
      await handle.close();
    }
  } catch {
    return null;
  }
}

/** 同目录同名 `.lrc`（大小写都试，兼顾 Linux 上常见的 `.LRC`） */
function sidecarLrcPath(abs: string): string | null {
  const base = path.join(path.dirname(abs), path.basename(abs, path.extname(abs)));
  for (const ext of ['.lrc', '.LRC', '.Lrc']) {
    const p = `${base}${ext}`;
    if (fs.existsSync(p)) return p;
  }
  return null;
}

/** 读取一首歌的歌词：旁挂 LRC 优先，其次内嵌（ID3 / Vorbis）；都没有返回 `none` */
export async function readLyrics(abs: string, opts: LyricsOptions = {}): Promise<LyricsResult> {
  return withTranslation(abs, await readPrimaryLyrics(abs), opts.lang);
}

export interface LyricsOptions {
  /** 首选译文语言（如 `zh-CN` / `en`）；缺省时中文优先 */
  lang?: string;
}

/** 给主歌词贴上旁挂译文；没有任何一行对上时保持原样 */
async function withTranslation(
  abs: string,
  result: LyricsResult,
  lang?: string,
): Promise<LyricsResult> {
  if (result.lines.length === 0) return result;

  for (const file of translationLrcCandidates(abs, lang)) {
    try {
      const stat = await fsp.stat(file);
      if (stat.size <= 0 || stat.size > MAX_HEAD_BYTES) continue;
      const parsed = parseLrc(await fsp.readFile(file, 'utf8'));
      if (parsed.lines.length === 0) continue;
      const lines = attachTranslation(result.lines, parsed.lines, result.synced);
      if (lines.some((line) => line.translation)) return { ...result, lines };
    } catch {
      // 单份译文读不出来就换下一份
    }
  }
  return result;
}

async function readPrimaryLyrics(abs: string): Promise<LyricsResult> {
  const lrc = sidecarLrcPath(abs);
  if (lrc) {
    let text = '';
    try {
      text = await fsp.readFile(lrc, 'utf8');
    } catch {
      // 读不出来就当作没有旁挂歌词，继续看内嵌
    }
    const parsed = text ? parseLrc(text) : null;
    if (parsed && parsed.lines.length > 0) {
      return { ...parsed, source: 'lrc' };
    }
  }

  let head: Buffer;
  try {
    head = await readHead(abs);
  } catch {
    return EMPTY;
  }

  const embedded =
    readId3Lyrics(head) ??
    readFlacLyrics(head) ??
    readMp4Lyrics(head) ??
    readOggLyrics(head);
  const resolved =
    embedded ??
    (TAIL_FORMATS.has(path.extname(abs).toLowerCase())
      ? await readTail(abs).then((tail) => (tail ? readMp4Lyrics(tail) : null))
      : null);
  if (!resolved || !resolved.trim()) return EMPTY;

  const parsed = parseLrc(resolved);
  if (parsed.lines.length === 0) return EMPTY;
  return { ...parsed, source: 'embedded' };
}
