import fs from 'node:fs';
import crypto from 'node:crypto';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { ref } from './ai/schemas';
import { ensureSidecar } from './ai/sidecar';
import { filesRoot, resolveAnyPath } from '../files/fs-root';

/**
 * 相似照片：两阶段感知哈希（pHash/dHash）。
 *
 *   阶段 1 扫描：每张图用 ffmpeg 缩到 9×8 灰度，算 64 位差值与 → `photo_items.phash`
 *   阶段 2 比对：按 phash 前 32 位分桶，桶内汉明距离 ≤6 视为相似，写入 `photo_phash_groups`
 *
 * 先扫描、再比对；失败的照片标记 `phash_state=2`，
 * 不会在下次扫描时反复重试。阈值固定 6，与参考实现一致（64 位里 6 位差异）。
 */
const PHASH_DISTANCE = 6;
const PREFIX_LEN = 8;
const SCAN_BATCH = 15;
const MAX_BUCKET = 2000;

interface PhashState {
  running: boolean;
  phase: 'idle' | 'scan' | 'compare' | 'done';
  done: number;
  total: number;
  groups: number;
  failed: number;
  owner: string;
}

const state: PhashState = {
  running: false,
  phase: 'idle',
  done: 0,
  total: 0,
  groups: 0,
  failed: 0,
  owner: '',
};

function hexBits(hex: string): bigint {
  try {
    return BigInt(`0x${String(hex || '').padEnd(16, '0').slice(0, 16)}`);
  } catch {
    return 0n;
  }
}

function hamming(a: bigint, b: bigint): number {
  let x = a ^ b;
  let n = 0;
  while (x) {
    x &= x - 1n;
    n += 1;
  }
  return n;
}

function ownerFilter(uid: string) {
  return sql`library_id in (select id from photo_libraries where owner_id = ${uid})`;
}

async function runPhash(k: KernelApi, uid: string): Promise<void> {
  state.running = true;
  state.owner = uid;
  state.done = 0;
  state.failed = 0;
  state.groups = 0;
  state.phase = 'scan';

  try {
    const pending = await sql<{ n: number }>`
      select count(*) as n from photo_items
       where in_trash = 0 and phash_state = 0 and ${ownerFilter(uid)}
    `.execute(k.db);
    state.total = Number(pending.rows[0]?.n) || 0;

    const s = await ensureSidecar(k);
    const root = filesRoot();

    for (;;) {
      const rows = (
        await sql<{ id: string; rel_path: string }>`
          select id, rel_path from photo_items
           where in_trash = 0 and phash_state = 0 and ${ownerFilter(uid)}
           order by taken_at desc limit ${SCAN_BATCH}
        `.execute(k.db)
      ).rows;
      if (rows.length === 0) break;

      for (const row of rows) {
        try {
          const abs = resolveAnyPath(root, row.rel_path);
          if (!fs.existsSync(abs)) {
            await sql`update photo_items set phash_state = 2 where id = ${row.id}`.execute(k.db);
            state.failed += 1;
            state.done += 1;
            continue;
          }
          const out = await s.request<{ hash: string }>('phash', { src: abs }, 120_000);
          const hash = String(out.hash || '');
          if (!/^[0-9a-f]{16}$/.test(hash)) {
            await sql`update photo_items set phash_state = 2 where id = ${row.id}`.execute(k.db);
            state.failed += 1;
          } else {
            await sql`
              update photo_items set phash = ${hash}, phash_state = 1 where id = ${row.id}
            `.execute(k.db);
          }
          state.done += 1;
        } catch (err) {
          k.log.warn({ photo: row.id, err: String((err as Error)?.message || err) }, 'phash failed');
          await sql`update photo_items set phash_state = 2 where id = ${row.id}`.execute(k.db);
          state.failed += 1;
          state.done += 1;
        }
      }
    }

    state.phase = 'compare';
    await sql`delete from photo_phash_groups where owner_id = ${uid}`.execute(k.db);

    const rows = (
      await sql<{
        id: string;
        phash: string;
        size: number;
        taken_at: number;
        rel_path: string;
      }>`
        select id, phash, size, taken_at, rel_path from photo_items
         where in_trash = 0 and phash is not null and phash <> '' and ${ownerFilter(uid)}
         order by taken_at asc, id asc
         limit 40000
      `.execute(k.db)
    ).rows;

    const buckets = new Map<string, typeof rows>();
    for (const row of rows) {
      const prefix = String(row.phash).slice(0, PREFIX_LEN);
      if (!buckets.has(prefix)) buckets.set(prefix, []);
      buckets.get(prefix)!.push(row);
    }

    let groups = 0;
    for (const list of buckets.values()) {
      if (list.length < 2 || list.length > MAX_BUCKET) continue;
      const bits = list.map((r) => hexBits(String(r.phash)));
      const used = new Set<number>();
      for (let i = 0; i < list.length; i += 1) {
        if (used.has(i)) continue;
        used.add(i);
        const members: number[] = [i];
        let worst = 0;
        for (let j = i + 1; j < list.length; j += 1) {
          if (used.has(j)) continue;
          const d = hamming(bits[i], bits[j]);
          if (d <= PHASH_DISTANCE) {
            used.add(j);
            members.push(j);
            if (d > worst) worst = d;
          }
        }
        if (members.length < 2) continue;
        const group = members.map((idx) => list[idx]);
        const leader = group.reduce((a, b) => (Number(a.size) >= Number(b.size) ? a : b));
        const ids = group.map((r) => r.id);
        await sql`
          insert into photo_phash_groups (id, owner_id, leader_id, member_ids, distance, created_at)
          values (${`pg_${crypto.randomUUID().replace(/-/g, '').slice(0, 16)}`}, ${uid},
                  ${leader.id}, ${JSON.stringify(ids)}, ${worst}, ${Math.floor(Date.now() / 1000)})
        `.execute(k.db);
        groups += 1;
      }
    }
    state.groups = groups;
    state.phase = 'done';
  } catch (err) {
    k.log.error({ err: String((err as Error)?.message || err) }, 'phash task failed');
    state.phase = 'done';
  } finally {
    state.running = false;
  }
}

export async function registerPhotoPhash(app: FastifyInstance, k: KernelApi): Promise<void> {
  app.get(
    '/api/v1/photo/cleanup/phash/status',
    secured('photo:read', {
      schema: {
        operationId: 'photoPhashStatus',
        tags: ['photo'],
        summary: '相似照片感知哈希扫描进度',
        response: { 200: ref('PhotoPhashStatus') },
      },
    }),
    async () => ({
      running: state.running,
      phase: state.phase,
      done: state.done,
      total: state.total,
      percent:
        state.total <= 0
          ? state.running
            ? 0
            : 100
          : Math.min(100, Math.round((state.done / state.total) * 100)),
      groups: state.groups,
      failed: state.failed,
      threshold: PHASH_DISTANCE,
    }),
  );

  app.post(
    '/api/v1/photo/cleanup/phash/scan',
    secured('photo:write', {
      schema: {
        operationId: 'photoPhashScan',
        tags: ['photo'],
        summary: '开始相似照片扫描（pHash 扫描 → 比对）',
        response: { 200: ref('PhotoPhashScanResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String((req as any).user?.sub || '');
      if (!state.running) {
        state.done = 0;
        state.total = 0;
        state.groups = 0;
        state.failed = 0;
        void runPhash(k, uid);
      }
      return { started: true };
    },
  );
}