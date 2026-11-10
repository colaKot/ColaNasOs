import { sql } from 'kysely';
import { ftsPhrase } from '../../files/fts';
import { secured } from '../../../../kernel/route';
import type { KernelApi } from '../../../../kernel/types';
import { aiAvailable, ensureSidecar } from './sidecar';
import { aiConfig } from './config';
import { scorePhotoVector } from './photo-vector';
import { ref } from './schemas';
import type { FastifyRequest } from 'fastify';

/**
 * 语义搜索。
 *
 * 查询侧：中文短语 → 场景标签（sidecar 的 512 词表 + 权威绑定 + 多命中加成）。
 * 检索侧：标签召回（场景 ∪ 活动）→ **有序绑定取交集**（AND 语义）→ 交集为空退并集；
 * 再与 OCR 文本 / 路径做**迟到融合**：OCR 命中 +0.8、路径命中 +0.3、多标签命中 ×(1+0.35×(n-1))。
 *
 * 词表不可用（缺模型）时降级为纯文字搜索，并在响应里标 degraded —— 不让整页 500。
 */
interface ParsedQuery {
  normalized?: string;
  tags?: Array<{ label: string; score: number; hits: number; from?: string[] }>;
  unmatched?: string[];
  components?: Array<{ key: string; binding: string; tag: string; via: string }>;
}

function likePattern(q: string): string {
  return `%${q.replace(/[\s\u3000]+/g, '').replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}

/**
 * 宠物类标签门控（AI 设置里的宠物识别开关）。
 *
 * 词表里「猫 / 狗 / 宠物」绑定的是「宠物特写 / 宠物店 / 狗舍」这类标签，
 * 但 CLIP 对这些短语的最近邻噪声很大（实测「猫」→「地下墓穴 0.97」）。
 * 关掉开关就从解析结果里摘掉这些标签，避免污染召回；打开才放行。
 * 过滤同时作用在 tags 与 components，前端不会看到「已命中但搜不出来」的假标签。
 */
const PET_TAG = /宠物|猫|狗|鸟|兔|仓鼠|动物|喵|汪/;

function applyPetFilter(parsed: ParsedQuery | null, enabled: boolean): ParsedQuery | null {
  if (!parsed || enabled) return parsed;
  return {
    ...parsed,
    tags: (parsed.tags || []).filter((t) => !PET_TAG.test(String(t.label || ''))),
    components: (parsed.components || []).map((c) =>
      PET_TAG.test(String(c.tag || '')) || PET_TAG.test(String(c.binding || ''))
        ? { ...c, tag: '', via: 'filtered_pet' }
        : c,
    ),
  };
}

async function parseQuery(k: KernelApi, q: string): Promise<ParsedQuery | null> {
  if (!aiAvailable()) return null;
  try {
    const s = await ensureSidecar(k);
    const parsed = await s.request<ParsedQuery>('semantic', { query: q }, 30_000);
    return applyPetFilter(parsed, aiConfig(k).petEnabled);
  } catch (err) {
    k.log.warn({ err: String((err as Error)?.message || err) }, 'semantic parse failed');
    return null;
  }
}

export interface SemanticHit {
  id: string;
  score: number;
  matched: string[];
}

export interface SemanticScore {
  /** 按相关度降序的命中 id（最多 300 条） */
  hits: SemanticHit[];
  tags: string[];
  /** 解码后的标签对象（含 score / hits），给需要原样回包的接口用 */
  tagsDetail: Array<{ label: string; score: number; hits: number }>;
  unmatched: string[];
  degraded: boolean;
  reason: string;
}

/**
 * 语义检索的**纯打分**部分（不做分页、不查整行）。
 *
 * 抽出来是为了让「语义搜索」和「搜索框混合检索」用**同一份口径**：
 * 两份实现一定会漂移（改了一边忘了另一边），而用户只会觉得"两个地方搜出来不一样"。
 */
export async function scoreSemantic(
  k: KernelApi,
  q: string,
  opts: { uid: string; limit?: number },
): Promise<SemanticScore> {
  const query = String(q || '').trim();
  const limit = Math.max(1, Math.min(Number(opts.limit) || 300, 300));
  if (!query) {
    return { hits: [], tags: [], tagsDetail: [], unmatched: [], degraded: false, reason: '' };
  }

  const parsed = await parseQuery(k, query);
  const degraded = parsed === null;
  const reason = degraded ? '语义词表不可用，已降级为标签 / 文字搜索' : '';
  const tagsDetail = (parsed?.tags || [])
    .slice(0, 8)
    .map((t) => ({
      label: String(t.label),
      score: Number(t.score) || 0,
      hits: Number(t.hits) || 1,
    }))
    .filter((t) => t.label);
  const tags = tagsDetail.map((t) => t.label);

  const owner = sql`i.library_id in (select id from photo_libraries where owner_id = ${opts.uid})`;

  // 每个标签的照片集合（场景 + 活动合并）
  const sets: Array<{ tag: string; ids: Set<string> }> = [];
  for (const tag of tags) {
    const ids = new Set<string>();
    const sceneRows = (
      await sql<{ id: string }>`
        select s.photo_id as id from photo_scenes s
          join photo_items i on i.id = s.photo_id
         where s.label = ${tag} and i.in_trash = 0 and ${owner} limit 5000
      `.execute(k.db)
    ).rows;
    for (const r of sceneRows) ids.add(r.id);
    const actRows = (
      await sql<{ id: string }>`
        select a.photo_id as id from photo_activities a
          join photo_items i on i.id = a.photo_id
         where a.label = ${tag} and a.score >= 0.078 and i.in_trash = 0 and ${owner} limit 5000
      `.execute(k.db)
    ).rows;
    for (const r of actRows) ids.add(r.id);
    sets.push({ tag, ids });
  }

  const nonEmpty = sets.filter((s) => s.ids.size > 0);
  let base = new Set<string>();
  if (nonEmpty.length > 0) {
    base = new Set(nonEmpty[0].ids);
    for (const s of nonEmpty.slice(1)) {
      const next = new Set<string>();
      for (const id of base) if (s.ids.has(id)) next.add(id);
      if (next.size === 0) break;
      base = next;
    }
    if (base.size === 0) {
      for (const s of nonEmpty) for (const id of s.ids) base.add(id);
    }
  }

  // 文字融合：OCR / 路径（票号、车次这类查询走这里最快）
  const like = likePattern(query);
  const fts = ftsPhrase(query);
  const ocrRows = (
    await sql<{ id: string }>`
      select o.photo_id as id from photo_ocr o
        join photo_items i on i.id = o.photo_id
       where ${fts
         ? sql`o.rowid in (select rowid from photo_ocr_fts where photo_ocr_fts match ${fts})`
         : sql`o.text like ${like} escape '\\'`}
         and i.in_trash = 0 and ${owner}
       limit 3000
    `.execute(k.db)
  ).rows;
  const pathRows = (
    await sql<{ id: string }>`
      select i.id from photo_items i
       where i.in_trash = 0 and ${owner} and i.rel_path like ${like} escape '\\'
       limit 3000
    `.execute(k.db)
  ).rows;

  const scores = new Map<string, { score: number; matched: Set<string> }>();
  const bump = (id: string, value: number, label: string) => {
    const rec = scores.get(id) || { score: 0, matched: new Set<string>() };
    rec.score += value;
    rec.matched.add(label);
    scores.set(id, rec);
  };
  for (const s of sets) {
    for (const id of s.ids) {
      if (sets.length > 1 && !base.has(id)) continue;
      bump(id, 1, s.tag);
    }
  }
  for (const rec of scores.values()) {
    rec.score *= 1 + 0.35 * Math.max(0, rec.matched.size - 1);
  }
  for (const r of ocrRows) bump(r.id, 0.8, 'ocr');
  for (const r of pathRows) bump(r.id, 0.3, 'path');

  // 照片级向量召回（补充粒度：标签没打上、或词表没有的概念也能捞回来）。
  // 只**追加**新 id、不重排已有命中：标签命中是确定性的，向量命中是概率的。
  const petOn = aiConfig(k).petEnabled;
  const vecKeys = [
    ...new Set(
      (parsed?.tags || []).flatMap((t) =>
        (t.from || []).filter((key) => petOn || !PET_TAG.test(key)),
      ),
    ),
  ];
  // 上限：标签/文字命中已经够多时不再掺向量结果（否则一搜 300 条里一半是概率性噪声）；
  // 命中稀疏（词表没覆盖、标签没打过）时才用向量补齐。
  const VISUAL_BUDGET = 120;
  const room = Math.max(0, VISUAL_BUDGET - scores.size);
  if (room > 0 && (vecKeys.length > 0 || tags.length > 0)) {
    const vis = await scorePhotoVector(
      k,
      { keys: vecKeys, labels: tags },
      { uid: opts.uid, limit: room },
    ).catch(() => ({ hits: [], truncated: false, degraded: true }));
    for (const h of vis.hits) {
      if (scores.has(h.id)) continue;
      // 压到「路径命中」的量级：视觉相似能排进结果，但不该盖过标签精确命中
      bump(h.id, Number((0.15 + h.score * 0.5).toFixed(3)), '视觉相似');
    }
  }

  const hits = [...scores.entries()]
    .sort((a, b) => b[1].score - a[1].score)
    .slice(0, limit)
    .map(([id, rec]) => ({
      id,
      score: Number(rec.score.toFixed(3)),
      matched: [...rec.matched],
    }));

  return {
    hits,
    tags,
    tagsDetail,
    unmatched: parsed?.unmatched || [],
    degraded,
    reason: hits.length === 0 ? reason || '没有匹配的照片' : reason,
  };
}

export async function registerPhotoSemantic(app: any, k: KernelApi): Promise<void> {
  app.get(
    '/api/v1/photo/semantic/parse',
    secured('photo:read', {
      schema: {
        operationId: 'photoSemanticParse',
        tags: ['photo'],
        summary: '语义查询解析：中文短语 → 场景标签（含未识别片段，便于提示）',
        querystring: ref('PhotoSemanticQuery'),
        response: { 200: ref('PhotoSemanticParse') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = String(((req.query || {}) as { q?: string }).q || '');
      const parsed = await parseQuery(k, q);
      if (!parsed) {
        return {
          ok: false,
          normalized: q,
          components: [],
          unmatched: [],
          tags: [],
          reason: '语义词表不可用（缺模型或 sidecar）',
        };
      }
      return {
        ok: parsed.tags ? parsed.tags.length > 0 : false,
        normalized: parsed.normalized || q,
        components: parsed.components || [],
        unmatched: parsed.unmatched || [],
        tags: parsed.tags || [],
        ...(parsed.tags && parsed.tags.length > 0 ? {} : { reason: 'no_component' }),
      };
    },
  );

  app.get(
    '/api/v1/photo/semantic/search',
    secured('photo:read', {
      schema: {
        operationId: 'photoSemanticSearch',
        tags: ['photo'],
        summary: '语义搜索：短语绑定标签（有序）+ OCR 文本融合；词表不可用时降级为文字搜索',
        querystring: ref('PhotoSemanticQuery'),
        response: { 200: ref('PhotoSemanticSearchResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = String(((req.query || {}) as { q?: string }).q || '').trim();
      if (!q) {
        return { normalized: '', tags: [], unmatched: [], items: [], degraded: false, reason: '' };
      }

      // 与「搜索框混合检索」共用同一份打分：以前这里有一份复制粘贴的实现，
      // 而且漏了 owner 过滤 —— 多账号部署下会把别人的照片搜出来。
      const uid = String((req as any).user?.sub || '');
      const score = await scoreSemantic(k, q, { uid, limit: 300 });
      if (score.hits.length === 0) {
        return {
          normalized: q,
          tags: score.tagsDetail,
          unmatched: score.unmatched,
          items: [],
          degraded: score.degraded,
          reason: score.reason,
        };
      }

      const ids = score.hits.map((h) => h.id);
      const photos = (
        await sql<{ id: string; rel_path: string; taken_at: number }>`
          select id, rel_path, taken_at from photo_items
           where id in (${sql.join(
             ids.map((id) => sql`${id}`),
             sql`, `,
           )}) and in_trash = 0
        `.execute(k.db)
      ).rows;
      const byId = new Map(photos.map((p) => [p.id, p]));

      const items = score.hits.flatMap((h) => {
        const p = byId.get(h.id);
        if (!p) return [];
        return [
          {
            id: p.id,
            path: p.rel_path,
            takenAt: Number(p.taken_at),
            score: h.score,
            matched: h.matched,
          },
        ];
      });

      return {
        normalized: q,
        tags: score.tagsDetail,
        unmatched: score.unmatched,
        items,
        degraded: score.degraded,
        reason: score.reason,
      };
    },
  );
}