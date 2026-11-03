import fsp from 'node:fs/promises';
import { inflateRawSync } from 'node:zlib';

/**
 * 最小 ZIP 读取（epub / cbz 用），零依赖：
 *   - 只支持 store(0) 与 deflate(8)，这正是 epub/cbz 的全部用法
 *   - 防炸：条目数 ≤ 5000、单条目解压 ≤ 32 MB、整包读取 ≤ 64 MB
 *
 * 不解压整个压缩包，只按需取中央目录里登记的 entry。
 */
const MAX_FILE_BYTES = 64 * 1024 * 1024;
const MAX_ENTRY_BYTES = 32 * 1024 * 1024;
const MAX_ENTRIES = 5000;

export interface ZipEntry {
  name: string;
  method: number;
  compSize: number;
  size: number;
  localOffset: number;
}

function findEocd(buf: Buffer): number {
  const min = Math.max(0, buf.length - 66_000);
  for (let i = buf.length - 22; i >= min; i -= 1) {
    if (buf.readUInt32LE(i) === 0x06054b50) return i;
  }
  return -1;
}

export function listZipEntries(buf: Buffer): ZipEntry[] {
  if (buf.length < 22) return [];
  const eocd = findEocd(buf);
  if (eocd < 0) return [];
  if (eocd + 22 > buf.length) return [];

  const count = buf.readUInt16LE(eocd + 10);
  const cdOffset = buf.readUInt32LE(eocd + 16);
  if (count > MAX_ENTRIES || cdOffset + 4 > buf.length) return [];

  const entries: ZipEntry[] = [];
  let p = cdOffset;
  for (let i = 0; i < count; i += 1) {
    if (p + 46 > buf.length || buf.readUInt32LE(p) !== 0x02014b50) break;
    const flags = buf.readUInt16LE(p + 8);
    const method = buf.readUInt16LE(p + 10);
    const compSize = buf.readUInt32LE(p + 20);
    const size = buf.readUInt32LE(p + 24);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const localOffset = buf.readUInt32LE(p + 42);
    const nameEnd = p + 46 + nameLen;
    if (nameEnd > buf.length) break;
    const name = buf.toString(flags & 0x800 ? 'utf8' : 'latin1', p + 46, nameEnd);
    entries.push({ name, method, compSize, size, localOffset });
    p = nameEnd + extraLen + commentLen;
  }
  return entries;
}

export function readZipEntry(buf: Buffer, name: string): Buffer | null {
  const entry = listZipEntries(buf).find((e) => e.name === name);
  if (!entry) return null;
  return extractEntry(buf, entry);
}

export function extractEntry(buf: Buffer, entry: ZipEntry): Buffer | null {
  const p = entry.localOffset;
  if (p + 30 > buf.length || buf.readUInt32LE(p) !== 0x04034b50) return null;
  const nameLen = buf.readUInt16LE(p + 26);
  const extraLen = buf.readUInt16LE(p + 28);
  const start = p + 30 + nameLen + extraLen;
  const end = start + entry.compSize;
  if (start > buf.length || end > buf.length) return null;
  if (entry.size > MAX_ENTRY_BYTES) return null;

  const data = buf.subarray(start, end);
  if (entry.method === 0) return Buffer.from(data);
  if (entry.method === 8) {
    try {
      return inflateRawSync(data, { maxOutputLength: MAX_ENTRY_BYTES });
    } catch {
      return null;
    }
  }
  return null;
}

/** 读整个压缩包（超过上限直接返回 null，交由调用方降级） */
export async function readZipFile(abs: string): Promise<Buffer | null> {
  try {
    const st = await fsp.stat(abs);
    if (st.size > MAX_FILE_BYTES) return null;
    return await fsp.readFile(abs);
  } catch {
    return null;
  }
}