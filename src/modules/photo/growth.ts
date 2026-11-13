import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import { chinaPlacePath } from './geo/china';
import { describePlace } from './geo/place-label';
import { decodeCursor, encodeCursor, newId, toItem, type PhotoItemRow } from './util';

/**
 * 成长轨迹：服务端预计算「阶段」（Stage）。
 *
 * 分层 Asset → Event → Stage → Track：
 *   · Asset = photo_items 一行 + 它在该 person 下最清晰的那张脸；
 *   · Event = 同一天 / 相邻连拍，只在分段过程中隐式存在，不落表；
 *   · Stage = 地点 × 时间窗，UI 上的一条记录（封面 + 可选次图）；
 *   · Track = 某 person 的 Stage 有序序列，用 (owner, person, granularity) 索引表示。
 *
 * 设计文档里「规则负责分段、AI 负责选片」的分工在这里落地，但按本仓库现状
 * 做了可解释的降级（每一项都记进 reason_json，不假装有模型）：
 *   · 地点：离线行政区划 + GeoNames（chinaPlacePath / describePlace），城市级归并
 *     天然消除了「小区门口 vs 后门」的抖动；没有 DBSCAN / 停留点 / 城市多边形；
 *   · 选片：人脸 quality / bbox 面积 / 场景多标签 / pHash 连拍去重；
 *     没有 NIMA/MUSIQ 美学分、人像分割与 CLIP MMR，权重见 scoreAsset()；
 *   · 文案：服务端只给结构化数据（地点、时间、里程碑枚举），UI 文案全走 i18n，
 *     title/subtitle 两列留给后续 VLM 阶段文案缓存。
 *
 * 性能：阶段是预计算落库的，前端只读；新增/删除照片后按 (person, granularity)
 * 的「照片数 + 最新拍摄时间」判定是否重算，只重算这一条 track。
 */

const DAY = 86_400;
const GAP_DAYS = 30;
const CANDIDATE_POOL = 12;

export type GrowthGranularity = 'auto' | 'month' | 'quarter' | 'year';

/** 场景标签是 AI 侧 zero-shot 词表，这里只做「风景 / 室内 / 不能用」三类粗判。
 *  命中不了时退化为标签数量，绝不因为词表差异把整段照片全判成废片。 */
const OUTDOOR_LABEL = /海|沙滩|山|雪|湖|河|森林|草原|公园|街|户外|风景|广场|地标|天空|field|beach|sea|mountain|snow|lake|river|forest|park|street|outdoor|landscape|sky|city/i;
const INDOOR_LABEL = /室内|客厅|卧室|厨房|餐厅|办公室|白墙|indoor|living|bedroom|kitchen|office|wall/i;
const BAD_LABEL = /截图|文档|屏幕|表情包|二维码|screenshot|document|screen|meme|qrcode/i;

interface GrowthAsset {
  id: string;
  path: string;
  takenAt: number;
  lat: number | null;
  lng: number | null;
  geohash4: string;
  geohash5: string;
  width: number;
  height: number;
  favorite: boolean;
  phash: string;
  quality: number;
  faceScore: number;
  boxLeft: number;
  boxTop: number;
  boxWidth: number;
  boxHeight: number;
  imgWidth: number;
  imgHeight: number;
}

interface AssetRow {
  id: string;
  rel_path: string;
  taken_at: number;
  latitude: number | null;
  longitude: number | null;
  geohash4: string | null;
  geohash5: string | null;
  width: number | null;
  height: number | null;
  favorite: number | null;
  phash: string | null;
  quality: number | null;
  score: number | null;
  box_left: number | null;
  box_top: number | null;
  box_width: number | null;
  box_height: number | null;
  img_width: number | null;
  img_height: number | null;
}

export interface GrowthStageRow {
  id: string;
  owner_id: string;
  person_id: string;
  granularity: string;
  seq: number;
  start_at: number;
  end_at: number;
  place_key: string;
  place_name: string;
  span_kind: string;
  title: string;
  subtitle: string;
  cover_asset_id: string | null;
  cover_path: string;
  secondary_path: string;
  cover_score: number;
  reason_json: string;
  photo_count: number;
  milestone: string;
  hint: string;
  locked: number;
  hidden: number;
  version: number;
  created_at: number;
  updated_at: number;
}

interface StageDraft {
  placeKey: string;
  placeName: string;
  spanKind: string;
  startAt: number;
  endAt: number;
  assets: GrowthAsset[];
}

interface Scored {
  asset: GrowthAsset;
  score: number;
  grade: number;
  /** 横屏照片（宽 > 高）：成长轨迹优先用横屏，视觉上比竖图更适合时间轴 */
  wide: boolean;
  reason: Record<string, unknown>;
}

interface PickResult {
  cover: Scored | null;
  secondary: GrowthAsset | null;
  candidates: Scored[];
  hint: string;
}

const clamp01 = (n: number) => Math.max(0, Math.min(1, n));
const num = (v: unknown) => Number(v) || 0;
const now = () => Math.floor(Date.now() / 1000);

export function normalizeGranularity(raw: unknown): GrowthGranularity {
  const v = String(raw || '').toLowerCase();
  return v === 'month' || v === 'quarter' || v === 'year' || v === 'auto'
    ? v
    : 'auto';
}

/** 自动粒度按「轨迹起点」（该人首张照片）后的月龄自适应：
 *  0–1 岁月度、1–3 岁季度、3–6 岁半年、6 岁以后年度。
 *  这里只用 EXIF 真实时间，绝不估年龄 / 身高（设计文档明确禁止）。 */
function spanDaysFor(g: GrowthGranularity, ageMonths: number): number {
  if (g === 'month') return 30;
  if (g === 'quarter') return 90;
  if (g === 'year') return 365;
  if (ageMonths < 12) return 30;
  if (ageMonths < 36) return 90;
  if (ageMonths < 72) return 180;
  return 365;
}

function spanKindOf(g: GrowthGranularity, days: number): string {
  if (g !== 'auto') return g;
  if (days <= 30) return 'month';
  if (days <= 90) return 'quarter';
  if (days <= 180) return 'halfYear';
  return 'year';
}

/** 城市级归并：国内取「省 + 市」，国外取国家中文名，都没有则退到 geohash4 网格。 */
function resolvePlace(a: GrowthAsset): { key: string; name: string } {
  const lat = Number(a.lat);
  const lng = Number(a.lng);
  const hasGps = Number.isFinite(lat) && Number.isFinite(lng) && !(lat === 0 && lng === 0);
  if (!hasGps) return { key: 'unknown', name: '' };

  const path = chinaPlacePath(lat, lng);
  if (path) {
    const parts = path.split(' ').filter(Boolean);
    return {
      key: parts.slice(0, Math.min(2, parts.length)).join(' '),
      name: parts.length >= 2 ? parts[1] : parts[0],
    };
  }
  const name = describePlace(a.geohash5, lat, lng, 'zh-CN');
  return { key: name || a.geohash4 || 'unknown', name };
}

async function loadAssets(k: KernelApi, owner: string, personId: string): Promise<GrowthAsset[]> {
  const rows = (
    await sql<AssetRow>`
      select i.id, i.rel_path, i.taken_at, i.latitude, i.longitude,
             i.geohash4, i.geohash5, i.width, i.height, i.favorite, i.phash,
             f.quality, f.score, f.box_left, f.box_top, f.box_width, f.box_height,
             f.img_width, f.img_height
        from photo_items i
        join photo_faces f on f.photo_id = i.id and f.cluster_id = ${personId}
       where i.in_trash = 0
         and i.library_id in (select id from photo_libraries where owner_id = ${owner})
       order by i.taken_at asc, i.id asc
    `.execute(k.db)
  ).rows;

  // 同一张照片可能被识别出多张同簇人脸：只留 quality 最高的那张脸。
  const byId = new Map<string, GrowthAsset>();
  for (const r of rows) {
    const prev = byId.get(r.id);
    const quality = num(r.quality) || num(r.score) * 100;
    if (prev && prev.quality >= quality) continue;
    byId.set(r.id, {
      id: r.id,
      path: String(r.rel_path || ''),
      takenAt: num(r.taken_at),
      lat: r.latitude,
      lng: r.longitude,
      geohash4: String(r.geohash4 || ''),
      geohash5: String(r.geohash5 || ''),
      width: num(r.width),
      height: num(r.height),
      favorite: num(r.favorite) === 1,
      phash: String(r.phash || ''),
      quality,
      faceScore: num(r.score),
      boxLeft: num(r.box_left),
      boxTop: num(r.box_top),
      boxWidth: num(r.box_width),
      boxHeight: num(r.box_height),
      imgWidth: num(r.img_width),
      imgHeight: num(r.img_height),
    });
  }
  return [...byId.values()].sort((a, b) => a.takenAt - b.takenAt || a.id.localeCompare(b.id));
}

/** 规则分段：地点变化 / 相邻间隔 > 30 天 / 本段跨度超过粒度阈值，三者任一成立就切。
 *  无 GPS 的照片只并入当前段（同一天内），不新建城市；一天跨城按城市级归并，
 *  不按「到家/到幼儿园」这种点位跳变切段。 */
function buildStages(assets: GrowthAsset[], g: GrowthGranularity): StageDraft[] {
  const out: StageDraft[] = [];
  let cur: StageDraft | null = null;
  const firstAt = assets[0]?.takenAt ?? 0;

  for (const a of assets) {
    const place = resolvePlace(a);
    const noGps = place.key === 'unknown';
    const ageMonths = (a.takenAt - firstAt) / (30 * DAY);
    const spanDays = spanDaysFor(g, ageMonths);
    const sameDay = cur ? Math.floor(a.takenAt / DAY) === Math.floor(cur.endAt / DAY) : false;
    const split = !cur
      || (!noGps && cur.placeKey !== 'unknown' && place.key !== cur.placeKey)
      || (a.takenAt - cur.endAt > GAP_DAYS * DAY)
      || (a.takenAt - cur.startAt > spanDays * DAY)
      || (noGps && !sameDay && cur.placeKey !== 'unknown');

    if (split) {
      cur = {
        placeKey: place.key,
        placeName: place.name,
        spanKind: spanKindOf(g, spanDays),
        startAt: a.takenAt,
        endAt: a.takenAt,
        assets: [],
      };
      out.push(cur);
    }
    const stage = cur!;
    stage.assets.push(a);
    stage.endAt = a.takenAt;
  }
  return out;
}

/** 该 person 相关的全部场景标签；photo_scenes 是老库的 top-1 单标签，一并并入。 */
async function loadSceneLabels(k: KernelApi, personId: string): Promise<Map<string, Set<string>>> {
  const rows = (
    await sql<{ photo_id: string; label: string }>`
      select t.photo_id, t.label
        from photo_scene_tags t
       where exists (select 1 from photo_faces f
                      where f.photo_id = t.photo_id and f.cluster_id = ${personId})
      union all
      select s.photo_id, s.label
        from photo_scenes s
       where exists (select 1 from photo_faces f
                      where f.photo_id = s.photo_id and f.cluster_id = ${personId})
    `.execute(k.db)
  ).rows;
  const out = new Map<string, Set<string>>();
  for (const r of rows) {
    const label = String(r.label || '').trim();
    if (!label) continue;
    const set = out.get(r.photo_id) ?? new Set<string>();
    set.add(label);
    out.set(r.photo_id, set);
  }
  return out;
}

/** 可解释的降级打分。每项都写进 reason_json，长按「换一张」时能看出为什么。 */
function scoreAsset(a: GrowthAsset, labels: Set<string>): Scored {
  const area = a.imgWidth > 0 && a.imgHeight > 0
    ? (a.boxWidth * a.boxHeight) / (a.imgWidth * a.imgHeight)
    : 0;
  const ratio = clamp01(area);
  const faceQuality = clamp01(a.quality / 100);
  const centerX = a.imgWidth > 0 ? (a.boxLeft + a.boxWidth / 2) / a.imgWidth : 0.5;
  const centerY = a.imgHeight > 0 ? (a.boxTop + a.boxHeight / 2) / a.imgHeight : 0.5;
  const centerBonus = clamp01(1 - Math.hypot(centerX - 0.5, centerY - 0.5) * 1.4);
  const composition = clamp01(1 - Math.abs(ratio - 0.18) / 0.35) * 0.75 + centerBonus * 0.25;
  const richness = clamp01(labels.size / 4);
  const landscape = [...labels].some((l) => OUTDOOR_LABEL.test(l));
  // photo_items 的宽高老库可能没探测到；人脸检测时的原图尺寸是可靠后备，
  // 否则这批照片会被一律当成竖图，横屏优先就失效了。
  const w = a.width > 0 ? a.width : a.imgWidth;
  const h = a.height > 0 ? a.height : a.imgHeight;
  const wide = w > 0 && h > 0 && w > h;
  const indoor = [...labels].some((l) => INDOOR_LABEL.test(l));
  const background = landscape ? 1 : indoor ? 0.35 : labels.size >= 2 ? 0.6 : 0.2;
  const penalty = (ratio < 0.03 ? 0.15 : 0) + (ratio > 0.45 ? 0.1 : 0) + (faceQuality < 0.4 ? 0.1 : 0);
  const score = 0.35 * faceQuality
    + 0.25 * composition
    + 0.20 * richness
    + 0.10 * background
    + 0.05
    + 0.05 * (a.favorite ? 1 : 0)
    - penalty;

  // 人 + 景 > 人（含室内）> 纯风景 > 兜底；没有合格人景照时不静默省略，给 hint。
  const grade = ratio >= 0.08 && ratio <= 0.45 && background >= 0.6 && faceQuality >= 0.5
    ? 4
    : ratio >= 0.03 && ratio <= 0.45 && faceQuality >= 0.4
      ? 3
      : landscape && ratio < 0.08
        ? 2
        : 1;

  return {
    asset: a,
    score: Number(score.toFixed(4)),
    grade,
    wide,
    reason: {
      faceQuality: Number(faceQuality.toFixed(3)),
      composition: Number(composition.toFixed(3)),
      sceneRichness: Number(richness.toFixed(3)),
      background: Number(background.toFixed(3)),
      faceAreaRatio: Number(ratio.toFixed(3)),
      orientation: wide ? 'landscape' : 'portrait',
      labels: [...labels].slice(0, 8),
      grade: grade === 4 ? 'scenePortrait' : grade === 3 ? 'portrait' : grade === 2 ? 'scenery' : 'fallback',
      // 明确标注：没有美学模型 / 人像分割 / CLIP MMR，这是规则降级版
      degraded: true,
    },
  };
}

function pickCover(assets: GrowthAsset[], labelsOf: (a: GrowthAsset) => Set<string>): PickResult {
  const scored: Scored[] = [];
  for (const a of assets) {
    const labels = labelsOf(a);
    if ([...labels].some((l) => BAD_LABEL.test(l))) continue; // 截图 / 文档 / 表情包
    scored.push(scoreAsset(a, labels));
  }
  // 横屏优先：时间轴一行一张横图最好看；同一方向内部仍按人+景等级、可解释分排序。
  // 宽高缺失（老库/视频）按竖图处理，绝不凭空当横屏。
  scored.sort((x, y) =>
    Number(y.wide) - Number(x.wide)
    || y.grade - x.grade
    || y.score - x.score
    || x.asset.id.localeCompare(y.asset.id));

  // 连拍去重：同一 pHash 只留最高分的一张。
  const seenHash = new Set<string>();
  const unique: Scored[] = [];
  for (const s of scored) {
    const h = s.asset.phash;
    if (h && seenHash.has(h)) continue;
    if (h) seenHash.add(h);
    unique.push(s);
  }
  const pool = unique.length > 0 ? unique : scored;
  const widePool = pool.filter((s) => s.wide);
  const tallPool = pool.filter((s) => !s.wide);
  const cover = widePool[0] ?? tallPool[0] ?? null;

  // 排版策略（用户口径）：
  //   · 有横屏 → 只出一张横图，跨整行完整显示，不再并排把宽图挤窄；
  //   · 实在没有横屏 → 尽量凑两张竖图并排，避免单张竖图把卡片撑得又高又空。
  let secondary: GrowthAsset | null = null;
  if (cover && !cover.wide) {
    secondary = tallPool.find((s) => {
      if (s.asset.id === cover.asset.id) return false;
      // 两边都没算过 pHash 时不能因为「都为空」误判成连拍，
      // 否则明明有多张竖图也只剩一张。
      const a = s.asset.phash;
      const b = cover.asset.phash;
      return !a || !b || a !== b;
    })?.asset ?? null;
  }
  return {
    cover,
    secondary,
    candidates: pool.slice(0, CANDIDATE_POOL),
    hint: cover && cover.grade < 4 ? 'noScenePortrait' : '',
  };
}

interface StageSize {
  width: number | null;
  height: number | null;
}

function stageJson(r: GrowthStageRow, cover?: StageSize | null, secondary?: StageSize | null) {
  return {
    id: r.id,
    seq: num(r.seq),
    startAt: num(r.start_at),
    endAt: num(r.end_at),
    placeKey: String(r.place_key || ''),
    placeName: String(r.place_name || ''),
    spanKind: String(r.span_kind || 'auto'),
    coverAssetId: r.cover_asset_id ?? null,
    coverPath: String(r.cover_path || ''),
    secondaryPath: r.secondary_path ? String(r.secondary_path) : null,
    // 原始宽高给前端按真实比例自适应（竖图不再被固定高度裁成横条）
    coverWidth: cover?.width ?? null,
    coverHeight: cover?.height ?? null,
    secondaryWidth: secondary?.width ?? null,
    secondaryHeight: secondary?.height ?? null,
    photoCount: num(r.photo_count),
    coverScore: num(r.cover_score),
    milestone: String(r.milestone || ''),
    hint: String(r.hint || ''),
    locked: num(r.locked) === 1,
    hidden: num(r.hidden) === 1,
    version: num(r.version),
  };
}

export function growthStageJson(r: GrowthStageRow) {
  return stageJson(r);
}

/** 批量取本页封面的原始宽高（cover 按 id、次图按 rel_path），一页最多 100 条。 */
async function loadStageSizes(k: KernelApi, rows: GrowthStageRow[]) {
  const byId = new Map<string, StageSize>();
  const byPath = new Map<string, StageSize>();
  const ids = [...new Set(rows.map((r) => r.cover_asset_id).filter((x): x is string => !!x))];
  const paths = [...new Set(rows.map((r) => r.secondary_path).filter((p) => !!p))];

  if (ids.length > 0) {
    const res = (
      await sql<{ id: string; width: number | null; height: number | null }>`
        select i.id,
               coalesce(i.width,
                 (select max(f.img_width) from photo_faces f where f.photo_id = i.id)) as width,
               coalesce(i.height,
                 (select max(f.img_height) from photo_faces f where f.photo_id = i.id)) as height
          from photo_items i
         where i.id in (${sql.join(ids.map((id) => sql`${id}`), sql`, `)})
      `.execute(k.db)
    ).rows;
    for (const r of res) byId.set(r.id, { width: r.width ?? null, height: r.height ?? null });
  }
  if (paths.length > 0) {
    const res = (
      await sql<{ rel_path: string; width: number | null; height: number | null }>`
        select i.rel_path,
               coalesce(i.width,
                 (select max(f.img_width) from photo_faces f where f.photo_id = i.id)) as width,
               coalesce(i.height,
                 (select max(f.img_height) from photo_faces f where f.photo_id = i.id)) as height
          from photo_items i
         where i.rel_path in (${sql.join(paths.map((p) => sql`${p}`), sql`, `)})
      `.execute(k.db)
    ).rows;
    for (const r of res) {
      if (!byPath.has(r.rel_path)) {
        byPath.set(r.rel_path, { width: r.width ?? null, height: r.height ?? null });
      }
    }
  }
  return { byId, byPath };
}

async function trackFingerprint(k: KernelApi, owner: string, personId: string) {
  const row = (
    await sql<{ n: number; last_at: number }>`
      select count(distinct i.id) as n, coalesce(max(i.taken_at), 0) as last_at
        from photo_items i
        join photo_faces f on f.photo_id = i.id and f.cluster_id = ${personId}
       where i.in_trash = 0
         and i.library_id in (select id from photo_libraries where owner_id = ${owner})
    `.execute(k.db)
  ).rows[0];
  return { count: num(row?.n), lastAt: num(row?.last_at) };
}

/** 重算一条 track。同一进程内并发调用合并成一次，避免两个请求同时建表数据。 */
const building = new Map<string, Promise<{ stages: number; photos: number; version: number }>>();

export async function rebuildTrack(
  k: KernelApi,
  owner: string,
  personId: string,
  granularity: GrowthGranularity,
): Promise<{ stages: number; photos: number; version: number }> {
  const key = `${owner}|${personId}|${granularity}`;
  const pending = building.get(key);
  if (pending) return pending;

  const run = (async () => {
    const assets = await loadAssets(k, owner, personId);
    const fingerprint = await trackFingerprint(k, owner, personId);
    const drafts = buildStages(assets, granularity);
    const sceneLabels = await loadSceneLabels(k, personId);
    const labelsOf = (a: GrowthAsset) => sceneLabels.get(a.id) ?? new Set<string>();

    const old = (
      await sql<GrowthStageRow>`
        select * from photo_growth_stages
         where owner_id = ${owner} and person_id = ${personId} and granularity = ${granularity}
      `.execute(k.db)
    ).rows;
    // 人工指定的封面不能因为重算被冲掉：按 asset id 找回它在新段里的位置。
    const pins = new Set(old.filter((r) => num(r.locked) === 1 && r.cover_asset_id).map((r) => String(r.cover_asset_id)));
    const hiddenKeys = new Set(
      old.filter((r) => num(r.hidden) === 1).map((r) => `${r.place_key}|${Math.floor(num(r.start_at) / (30 * DAY))}`),
    );
    const version = Math.max(0, ...old.map((r) => num(r.version))) + 1;
    const ts = now();

    const seenPlaces = new Set<string>();
    let seenScenery = false;
    const prepared = drafts.map((d, i) => {
      const picked = pickCover(d.assets, labelsOf);
      let cover = picked.cover;
      let secondary = picked.secondary;
      const pinned = d.assets.find((a) => pins.has(a.id));
      if (pinned) {
        const s = scoreAsset(pinned, labelsOf(pinned));
        cover = { ...s, reason: { ...s.reason, manualPin: true } };
        // 人工换封面也要遵守同一套排版口径：横图单张、竖图尽量再配一张竖图。
        secondary = s.wide
          ? null
          : picked.candidates.find((c) =>
              c.asset.id !== pinned.id
              && !c.wide
              && (!pinned.phash || !c.asset.phash || c.asset.phash !== pinned.phash),
            )?.asset ?? null;
      }
      const hasScenery = d.assets.some((a) => [...labelsOf(a)].some((l) => OUTDOOR_LABEL.test(l)));
      const firstPlace = d.placeKey !== 'unknown' && !seenPlaces.has(d.placeKey);
      if (d.placeKey !== 'unknown') seenPlaces.add(d.placeKey);
      const firstScene = hasScenery && !seenScenery;
      if (hasScenery) seenScenery = true;
      const milestone = firstPlace ? 'firstPlace' : firstScene ? 'firstScene' : '';

      return {
        stage: d,
        pick: picked,
        cover,
        secondary,
        milestone,
        hidden: hiddenKeys.has(`${d.placeKey}|${Math.floor(d.startAt / (30 * DAY))}`) ? 1 : 0,
        seq: i + 1,
      };
    });

    await k.db.transaction().execute(async (trx: any) => {
      await sql`
        delete from photo_growth_stage_assets
         where stage_id in (select id from photo_growth_stages
                             where owner_id = ${owner} and person_id = ${personId}
                               and granularity = ${granularity})
      `.execute(trx);
      await sql`
        delete from photo_growth_stages
         where owner_id = ${owner} and person_id = ${personId} and granularity = ${granularity}
      `.execute(trx);

      for (const p of prepared) {
        const id = newId();
        const cover = p.cover;
        const reason = cover ? JSON.stringify(cover.reason) : '{}';
        await sql`
          insert into photo_growth_stages
            (id, owner_id, person_id, granularity, seq, start_at, end_at,
             place_key, place_name, span_kind, title, subtitle,
             cover_asset_id, cover_path, secondary_path, cover_score, reason_json,
             photo_count, milestone, hint, locked, hidden, version, created_at, updated_at)
          values
            (${id}, ${owner}, ${personId}, ${granularity}, ${p.seq},
             ${p.stage.startAt}, ${p.stage.endAt}, ${p.stage.placeKey}, ${p.stage.placeName},
             ${p.stage.spanKind}, ${p.stage.placeName}, ${''},
             ${cover?.asset.id ?? null}, ${cover?.asset.path ?? ''}, ${p.secondary?.path ?? ''},
             ${cover?.score ?? 0}, ${reason}, ${p.stage.assets.length},
             ${p.milestone}, ${p.pick.hint}, ${p.cover && pins.has(p.cover.asset.id) ? 1 : 0},
             ${p.hidden}, ${version}, ${ts}, ${ts})
        `.execute(trx);

        for (let rank = 0; rank < p.pick.candidates.length; rank += 1) {
          const c = p.pick.candidates[rank];
          await sql`
            insert into photo_growth_stage_assets (stage_id, asset_id, rank, score, reason_json)
            values (${id}, ${c.asset.id}, ${rank + 1}, ${c.score}, ${JSON.stringify(c.reason)})
          `.execute(trx);
        }
      }

      await sql`
        insert into photo_growth_track_state
          (owner_id, person_id, granularity, asset_count, last_asset_at, version, built_at)
        values (${owner}, ${personId}, ${granularity}, ${fingerprint.count}, ${fingerprint.lastAt}, ${version}, ${ts})
        on conflict(owner_id, person_id, granularity) do update set
          asset_count = excluded.asset_count,
          last_asset_at = excluded.last_asset_at,
          version = excluded.version,
          built_at = excluded.built_at
      `.execute(trx);
    });

    return { stages: prepared.length, photos: assets.length, version };
  })().finally(() => building.delete(key));

  building.set(key, run);
  return run;
}

/**
 * 列表请求前调一次：照片数 / 最新时间没变就直接读预计算结果。
 *
 * 进程启动后每条 track 的首次访问**强制重算一次**：分段 / 选片策略改了
 * （例如改成「横屏优先」）时 fingerprint 没变，光靠增量判断用户会一直看到
 * 旧策略选出的封面。dev.bat 的 watch-kernel 改代码就重启，正好触发重算；
 * 正式服务端重启也只是多花一次按人重算，人工指定的封面仍会保留。
 */
const warmedTracks = new Set<string>();

export async function ensureBuilt(
  k: KernelApi,
  owner: string,
  personId: string,
  granularity: GrowthGranularity,
): Promise<boolean> {
  const key = `${owner}|${personId}|${granularity}`;
  if (!warmedTracks.has(key)) {
    await rebuildTrack(k, owner, personId, granularity);
    warmedTracks.add(key);
    return true;
  }
  const state = (
    await sql<{ asset_count: number; last_asset_at: number; version: number }>`
      select asset_count, last_asset_at, version from photo_growth_track_state
       where owner_id = ${owner} and person_id = ${personId} and granularity = ${granularity}
    `.execute(k.db)
  ).rows[0];
  const fp = await trackFingerprint(k, owner, personId);
  if (state && num(state.version) > 0 && num(state.asset_count) === fp.count && num(state.last_asset_at) === fp.lastAt) {
    return false;
  }
  await rebuildTrack(k, owner, personId, granularity);
  return true;
}

export async function listPersons(k: KernelApi, owner: string, limit: number) {
  const rows = (
    await sql<{
      id: string;
      name: string | null;
      size: number;
      cover_face_id: string | null;
      last_at: number | null;
      stage_count: number;
    }>`
      select c.id, c.name, c.size, c.cover_face_id,
             (select max(i.taken_at) from photo_faces f
                join photo_items i on i.id = f.photo_id
               where f.cluster_id = c.id) as last_at,
             (select count(*) from photo_growth_stages s
               where s.person_id = c.id and s.owner_id = ${owner}
                 and s.granularity = 'auto') as stage_count
        from photo_face_clusters c
       where c.size >= 3 or (c.name is not null and c.name <> '')
       order by case when c.name is not null and c.name <> '' then 0 else 1 end, c.size desc
       limit ${limit}
    `.execute(k.db)
  ).rows;
  return rows.map((r) => ({
    id: r.id,
    name: r.name ?? null,
    size: num(r.size),
    coverFaceId: r.cover_face_id ?? null,
    stageCount: num(r.stage_count),
    lastAt: num(r.last_at),
  }));
}

export async function listStages(
  k: KernelApi,
  owner: string,
  personId: string,
  granularity: GrowthGranularity,
  order: string,
  cursor: string | undefined,
  limit: number,
  rebuilt: boolean,
) {
  const desc = order !== 'asc';
  const cur = decodeCursor(cursor);
  let where = sql`owner_id = ${owner} and person_id = ${personId} and granularity = ${granularity} and hidden = 0`;
  if (cur) {
    where = desc
      ? sql`${where} and (start_at < ${cur.takenAt} or (start_at = ${cur.takenAt} and id > ${cur.id}))`
      : sql`${where} and (start_at > ${cur.takenAt} or (start_at = ${cur.takenAt} and id > ${cur.id}))`;
  }
  const rows = (
    await sql<GrowthStageRow>`
      select * from photo_growth_stages
       where ${where}
       order by start_at ${sql.raw(desc ? 'desc' : 'asc')}, id asc
       limit ${limit + 1}
    `.execute(k.db)
  ).rows;
  const page = rows.slice(0, limit);
  const last = page.length > 0 ? page[page.length - 1] : null;
  const sizes = await loadStageSizes(k, page);
  const agg = (
    await sql<{
      stage_count: number;
      city_count: number;
      photo_count: number;
      first_at: number;
      last_at: number;
    }>`
      select count(*) as stage_count,
             count(distinct case when place_key <> 'unknown' then place_key end) as city_count,
             coalesce(sum(photo_count), 0) as photo_count,
             coalesce(min(start_at), 0) as first_at,
             coalesce(max(end_at), 0) as last_at
        from photo_growth_stages
       where owner_id = ${owner} and person_id = ${personId}
         and granularity = ${granularity} and hidden = 0
    `.execute(k.db)
  ).rows[0];
  const person = (
    await sql<{ name: string | null }>`select name from photo_face_clusters where id = ${personId}`.execute(k.db)
  ).rows[0];
  return {
    items: page.map((r) => stageJson(
      r,
      sizes.byId.get(r.cover_asset_id ?? ''),
      sizes.byPath.get(r.secondary_path),
    )),
    nextCursor: rows.length > limit && last ? encodeCursor(num(last.start_at), last.id) : null,
    summary: {
      personId,
      personName: person?.name ?? null,
      stageCount: num(agg?.stage_count),
      cityCount: num(agg?.city_count),
      photoCount: num(agg?.photo_count),
      firstAt: num(agg?.first_at),
      lastAt: num(agg?.last_at),
      granularity,
      rebuilt,
    },
  };
}

export async function loadStage(k: KernelApi, owner: string, stageId: string): Promise<GrowthStageRow | null> {
  const rows = (
    await sql<GrowthStageRow>`select * from photo_growth_stages where id = ${stageId} and owner_id = ${owner}`.execute(k.db)
  ).rows;
  return rows[0] ?? null;
}

/** 二级页：阶段全量照片按 (taken_at, id) 排序键游标分页，绝不一次全量返回。 */
export async function stagePhotos(
  k: KernelApi,
  owner: string,
  stage: GrowthStageRow,
  cursor: string | undefined,
  limit: number,
) {
  const cur = decodeCursor(cursor);
  let where = sql`i.in_trash = 0
     and i.library_id in (select id from photo_libraries where owner_id = ${owner})
     and i.taken_at between ${num(stage.start_at)} and ${num(stage.end_at)}
     and exists (select 1 from photo_faces f
                  where f.photo_id = i.id and f.cluster_id = ${stage.person_id})`;
  if (cur) {
    where = sql`${where} and (i.taken_at > ${cur.takenAt} or (i.taken_at = ${cur.takenAt} and i.id > ${cur.id}))`;
  }
  const rows = (
    await sql<PhotoItemRow>`
      select i.* from photo_items i
       where ${where}
       order by i.taken_at asc, i.id asc
       limit ${limit + 1}
    `.execute(k.db)
  ).rows;
  const page = rows.slice(0, limit);
  const last = page.length > 0 ? page[page.length - 1] : null;
  const total = (
    await sql<{ n: number }>`
      select count(*) as n from photo_items i
       where i.in_trash = 0
         and i.library_id in (select id from photo_libraries where owner_id = ${owner})
         and i.taken_at between ${num(stage.start_at)} and ${num(stage.end_at)}
         and exists (select 1 from photo_faces f
                      where f.photo_id = i.id and f.cluster_id = ${stage.person_id})
    `.execute(k.db)
  ).rows[0];
  return {
    items: page.map(toItem),
    nextCursor: rows.length > limit && last ? encodeCursor(num(last.taken_at), last.id) : null,
    total: num(total?.n),
    stage: stageJson(stage),
  };
}

/** 换封面的候选：候选池里排除当前封面，取前 3 张。 */
export async function stageCandidates(k: KernelApi, stage: GrowthStageRow) {
  const rows = (
    await sql<{ asset_id: string; score: number; reason_json: string }>`
      select a.asset_id, a.score, a.reason_json
        from photo_growth_stage_assets a
       where a.stage_id = ${stage.id} and a.asset_id <> ${stage.cover_asset_id ?? ''}
       order by a.rank asc limit 3
    `.execute(k.db)
  ).rows;
  if (rows.length === 0) return [];
  const ids = rows.map((r) => r.asset_id);
  const paths = (
    await sql<{ id: string; rel_path: string }>`
      select id, rel_path from photo_items
       where id in (${sql.join(ids.map((id) => sql`${id}`), sql`, `)})
    `.execute(k.db)
  ).rows;
  const map = new Map(paths.map((r) => [r.id, String(r.rel_path || '')]));
  return rows
    .map((r) => {
      let grade = '';
      try {
        grade = String((JSON.parse(r.reason_json || '{}') as { grade?: string }).grade || '');
      } catch {
        grade = '';
      }
      return {
        assetId: r.asset_id,
        path: map.get(r.asset_id) ?? '',
        score: num(r.score),
        reason: grade,
      };
    })
    .filter((r) => r.path !== '');
}

/** 人工换封面：写 locked，之后的自动重算一律以人工指定为准。 */
export async function repinStage(
  k: KernelApi,
  owner: string,
  stage: GrowthStageRow,
  assetId: string,
): Promise<GrowthStageRow | null> {
  const rows = (
    await sql<{ rel_path: string }>`
      select i.rel_path from photo_items i
       where i.id = ${assetId} and i.in_trash = 0
         and i.library_id in (select id from photo_libraries where owner_id = ${owner})
         and i.taken_at between ${num(stage.start_at)} and ${num(stage.end_at)}
         and exists (select 1 from photo_faces f
                      where f.photo_id = i.id and f.cluster_id = ${stage.person_id})
    `.execute(k.db)
  ).rows;
  if (rows.length === 0) return null;
  await sql`
    update photo_growth_stages
       set cover_asset_id = ${assetId}, cover_path = ${String(rows[0].rel_path || '')},
           locked = 1, updated_at = ${now()}
     where id = ${stage.id} and owner_id = ${owner}
  `.execute(k.db);
  const updated = (
    await sql<GrowthStageRow>`
      select * from photo_growth_stages where id = ${stage.id} and owner_id = ${owner}
    `.execute(k.db)
  ).rows;
  return updated[0] ?? null;
}
