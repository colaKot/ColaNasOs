import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import { contentMd5Of, photoItemAbs } from './content-md5';

/**
 * 全库内容指纹回填（后台、限速、可续跑）。
 *
 * 为什么必须有：`content_md5` 原本是**惰性**的，只在「重复照片清理」里补
 * size 撞车的候选。真实库 19089 张里只有 582 张属于这类，其余 18507 张
 * 永远是 NULL —— 手机备份拿原图 md5 来问时，服务端没有任何可比对的码，
 * 已备份过的照片会被当成新照片重新上传一遍。
 *
 * 设计：
 * - 内核启动即跑，每批 N 张、批间留间隔，避免把 63 GiB 原图一次性压到磁盘上；
 * - 判据就是 `content_md5` 为空，所以进程被杀 / 重启后会从断点继续；
 * - 补完自动停；读不到的文件本进程内跳过（重启后会再试一次）；
 * - **扫描新增照片后要重新踢一次**（`kickContentMd5Backfill`），否则新入库的
 *   记录永远补不上码 —— 2026-11-07 全库重扫新增 1138 条就是这么漏掉的；
 * - `COLANAS_MD5_BACKFILL=0` 可关掉（临时让出磁盘给别的任务）。
 *
 * 写的是 `content_md5`（原始内容指纹），**不写 size / orig_size**：
 * 它描述的是「手机上传时那份原始内容」，与文件当前大小无关。
 */

const BATCH = 60;
const INTERVAL_MS = 3000;

type Row = { id: string; rel_path: string; root_path: string };

// 模块级状态：保证「补完再踢一次」不会叠出第二个定时器。
let timer: ReturnType<typeof setInterval> | null = null;
let running = false;

export async function backfillContentMd5Batch(k: KernelApi, limit = BATCH) {
  const rows = (
    await sql<Row>`
      select p.id, p.rel_path, l.root_path
        from photo_items p join photo_libraries l on l.id = p.library_id
       where p.in_trash = 0
         and (p.content_md5 is null or p.content_md5 = '')
       limit ${limit}
    `.execute(k.db)
  ).rows;

  let done = 0;
  let failed = 0;
  for (const row of rows) {
    try {
      const md5 = (await contentMd5Of(photoItemAbs(String(row.root_path || ''), row.rel_path)))
        .trim()
        .toLowerCase();
      if (!/^[0-9a-f]{32}$/.test(md5)) {
        failed += 1;
        continue;
      }
      await sql`
        update photo_items set content_md5 = ${md5}
         where id = ${row.id} and (content_md5 is null or content_md5 = '')
      `.execute(k.db);
      done += 1;
    } catch {
      failed += 1;
    }
  }

  const left = (
    await sql<{ n: number }>`
      select count(*) as n from photo_items
       where in_trash = 0 and (content_md5 is null or content_md5 = '')
    `.execute(k.db)
  ).rows[0];
  return { done, failed, scanned: rows.length, remaining: Number(left?.n) || 0 };
}

/**
 * 启动（或重启）回填循环。
 *
 * 幂等：已经在跑就直接返回，不会因为反复调用叠出多个定时器。
 * 场景有两个 —— 内核启动、以及每次照片扫描结束后（扫描会新增记录）。
 */
export function kickContentMd5Backfill(k: KernelApi): void {
  if (process.env.COLANAS_MD5_BACKFILL === '0') {
    k.log.info('photo content_md5 backfill disabled by env');
    return;
  }
  if (timer) return;

  const tick = async () => {
    if (running) return;
    running = true;
    try {
      const r = await backfillContentMd5Batch(k);
      if (r.scanned > 0) {
        k.log.info({ ...r }, 'photo content_md5 backfill');
      }
      if (r.remaining === 0) {
        if (timer) clearInterval(timer);
        timer = null;
        k.log.info('photo content_md5 backfill completed');
      }
    } catch (err) {
      k.log.warn({ err: String(err) }, 'photo content_md5 backfill failed');
    } finally {
      running = false;
    }
  };

  // 先建立定时器再跑第一批，让 tick 完成时可以安全地 clearInterval。
  // unref 不阻止进程退出；启动立刻补一批，之后按间隔续跑。
  timer = setInterval(() => void tick(), INTERVAL_MS);
  timer.unref?.();
  void tick();
}

/** 内核启动时的入口，语义与 kick 等价，保留名字让调用点读起来更明确。 */
export function startContentMd5Backfill(k: KernelApi): void {
  kickContentMd5Backfill(k);
}
