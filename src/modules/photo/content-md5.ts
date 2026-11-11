import crypto from 'node:crypto';
import fs from 'node:fs';
import { createReadStream } from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { absoluteInput, filesRoot, isAbsoluteInput, resolveInRoot } from '../files/fs-root';

/**
 * 照片「原始内容指纹」。
 *
 * 手机备份判重只认两样东西：`content_md5`（内容）与 `orig_size`（原始字节数）。
 * 它们描述的是**手机上传时那份原始内容**，一旦写入就永不更新 —— 因为 NAS 上的
 * 照片之后可能被补充 GPS / 旋转 / 重新编码（JPEG 重编码会同时改变字节内容
 * 和文件大小），若跟着改写后的文件重算，手机再备份同一张原图就会被判成新照片，
 * 于是重复上传一份。
 *
 * 参考口径：既有实现 的 `photoSourceService.computeContentMd5` 与
 * `gpsSupplementService._preserveOriginalFingerprint`。
 *
 * ⚠️ 算法必须与客户端 `crypto.md5.bind(file.openRead()).first` 逐字节一致：
 *    全文件流式 MD5，不做头尾采样、不截断。两端写成两份实现必然对不上。
 */

/** 全文件流式 MD5（hex）；读失败抛错，由调用方决定重试 / 跳过。 */
export function contentMd5Of(abs: string): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const h = crypto.createHash('md5');
    const s = createReadStream(abs);
    s.on('data', (chunk) => h.update(chunk as Buffer));
    s.on('end', () => resolve(h.digest('hex')));
    s.on('error', reject);
  });
}

/**
 * 把 photo_items.rel_path 还原成绝对路径。
 *
 * 历史库里三种形态都真实存在，不能只按一种猜：
 *  ① **绝对路径**（老库 / 库根本身在 filesRoot 之外，例如
 *     `D:/Photos/IMG_001.JPG`）——真库 19089 行全是这种；
 *  ② 相对 filesRoot（新库 / 冒烟库，例如 `photos/IMG_001.JPG`）；
 *  ③ 相对相册库根（`D:/Photos` 那种外挂盘）。
 * 拼出候选后取真实存在的那个；三种都失败时返回第一种，让读文件报错而不是静默算错。
 */
export function photoItemAbs(rootPath: string, relPath: string): string {
  const raw = String(relPath || '').trim();
  const root = filesRoot();
  const candidates: string[] = [];
  // ① rel_path 本身就是绝对路径：直接还原，不要拿去 resolveInRoot（会被判越界 403）
  if (isAbsoluteInput(raw)) {
    candidates.push(path.resolve(absoluteInput(raw)));
  }
  // ② 相对 filesRoot
  try {
    candidates.push(resolveInRoot(root, raw));
  } catch {
    // 越界，忽略
  }
  // ③ 相对相册库根
  try {
    const base = isAbsoluteInput(rootPath)
      ? path.resolve(absoluteInput(rootPath))
      : resolveInRoot(root, rootPath);
    candidates.push(resolveInRoot(base, raw));
  } catch {
    // 库根本身越界，忽略
  }
  if (candidates.length === 0) return path.join(root, raw);
  return candidates.find((p) => fs.existsSync(p)) ?? candidates[0];
}

export type FingerprintRow = {
  id: string;
  rel_path: string;
  root_path?: string;
  size: number;
  orig_size?: number | null;
  content_md5?: string | null;
};

/**
 * **在任何会改写照片文件的操作之前**调用：固化原始内容指纹。
 *
 * - `content_md5` 为空 → 现算当前（尚未被改写的）文件 MD5 写入；
 * - `orig_size` 为 0 → 写入当前字节数；
 * - 两者已有值时一律不覆盖（二次补充 GPS 必须幂等）。
 *
 * 返回固化后的值，供 `check_content` 直接比对。读文件失败时保持原值，
 * 不抛异常阻断业务（备份判重会退化成 size 粗筛）。
 */
export async function preserveOriginalFingerprint(
  db: any,
  row: FingerprintRow,
): Promise<{ md5: string; origSize: number }> {
  const md5 = String(row.content_md5 || '').trim().toLowerCase();
  const origSize = Number(row.orig_size) || 0;
  if (/^[0-9a-f]{32}$/.test(md5) && origSize > 0) return { md5, origSize };

  let nextMd5 = md5;
  let nextOrig = origSize;
  if (!/^[0-9a-f]{32}$/.test(nextMd5) && row.root_path) {
    try {
      nextMd5 = (await contentMd5Of(photoItemAbs(row.root_path, row.rel_path)))
        .trim()
        .toLowerCase();
    } catch {
      nextMd5 = '';
    }
  }
  if (nextOrig <= 0) nextOrig = Number(row.size) || 0;

  const patch: Record<string, string | number> = {};
  if (/^[0-9a-f]{32}$/.test(nextMd5) && !/^[0-9a-f]{32}$/.test(md5)) {
    patch.content_md5 = nextMd5;
  }
  if (nextOrig > 0 && origSize <= 0) patch.orig_size = nextOrig;
  try {
    if (typeof patch.content_md5 === 'string') {
      await sql`update photo_items set content_md5 = ${patch.content_md5} where id = ${row.id}`.execute(
        db,
      );
    }
    if (typeof patch.orig_size === 'number') {
      await sql`update photo_items set orig_size = ${patch.orig_size} where id = ${row.id}`.execute(
        db,
      );
    }
  } catch {
    // 写失败不阻断：下次 check_content 会再试
  }
  return { md5: nextMd5, origSize: nextOrig };
}
