import fsp from 'node:fs/promises';
import path from 'node:path';

/**
 * 动态照片里「那段视频」的统一识别。
 *
 * 两类形态：
 *   内嵌视频 —— 单文件，视频被塞进图片容器（JPEG/HEIC）。这里只吃内存里的
 *               文件头/文件尾 Buffer，做纯判定并返回 { offset, size }，
 *               由调用方按「虚拟文件」区间读取，绝不改动原文件。
 *   配对视频 —— 双文件，静图 + 同目录同名视频，按 basename 配对。
 *
 * 所有判定都是可单测的纯函数（文件或文件名只在配对函数里用到）。
 */

export type LiveVendor = 'google' | 'samsung' | 'huawei' | 'heic' | 'generic';

export interface EmbeddedVideo {
  /** 视频数据在原文件里的起始字节（绝对偏移） */
  offset: number;
  /** 视频字节数 */
  size: number;
  mime: string;
  vendor: LiveVendor;
}

/** 内嵌视频的最小可信字节数：小于它基本是元数据/垃圾，不当视频。 */
export const LIVE_MIN_BYTES = 64 * 1024;
/** 配对视频的最小可信字节数：小于它的多半是缩略/占位文件。 */
export const PAIR_MIN_BYTES = 32 * 1024;
/** ftyp 兜底扫描时最多回看的文件尾部字节数。 */
export const TAIL_SCAN_BYTES = 4 * 1024 * 1024;

/** 配对视频扩展名优先级：.mov > .mp4 > .m4v */
const PAIR_EXTS = ['.mov', '.mp4', '.m4v'] as const;
const PAIR_EXT_SET = new Set<string>(PAIR_EXTS);

/** latin1 让字节与字符一一对应，正则只碰 ASCII 属性，不会被二进制内容错位 */
function toLatin1(buf: Buffer): string {
  return buf.toString('latin1');
}

/**
 * 显式的 MotionPhoto 声明值。
 * 单文件容器规范里该字段为 "1" 表示启用；某些文件只带 MotionPhotoVersion 等
 * 相邻属性，这里要求紧跟 `MotionPhoto="…"`，不会把它们误当成声明。
 */
function motionPhotoValues(text: string): number[] {
  const out: number[] = [];
  const re = /(?:GCamera|Camera|[A-Za-z]+):MotionPhoto\s*=\s*"(-?\d+)"/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) out.push(Number(m[1]));
  return out;
}

/** 显式声明为 0 / 负数 = 关闭动态照片，即使尾部真有 MP4 也不认。 */
export function motionPhotoRejected(text: string): boolean {
  const vals = motionPhotoValues(text);
  return vals.length > 0 && vals.some((v) => !Number.isFinite(v) || v <= 0);
}

/** 是否存在正数（启用）的 MotionPhoto 声明，用于忽略遗留字段。 */
export function declaresMotionPhoto(text: string): boolean {
  return motionPhotoValues(text).some((v) => v > 0);
}

/**
 * 单文件容器规范的新格式：Container:Directory 里的视频条目带
 *   Item:Mime="video/*"、Item:Semantic="MotionPhoto"、Item:Length="N"
 * N 是视频字节数，视频结束于 EOF，起点 = fileSize - N。
 *
 * 同一份目录里还可能有带 Length 的增益图条目且排在视频前面，
 * 所以只能按视频语义挑选，不能盲取最后一个 Item:Length。
 * 三个正则覆盖属性顺序的写法差异，命中即返回。
 */
export function parseItemLength(text: string): number | null {
  let m = /Item:Mime="video\/[^"]*"[\s\S]{0,240}?Item:Length="(\d+)"/.exec(text);
  if (!m) {
    m = /Item:Length="(\d+)"[\s\S]{0,240}?Item:(?:Mime="video\/[^"]*"|Semantic="MotionPhoto")/.exec(
      text,
    );
  }
  if (!m) {
    m = /Item:Semantic="MotionPhoto"[\s\S]{0,240}?Item:Length="(\d+)"/.exec(text);
  }
  return m ? Number(m[1]) : null;
}

/** 视频条目的 MIME，缺省按 mp4 处理。 */
export function parseItemMime(text: string): string {
  const m = /Item:Mime="(video\/[^"]*)"/.exec(text);
  return m ? m[1] : 'video/mp4';
}

/**
 * 早期遗留字段：MicroVideoOffset 同样是从 EOF 回退的字节数（视频长度），
 * 不是「从文件开头的偏移」；MicroVideoPresentationTimestampUs 是微秒时间戳，
 * 绝不能当偏移量，这里只认 MicroVideoOffset。
 */
export function parseMicroVideoOffset(text: string): number | null {
  const m = /GCamera:MicroVideoOffset="(\d+)"/.exec(text);
  return m ? Number(m[1]) : null;
}

/**
 * 是否具备「动态照片线索」，供调用方决定是否读取文件尾部（ftyp 兜底）。
 * 限制条件：XMP 里出现 MotionPhoto/MicroVideo/MotionPhoto_Data 等字样，
 * 或文件名带 MVIMG_ / .MP.jpg / .MP 等特征。普通图片不走兜底，
 * 避免尾部恰好有二进制时被误判成视频。
 */
export function hasLiveHint(headText: string, fileName: string): boolean {
  if (/MotionPhoto|MicroVideo|SEFT/i.test(headText)) return true;
  const base = path.basename(fileName);
  if (/^MVIMG_/i.test(base)) return true;
  if (/\.MP\.jpe?g$/i.test(base)) return true;
  if (/\.MP$/i.test(base)) return true;
  return false;
}

function isPrintableAscii(buf: Buffer, start: number, len: number): boolean {
  if (start < 0 || start + len > buf.length) return false;
  for (let i = start; i < start + len; i += 1) {
    const c = buf[i];
    if (c < 0x20 || c > 0x7e) return false;
  }
  return true;
}

/**
 * 在文件尾部缓冲区里找 ISO BMFF 的 ftyp box 起点作为视频起点。
 * box 为「4 字节大端 size + 4 字节 type + 4 字节 major_brand …」，
 * 只有结构合法（size 合理、major_brand 为可打印 ASCII）才认。
 * 找到后视频 = 从该 box 起点一直到 EOF。
 */
export function scanFtyp(tail: Buffer, fileSize: number): { offset: number; size: number } | null {
  const tailStart = fileSize - tail.length;
  let from = 0;
  while (from < tail.length) {
    const p = tail.indexOf('ftyp', from, 'latin1');
    if (p < 0) return null;
    if (p >= 4) {
      const boxSize = tail.readUInt32BE(p - 4);
      const brandOk = isPrintableAscii(tail, p + 4, 4);
      if (boxSize >= 16 && boxSize <= 1 << 20 && p - 4 + boxSize <= tail.length && brandOk) {
        const offset = tailStart + p - 4;
        const size = fileSize - offset;
        if (offset > 0 && size >= LIVE_MIN_BYTES) return { offset, size };
      }
    }
    from = p + 4;
  }
  return null;
}

/**
 * HEIF 容器扩展：mpvd box 存放视频，视频未必在文件末尾，
 * 需要 offset + size 两个值。box 为「4 字节大端 size + 4 字节 type」。
 * 在文件头缓冲区里找 mpvd，读它前面的 size 字段，校验视频净荷 >= 64KB、
 * offset + size <= fileSize 才认（保守，避免 XMP 文本里出现 "mpvd" 误判）。
 * 视频净荷扣掉 8 字节 box 头。
 */
export function findMpvdBox(head: Buffer, fileSize: number): { offset: number; size: number } | null {
  const idx = head.indexOf('mpvd', 0, 'latin1');
  if (idx < 4) return null;
  const boxStart = idx - 4;
  const boxSize = head.readUInt32BE(boxStart);
  const size = boxSize - 8;
  if (size < 64 * 1024) return null;
  if (boxStart + boxSize > fileSize) return null;
  const offset = boxStart + 8;
  if (offset + size > fileSize) return null;
  return { offset, size };
}

/** 三星尾部结构特征（SEFT / MotionPhoto_Data / 厂商字样） */
function hasSamsungHint(headText: string, tailText: string): boolean {
  return /MotionPhoto_Data|SEFT|Samsung/i.test(headText) || /MotionPhoto_Data|SEFT/i.test(tailText);
}

/**
 * 统一识别内嵌视频。优先级：
 *   1 显式 MotionPhoto=0/负值 → 拒绝
 *   2 新格式 Item:Length（视频在末尾，起点 = fileSize - N）
 *   3 旧 MicroVideoOffset（同样是从 EOF 回退的字节数；声明了 MotionPhoto 时忽略）
 *   4 尾部 ftyp 兜底（tail 由调用方在确认线索后才传入）
 *   5 HEIF mpvd box（offset + size，视频未必在末尾）
 *
 * tail 为 null 表示调用方未确认线索，跳过第 4 步。
 */
export function detectEmbeddedVideo(
  head: Buffer,
  fileSize: number,
  tail: Buffer | null,
  ext: string,
): EmbeddedVideo | null {
  const text = toLatin1(head);
  if (motionPhotoRejected(text)) return null;

  const clamped = (offset: number, size: number, vendor: LiveVendor, mime: string): EmbeddedVideo | null => {
    if (!Number.isFinite(offset) || !Number.isFinite(size)) return null;
    if (size < LIVE_MIN_BYTES) return null;
    if (offset < 0 || offset + size > fileSize) return null;
    return { offset, size, mime, vendor };
  };

  // 2. 新格式 Item:Length
  const itemLen = parseItemLength(text);
  if (itemLen != null) {
    return clamped(fileSize - itemLen, itemLen, 'google', parseItemMime(text));
  }

  // 3. 旧 MicroVideoOffset：一旦声明了 MotionPhoto，遗留字段视为无效
  if (!declaresMotionPhoto(text)) {
    const mv = parseMicroVideoOffset(text);
    if (mv != null) return clamped(fileSize - mv, mv, 'google', 'video/mp4');
  }

  // 4. 尾部 ftyp 兜底
  if (tail != null) {
    const ft = scanFtyp(tail, fileSize);
    if (ft) {
      const tailText = toLatin1(tail);
      const vendor: LiveVendor = hasSamsungHint(text, tailText) ? 'samsung' : 'generic';
      return clamped(ft.offset, ft.size, vendor, 'video/mp4');
    }
  }

  // 5. HEIF mpvd box
  const mp = findMpvdBox(head, fileSize);
  if (mp) {
    const vendor: LiveVendor = /Huawei|Harmony|com\.huawei|hwmp/i.test(text)
      ? 'huawei'
      : ext === 'heic' || ext === 'heif' || ext === 'avif'
        ? 'heic'
        : 'generic';
    return clamped(mp.offset, mp.size, vendor, 'video/mp4');
  }

  return null;
}

/**
 * 双文件配对：readdir 一次，按同名 basename（大小写不敏感）匹配，
 * 认 .mov/.mp4/.m4v（大小写混写亦可），≥ PAIR_MIN_BYTES，
 * 优先级 .mov > .mp4 > .m4v。返回配对视频的绝对路径与字节数。
 *
 * 已知限制：更可靠的 ContentIdentifier UUID 配对（静图 MakerNote /
 * 视频 quicktime 元数据）本轮不做；导出/备份被压平成只有静图时，
 * 找不到配对即按普通图片处理。
 */
export async function findPairedVideo(abs: string): Promise<{ path: string; size: number } | null> {
  const dir = path.dirname(abs);
  const stem = path.basename(abs, path.extname(abs)).toLowerCase();
  let entries;
  try {
    entries = await fsp.readdir(dir, { withFileTypes: true });
  } catch {
    return null;
  }

  const candidates: Array<{ ext: string; name: string }> = [];
  for (const e of entries) {
    if (e.isDirectory()) continue;
    const ext = path.extname(e.name).toLowerCase();
    if (!PAIR_EXT_SET.has(ext)) continue;
    const s = path.basename(e.name, path.extname(e.name)).toLowerCase();
    if (s !== stem) continue;
    candidates.push({ ext, name: e.name });
  }

  const rank = (ext: string): number => PAIR_EXTS.indexOf(ext as (typeof PAIR_EXTS)[number]);
  candidates.sort((a, b) => rank(a.ext) - rank(b.ext) || a.name.localeCompare(b.name));

  for (const c of candidates) {
    const p = path.join(dir, c.name);
    try {
      const st = await fsp.stat(p);
      if (st.isFile() && st.size >= PAIR_MIN_BYTES) return { path: p, size: st.size };
    } catch {
      /* 这个候选读不到就试下一个 */
    }
  }
  return null;
}
