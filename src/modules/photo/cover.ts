import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';

/**
 * 首页 / 记忆卡片封面挑选：严格按用户口径的 6 级优先序。
 *
 *   1 横屏 + 前 5 人脸    2 竖屏 + 前 5 人脸
 *   3 横屏 + 有人脸       4 竖屏 + 有人脸
 *   5 横屏（无人脸）      6 竖屏（无人脸）
 *
 * 「前 5 人脸」= 照片里出现了人数最多的前 5 个人脸簇之一；
 * 「有人脸」= photo_faces 有任意一行（含未归簇 / 未命名）。
 *
 * 2026-11-09 口径修正：旧版是「前 3 大簇 + 命中簇数加权 + 横屏同档 +50」，
 * 会出现「竖屏命中 3 簇(1200) 压过横屏命中 1 簇(1150)」，横屏不是硬优先。
 * 现在横屏在同一人脸档内是硬优先，命中几个簇不再细分；六档全部能出封面，
 * 不会因为没有 top 人脸就掉回按构图分挑的照片。
 */

/** 前 5 大簇在每张照片里出现的簇数（已截到 5） */
export async function topFacePresence(k: KernelApi): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  const top = (
    await sql<{ id: string }>`
      select id from photo_face_clusters order by size desc limit 5
    `.execute(k.db)
  ).rows.map((r) => r.id);
  if (!top.length) return out;

  const rows = (
    await sql<{ photo_id: string; n: number }>`
      select photo_id, count(distinct cluster_id) as n
        from photo_faces
       where cluster_id in (${sql.join(
         top.map((id) => sql`${id}`),
         sql`, `,
       )})
       group by photo_id
    `.execute(k.db)
  ).rows;
  for (const r of rows) out.set(r.photo_id, Math.min(Number(r.n) || 0, 5));
  return out;
}

/**
 * 「这张照片里有人」的照片 id 集合。只要 photo_faces 有一行就算，
 * 不管有没有归簇、是不是前三大簇、有没有命名。
 *
 * 传 [ids] 时只在候选里查（按 400 一批，走 idx_photo_faces_photo），
 * 不传才是全库；后者只给没有候选集的调用方兜底。
 */
export async function anyFacePresence(
  k: KernelApi,
  ids?: string[],
): Promise<Set<string>> {
  const out = new Set<string>();
  if (ids && ids.length === 0) return out;
  if (!ids) {
    const rows = (
      await sql<{ photo_id: string }>`select distinct photo_id from photo_faces`.execute(k.db)
    ).rows;
    for (const r of rows) out.add(r.photo_id);
    return out;
  }
  for (let i = 0; i < ids.length; i += 400) {
    const batch = ids.slice(i, i + 400);
    const rows = (
      await sql<{ photo_id: string }>`
        select distinct photo_id from photo_faces
         where photo_id in (${sql.join(
           batch.map((id) => sql`${id}`),
           sql`, `,
         )})
      `.execute(k.db)
    ).rows;
    for (const r of rows) out.add(r.photo_id);
  }
  return out;
}

/** 横屏判定：拿不到宽高（老库 / 视频 / 探测失败）一律当竖屏，不加分也不剔除 */
export function isLandscape(w: unknown, h: unknown): boolean {
  const a = Number(w) || 0;
  const b = Number(h) || 0;
  return a > 0 && b > 0 && a > b;
}

/**
 * 6 级优先序 → 分数（6..1，越大越优先），沿用调用方的降序排序。
 * faceN > 0 只表示「命中前 5 簇」，命中几个簇不再加权。
 */
export function coverScore(faceN: number, hasAnyFace: boolean, landscape: boolean): number {
  const rank = faceN > 0
    ? (landscape ? 1 : 2)
    : hasAnyFace
      ? (landscape ? 3 : 4)
      : (landscape ? 5 : 6);
  return 7 - rank;
}

/** 是否命中前 5 人脸簇（rank 1/2 → 分数 6/5） */
export function hasTopFace(score: number): boolean {
  return score >= 5;
}

/**
 * 给一批照片 id 造一个打分函数。
 * 候选不多时（首页那年今日 ≤120 张）直接批量查宽高，避免调用方自己拼 SQL。
 */
export async function coverRanker(
  k: KernelApi,
  ids: string[],
): Promise<(id: string) => number> {
  const faceN = await topFacePresence(k);
  const anyFace = await anyFacePresence(k, ids);
  const landscape = new Set<string>();

  for (let i = 0; i < ids.length; i += 400) {
    const batch = ids.slice(i, i + 400);
    const rows = (
      await sql<{ id: string; width: number | null; height: number | null }>`
        select id, width, height from photo_items
         where id in (${sql.join(
           batch.map((id) => sql`${id}`),
           sql`, `,
         )})
      `.execute(k.db)
    ).rows;
    for (const r of rows) if (isLandscape(r.width, r.height)) landscape.add(r.id);
  }

  return (id: string) =>
    coverScore(faceN.get(id) || 0, anyFace.has(id), landscape.has(id));
}
