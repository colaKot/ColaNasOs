import { Type } from '@sinclair/typebox';
import crypto from 'node:crypto';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { describePlace } from './geo/place-label';
import type { FastifyRequest } from 'fastify';

/**
 * 相册「记忆」四件套：一日一帧 / 人生章节（按年成书）/ 票夹 / 年度记录。
 *
 * 共同原则：
 *   - 全部可解释、离线可算，不调 LLM；
 *   - 标签来自已有 AI 结果（场景 / 活动 / 人物），缺失时降级为「只有时间与地点」；
 *   - 票夹用 OCR 文本 + 正则，不引入检测模型；
 *   - 生成的记忆是**候选**，用户确认后才落库（见 photo_memories）。
 */
const TAG = ['photo'];

const DayFrame = Type.Object(
  {
    date: Type.String({ description: 'YYYY-MM-DD（本地时区）' }),
    photoId: Type.String(),
    path: Type.String(),
    takenAt: Type.Integer(),
    score: Type.Number(),
    caption: Type.String(),
    scenes: Type.Array(Type.String()),
    activities: Type.Array(Type.String()),
    people: Type.Array(Type.String()),
    dayPhotoCount: Type.Integer(),
  },
  { $id: 'PhotoDayFrame' },
);

const DayFrameList = Type.Object(
  { items: Type.Array(Type.Ref(DayFrame)) },
  { $id: 'PhotoDayFrameList' },
);

const DayFramesQuery = Type.Object(
  {
    days: Type.Optional(Type.Integer({ minimum: 1, maximum: 365, default: 30 })),
    locale: Type.Optional(Type.String()),
  },
  { $id: 'PhotoDayFramesQuery' },
);

const PickRef = Type.Object(
  { id: Type.String(), path: Type.String(), takenAt: Type.Integer() },
  { $id: 'PhotoMemoryPick' },
);

const ChapterPage = Type.Object(
  {
    date: Type.String(),
    photoCount: Type.Integer(),
    cover: Type.Ref(PickRef),
    picks: Type.Array(Type.Ref(PickRef)),
    place: Type.String(),
    scenes: Type.Array(Type.String()),
    activities: Type.Array(Type.String()),
    people: Type.Array(Type.String()),
    note: Type.String({ description: '影像日记：由地点 + 标签拼句，可编辑' }),
  },
  { $id: 'PhotoChapterPage' },
);

const ChapterBook = Type.Object(
  {
    year: Type.Integer(),
    title: Type.String(),
    totalPhotos: Type.Integer(),
    days: Type.Array(Type.Ref(ChapterPage)),
  },
  { $id: 'PhotoChapterBook' },
);

const ChapterQuery = Type.Object(
  {
    year: Type.Optional(Type.Integer({ minimum: 1900, maximum: 2200 })),
    locale: Type.Optional(Type.String()),
    limitDays: Type.Optional(Type.Integer({ minimum: 1, maximum: 366, default: 366 })),
  },
  { $id: 'PhotoChapterQuery' },
);

const Ticket = Type.Object(
  {
    kind: Type.String({ description: 'train / flight / ticket' }),
    kindLabel: Type.String(),
    photoId: Type.String(),
    path: Type.String(),
    takenAt: Type.Integer(),
    date: Type.String(),
    time: Type.String(),
    fromStation: Type.String(),
    toStation: Type.String(),
    code: Type.String(),
    evidence: Type.Array(Type.String()),
  },
  { $id: 'PhotoTicket' },
);

const Trip = Type.Object(
  {
    index: Type.Integer(),
    start: Type.String(),
    end: Type.String(),
    ticketCount: Type.Integer(),
    kinds: Type.Array(Type.String()),
    title: Type.String(),
  },
  { $id: 'PhotoTrip' },
);

const TicketResponse = Type.Object(
  {
    tickets: Type.Array(Type.Ref(Ticket)),
    trips: Type.Array(Type.Ref(Trip)),
    degraded: Type.Boolean(),
    reason: Type.String(),
    scanned: Type.Integer(),
  },
  { $id: 'PhotoTicketResponse' },
);

const TicketsQuery = Type.Object(
  {
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500, default: 200 })),
  },
  { $id: 'PhotoTicketsQuery' },
);

const MonthCount = Type.Object({ month: Type.Integer(), count: Type.Integer() }, { $id: 'PhotoMonthCount' });

const PlaceYear = Type.Object(
  { year: Type.Integer(), count: Type.Integer() },
  { $id: 'PhotoPlaceYear' },
);

const PlaceCount = Type.Object(
  {
    geohash5: Type.String(),
    name: Type.String(),
    count: Type.Integer(),
    years: Type.Array(Type.Ref(PlaceYear)),
  },
  { $id: 'PhotoPlaceCount' },
);

const LabelCount = Type.Object({ label: Type.String(), count: Type.Integer() }, { $id: 'PhotoLabelCount' });

const YearReport = Type.Object(
  {
    year: Type.Integer(),
    totalPhotos: Type.Integer(),
    months: Type.Array(Type.Ref(MonthCount)),
    places: Type.Array(Type.Ref(PlaceCount)),
    placeCount: Type.Integer({ description: '去重 geohash5 格子数（≈ 去过多少地方）' }),
    scenes: Type.Array(Type.Ref(LabelCount)),
    activities: Type.Array(Type.Ref(LabelCount)),
    people: Type.Array(Type.Ref(LabelCount)),
    cameras: Type.Array(Type.Ref(LabelCount)),
    busiestDays: Type.Array(Type.Ref(LabelCount)),
    earliest: Type.Union([Type.Integer(), Type.Null()]),
    latest: Type.Union([Type.Integer(), Type.Null()]),
  },
  { $id: 'PhotoYearReport' },
);

const YearQuery = Type.Object(
  {
    year: Type.Optional(Type.Integer({ minimum: 1900, maximum: 2200 })),
    locale: Type.Optional(Type.String()),
  },
  { $id: 'PhotoYearReportQuery' },
);

const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'PhotoMemoryError' },
);

export const PHOTO_MEMORY_SCHEMAS = [
  DayFrame,
  DayFrameList,
  DayFramesQuery,
  PickRef,
  ChapterPage,
  ChapterBook,
  ChapterQuery,
  Ticket,
  Trip,
  TicketResponse,
  TicketsQuery,
  MonthCount,
  PlaceYear,
  PlaceCount,
  LabelCount,
  YearReport,
  YearQuery,
  ErrorResponse,
];

const ref = (id: string) => ({ $ref: `${id}#` });

interface PhotoRow {
  id: string;
  rel_path: string;
  taken_at: number;
  geohash5: string | null;
  latitude: number | null;
  longitude: number | null;
  camera: string | null;
}

function pad2(v: number): string {
  return String(v).padStart(2, '0');
}

/** 本地时区的 YYYY-MM-DD（照片的「那天」按用户所在时区算） */
function dayOf(epochSec: number): string {
  const d = new Date(epochSec * 1000);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function yearRange(year: number): { from: number; to: number } {
  return {
    from: Math.floor(new Date(year, 0, 1, 0, 0, 0).getTime() / 1000),
    to: Math.floor(new Date(year + 1, 0, 1, 0, 0, 0).getTime() / 1000),
  };
}

async function labelsOf(
  db: any,
  ids: string[],
): Promise<{
  scenes: Map<string, string[]>;
  activities: Map<string, string[]>;
  people: Map<string, string[]>;
}> {
  const scenes = new Map<string, string[]>();
  const activities = new Map<string, string[]>();
  const people = new Map<string, string[]>();
  if (ids.length === 0) return { scenes, activities, people };

  const chunks: string[][] = [];
  for (let i = 0; i < ids.length; i += 500) chunks.push(ids.slice(i, i + 500));

  for (const chunk of chunks) {
    const list = sql.join(
      chunk.map((id) => sql`${id}`),
      sql`, `,
    );
    const sceneRows = (
      await sql<{ photo_id: string; label: string }>`
        select photo_id, label from photo_scenes where photo_id in (${list})
      `.execute(db)
    ).rows;
    for (const r of sceneRows) {
      if (!scenes.has(r.photo_id)) scenes.set(r.photo_id, []);
      scenes.get(r.photo_id)!.push(r.label);
    }

    const activityRows = (
      await sql<{ photo_id: string; label: string }>`
        select photo_id, label from photo_activities
         where photo_id in (${list})
         order by score desc
      `.execute(db)
    ).rows;
    for (const r of activityRows) {
      if (!activities.has(r.photo_id)) activities.set(r.photo_id, []);
      const arr = activities.get(r.photo_id)!;
      if (arr.length < 4) arr.push(r.label);
    }

    const peopleRows = (
      await sql<{ photo_id: string; name: string }>`
        select distinct f.photo_id, c.name
          from photo_faces f
          join photo_face_clusters c on c.id = f.cluster_id
         where f.photo_id in (${list}) and c.name is not null and c.name <> ''
         limit 2000
      `.execute(db)
    ).rows;
    for (const r of peopleRows) {
      if (!people.has(r.photo_id)) people.set(r.photo_id, []);
      const arr = people.get(r.photo_id)!;
      if (!arr.includes(r.name)) arr.push(r.name);
    }
  }

  return { scenes, activities, people };
}

/** 一天里挑「最值得看」的一张：场景 > 活动 > 人物 > 非截图；当天张数也加分 */
function scoreOf(
  r: PhotoRow,
  scenes: string[],
  activities: string[],
  people: string[],
  dayCount: number,
): number {
  const filename = (r.rel_path.split('/').pop() || '').toLowerCase();
  const isDoc = /screenshot|截图|scan|img_20\d{6}_\d{6}\.png/.test(filename);
  let score = 0;
  score += scenes.length > 0 ? 3 : 0;
  score += activities.length > 0 ? 2 : 0;
  score += people.length > 0 ? 2 + Math.min(2, people.length) : 0;
  if (isDoc) score -= 4;
  score += Math.min(3, dayCount / 40);
  // 稳定的日内定序：同一天多次请求结果一致
  const h = parseInt(r.id.slice(-4), 16);
  score += (Number.isFinite(h) ? h % 100 : 0) / 1000;
  return Number(score.toFixed(3));
}

function captionOf(scenes: string[], activities: string[], people: string[]): string {
  const parts: string[] = [];
  if (scenes.length) parts.push(scenes[0]);
  if (activities.length) parts.push(activities[0]);
  if (parts.length === 0 && people.length === 0) return '';
  return `${parts.join(' · ')}${people.length ? `，与 ${people.join('、')}` : ''}`;
}

async function photosBetween(
  db: any,
  from: number,
  to: number,
  limit: number,
  uid = '',
): Promise<PhotoRow[]> {
  return (
    await sql<PhotoRow>`
      select id, rel_path, taken_at, geohash5, latitude, longitude, camera
        from photo_items
       where in_trash = 0 and taken_at >= ${from} and taken_at < ${to}
         and (${uid} = '' or library_id in (select id from photo_libraries where owner_id = ${uid}))
       order by taken_at asc
       limit ${limit}
    `.execute(db)
  ).rows;
}

export async function registerPhotoMemories(app: any, k: KernelApi): Promise<void> {
  for (const schema of PHOTO_MEMORY_SCHEMAS) app.addSchema(schema);

  // ---------------------------------------------------------------- 一日一帧

  app.get(
    '/api/v1/photo/memories/day-frames',
    secured('photo:read', {
      schema: {
        operationId: 'photoDayFrames',
        tags: TAG,
        summary: '一日一帧：每天挑一张代表作（配当日标签与地点）',
        querystring: ref('PhotoDayFramesQuery'),
        response: { 200: ref('PhotoDayFrameList') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { days?: number };
      const days = Math.max(1, Math.min(Number(q.days) || 30, 365));
      const now = Math.floor(Date.now() / 1000);
      const rows = await photosBetween(k.db, now - days * 86400, now + 86400, 6000, String(req.user?.sub || ''));
      if (rows.length === 0) return { items: [] };

      const labels = await labelsOf(
        k.db,
        rows.map((r) => r.id),
      );

      const byDay = new Map<string, PhotoRow[]>();
      for (const r of rows) {
        const day = dayOf(Number(r.taken_at));
        if (!byDay.has(day)) byDay.set(day, []);
        byDay.get(day)!.push(r);
      }

      const items = [];
      for (const [day, list] of byDay) {
        let best: { row: PhotoRow; score: number } | null = null;
        for (const r of list) {
          const scenes = labels.scenes.get(r.id) || [];
          const acts = labels.activities.get(r.id) || [];
          const people = labels.people.get(r.id) || [];
          const score = scoreOf(r, scenes, acts, people, list.length);
          if (!best || score > best.score) best = { row: r, score };
        }
        if (!best) continue;
        const scenes = labels.scenes.get(best.row.id) || [];
        const acts = labels.activities.get(best.row.id) || [];
        const people = labels.people.get(best.row.id) || [];
        items.push({
          date: day,
          photoId: best.row.id,
          path: best.row.rel_path,
          takenAt: Number(best.row.taken_at),
          score: best.score,
          caption: captionOf(scenes, acts, people),
          scenes,
          activities: acts,
          people,
          dayPhotoCount: list.length,
        });
      }
      items.sort((a, b) => (a.date < b.date ? 1 : -1));
      return { items };
    },
  );

  // ---------------------------------------------------------------- 人生章节（按年成书）

  app.get(
    '/api/v1/photo/memories/chapters',
    secured('photo:read', {
      schema: {
        operationId: 'photoChapterBook',
        tags: TAG,
        summary: '人生章节：按年成书，一页 = 一天（左页大图 + 精选，右页影像日记）',
        querystring: ref('PhotoChapterQuery'),
        response: { 200: ref('PhotoChapterBook') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { year?: number; locale?: string; limitDays?: number };
      const year = Number(q.year) || new Date().getFullYear();
      const limitDays = Math.max(1, Math.min(Number(q.limitDays) || 366, 366));
      const { from, to } = yearRange(year);
      const rows = await photosBetween(k.db, from, to, 20000, String(req.user?.sub || ''));

      const labels = await labelsOf(
        k.db,
        rows.map((r) => r.id),
      );

      const byDay = new Map<string, PhotoRow[]>();
      for (const r of rows) {
        const day = dayOf(Number(r.taken_at));
        if (!byDay.has(day)) byDay.set(day, []);
        byDay.get(day)!.push(r);
      }

      const days = [];
      for (const [day, list] of [...byDay.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
        if (days.length >= limitDays) break;

        const scored = list
          .map((r) => ({
            row: r,
            score: scoreOf(
              r,
              labels.scenes.get(r.id) || [],
              labels.activities.get(r.id) || [],
              labels.people.get(r.id) || [],
              list.length,
            ),
          }))
          .sort((a, b) => b.score - a.score);

        // 封面优先挑「有人脸」的那张：记忆卡片是给人看的，一张有人的照片
        // 比构图最好的风景更像「回忆」。AI 没跑（无 people 数据）时自然退回最高分。
        const cover = scored.find((s) => (labels.people.get(s.row.id) || []).length > 0)?.row
          ?? scored[0].row;
        const picks = scored.slice(0, 7).map((s) => ({
          id: s.row.id,
          path: s.row.rel_path,
          takenAt: Number(s.row.taken_at),
        }));

        // 地点：按当天出现最多的 geohash5 取最近地名（最多试 4 个格）
        const cellCount = new Map<string, number>();
        for (const r of list) {
          const gh = String(r.geohash5 || '').trim();
          if (!gh) continue;
          cellCount.set(gh, (cellCount.get(gh) || 0) + 1);
        }
        const topCells = [...cellCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 4);
        let place = '';
        for (const [cell] of topCells) {
          const sample = list.find((r) => String(r.geohash5 || '') === cell);
          if (!sample) continue;
          place = describePlace(
            String(sample.geohash5 || ''),
            sample.latitude == null ? null : Number(sample.latitude),
            sample.longitude == null ? null : Number(sample.longitude),
            q.locale,
          );
          if (place) break;
        }

        const sceneCount = new Map<string, number>();
        const actCount = new Map<string, number>();
        const peopleSet = new Set<string>();
        for (const r of list) {
          for (const s of labels.scenes.get(r.id) || []) sceneCount.set(s, (sceneCount.get(s) || 0) + 1);
          for (const a of labels.activities.get(r.id) || []) actCount.set(a, (actCount.get(a) || 0) + 1);
          for (const p of labels.people.get(r.id) || []) peopleSet.add(p);
        }
        const top = (m: Map<string, number>, n: number) =>
          [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([label]) => label);

        const scenes = top(sceneCount, 3);
        const activities = top(actCount, 3);
        const people = [...peopleSet].slice(0, 6);

        const noteParts = [
          place ? `在${place}` : '',
          scenes[0] ? `看到${scenes[0]}` : '',
          activities[0] ? `在${activities[0]}` : '',
          people.length ? `同行：${people.join('、')}` : '',
        ].filter(Boolean);

        days.push({
          date: day,
          photoCount: list.length,
          cover: { id: cover.id, path: cover.rel_path, takenAt: Number(cover.taken_at) },
          picks,
          place,
          scenes,
          activities,
          people,
          note: noteParts.join('，') || '这一天的影像还没有标签',
        });
      }

      return {
        year,
        title: `${year} · 影像日记`,
        totalPhotos: rows.length,
        days,
      };
    },
  );

  // ---------------------------------------------------------------- 票夹

  app.get(
    '/api/v1/photo/memories/tickets',
    secured('photo:read', {
      schema: {
        operationId: 'photoTickets',
        tags: TAG,
        summary: '票夹：识别火车票 / 机票 / 门票，按行程归组',
        querystring: ref('PhotoTicketsQuery'),
        response: { 200: ref('PhotoTicketResponse'), 503: ref('PhotoMemoryError') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { limit?: number };
      const limit = Math.max(1, Math.min(Number(q.limit) || 200, 500));

      let rows: Array<{ id: string; rel_path: string; taken_at: number; ocr: string | null }>;
      let degraded = false;
      let reason = '';
      try {
        rows = (
          await sql<{
            id: string;
            rel_path: string;
            taken_at: number;
            ocr: string | null;
          }>`
            select i.id, i.rel_path, i.taken_at, o.text as ocr
              from photo_items i
              left join photo_ocr o on o.photo_id = i.id
             where i.in_trash = 0
             order by i.taken_at desc
             limit 4000
          `.execute(k.db)
        ).rows;
        if (rows.every((r) => !r.ocr)) {
          degraded = true;
          reason = '尚未运行 OCR（票夹需要先做文字识别）';
        }
      } catch (err) {
        degraded = true;
        reason = String((err as Error)?.message || err).slice(0, 200);
        rows = [];
      }

      const RULES = [
        {
          key: 'train',
          label: '火车票',
          strong: ['车次', '检票', '席别', '二等座', '一等座', '硬座', '硬卧', '软卧'],
          weak: ['票价', '退票', '改签', '取票', '成人票', '铁路'],
        },
        {
          key: 'flight',
          label: '机票',
          strong: ['登机口', '登机牌', '值机', '经济舱', '公务舱', '航班'],
          weak: ['舱位', '机场', '起飞', '降落', '航空'],
        },
        {
          key: 'ticket',
          label: '门票 / 票据',
          strong: ['门票', '入场券', '影票', '取票码', '单程票', '索道票'],
          weak: [],
        },
      ];
      const trainNo = /(?:^|[^0-9A-Za-z])([GDCKTZ][1-9]\d{0,3})(?!\d)/;
      const flightNo = /((?:CZ|CA|MU|MF|HU|ZH|SC|FM|HO|3U)[1-9]\d{2,3})(?!\d)/;
      const dateRe = /(20\d{2})[-年/.]?(\d{1,2})[-月/.]?(\d{1,2})/;
      const timeRe = /(?:^|\D)(\d{1,2})[:：](\d{1,2})(?!\d)/;
      const stationRe = /([\u4e00-\u9fa5]{2,4})(站|机场)/g;
      const NOISE = /[车线铁网接改经客观供安全中到本该台]/;
      const norm = (s: string): string => String(s || '').replace(/[\s\u3000]+/g, '');

      const cleanStation = (raw: string, suffix: string): string => {
        let core = raw;
        if (core.length >= 4 && core.length % 2 === 0) {
          const half = core.length / 2;
          if (core.slice(0, half) === core.slice(half)) core = core.slice(half);
        }
        if (core.length < 2 || core.length > 3) return '';
        if (NOISE.test(core)) return '';
        return core + suffix;
      };

      const tickets = [];
      for (const r of rows) {
        const text = norm(r.ocr || '');
        if (text.length < 4) continue;

        let matched: { key: string; label: string; hits: string[]; code: string } | null = null;
        for (const rule of RULES) {
          const strong = rule.strong.filter((w) => text.includes(w));
          const weak = rule.weak.filter((w) => text.includes(w));
          if (strong.length === 0 && weak.length < 2) continue;
          const m =
            rule.key === 'flight'
              ? flightNo.exec(text)
              : rule.key === 'train'
                ? trainNo.exec(text)
                : null;
          matched = {
            key: rule.key,
            label: rule.label,
            hits: [...strong, ...weak],
            code: m ? m[1] : '',
          };
          break;
        }
        if (!matched) continue;

        const wantStation =
          matched.key === 'flight' ||
          text.includes('车次') ||
          text.includes('出发站') ||
          text.includes('到达站') ||
          text.includes('检票');
        const stations: string[] = [];
        if (wantStation) {
          stationRe.lastIndex = 0;
          let sm: RegExpExecArray | null;
          while ((sm = stationRe.exec(text)) !== null) {
            const name = cleanStation(sm[1], sm[2]);
            if (!name || stations.includes(name)) continue;
            stations.push(name);
            if (stations.length >= 2) break;
          }
        }

        const dm = dateRe.exec(text);
        const tm = timeRe.exec(text);
        let hhmm = '';
        if (tm) {
          const h = Number(tm[1]);
          const mi = Number(tm[2]);
          if (h >= 0 && h <= 23 && mi >= 0 && mi <= 59) hhmm = `${pad2(h)}:${pad2(mi)}`;
        }

        tickets.push({
          kind: matched.key,
          kindLabel: matched.label,
          photoId: r.id,
          path: r.rel_path,
          takenAt: Number(r.taken_at),
          date: dm ? `${dm[1]}-${pad2(Number(dm[2]))}-${pad2(Number(dm[3]))}` : dayOf(Number(r.taken_at)),
          time: hhmm,
          fromStation: stations[0] || '',
          toStation: stations[1] || '',
          code: matched.code,
          evidence: matched.hits.slice(0, 8),
        });
        if (tickets.length >= limit) break;
      }

      // 行程聚类：按拍摄时间排序，间隔 > 7 天切段
      const sorted = tickets.slice().sort((a, b) => a.takenAt - b.takenAt);
      const trips = [];
      let cur: { start: number; end: number; tickets: typeof sorted } | null = null;
      for (const t of sorted) {
        if (!cur) {
          cur = { start: t.takenAt, end: t.takenAt, tickets: [t] };
          continue;
        }
        if ((t.takenAt - cur.end) / 86400 > 7) {
          trips.push(cur);
          cur = { start: t.takenAt, end: t.takenAt, tickets: [t] };
        } else {
          cur.end = t.takenAt;
          cur.tickets.push(t);
        }
      }
      if (cur) trips.push(cur);

      return {
        tickets,
        trips: trips.map((t, i) => {
          const kinds = [...new Set(t.tickets.map((x) => x.kind))];
          const from = t.tickets.map((x) => x.fromStation).find(Boolean) || '';
          const to = [...t.tickets].reverse().map((x) => x.toStation).find(Boolean) || '';
          return {
            index: i + 1,
            start: dayOf(t.start),
            end: dayOf(t.end),
            ticketCount: t.tickets.length,
            kinds,
            title: from && to ? `${from} → ${to}` : `${dayOf(t.start)} 的行程`,
          };
        }),
        degraded,
        reason,
        scanned: rows.length,
      };
    },
  );

  // ---------------------------------------------------------------- 年度记录

  app.get(
    '/api/v1/photo/memories/year-report',
    secured('photo:read', {
      schema: {
        operationId: 'photoYearReport',
        tags: TAG,
        summary: '年度记录：张数 / 地点 / 活跃人物 / 常用场景，地点可跨年对照',
        querystring: ref('PhotoYearReportQuery'),
        response: { 200: ref('PhotoYearReport') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { year?: number; locale?: string };
      const year = Number(q.year) || new Date().getFullYear();
      const { from, to } = yearRange(year);

      const rows = await photosBetween(k.db, from, to, 50000, String(req.user?.sub || ''));
      const ids = rows.map((r) => r.id);
      const labels = await labelsOf(k.db, ids);

      const months = Array.from({ length: 12 }, (_, i) => ({ month: i + 1, count: 0 }));
      const dayCount = new Map<string, number>();
      const cellCount = new Map<string, number>();
      const cameraCount = new Map<string, number>();
      const sceneCount = new Map<string, number>();
      const actCount = new Map<string, number>();
      const peopleCount = new Map<string, number>();

      for (const r of rows) {
        const d = new Date(Number(r.taken_at) * 1000);
        months[d.getMonth()].count += 1;
        const day = dayOf(Number(r.taken_at));
        dayCount.set(day, (dayCount.get(day) || 0) + 1);
        const cell = String(r.geohash5 || '').trim();
        if (cell) cellCount.set(cell, (cellCount.get(cell) || 0) + 1);
        const cam = String(r.camera || '').trim();
        if (cam) cameraCount.set(cam, (cameraCount.get(cam) || 0) + 1);
        for (const s of labels.scenes.get(r.id) || []) sceneCount.set(s, (sceneCount.get(s) || 0) + 1);
        for (const a of labels.activities.get(r.id) || []) actCount.set(a, (actCount.get(a) || 0) + 1);
        for (const p of labels.people.get(r.id) || []) peopleCount.set(p, (peopleCount.get(p) || 0) + 1);
      }

      const topLabels = (m: Map<string, number>, n: number) =>
        [...m.entries()]
          .sort((a, b) => b[1] - a[1])
          .slice(0, n)
          .map(([label, count]) => ({ label, count }));

      // 同一地点跨年份对照：只对当年 top20 的格子查其它年份
      const topCells = [...cellCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20);
      const places = [];
      for (const [cell, count] of topCells) {
        const sample = rows.find((r) => String(r.geohash5 || '') === cell);
        const name = sample
          ? describePlace(
              cell,
              sample.latitude == null ? null : Number(sample.latitude),
              sample.longitude == null ? null : Number(sample.longitude),
              q.locale,
            )
          : '';
        const yearRows = (
          await sql<{ y: number; n: number }>`
            select cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) as y,
                   count(*) as n
              from photo_items
             where in_trash = 0 and geohash5 = ${cell}
             group by y order by y asc
          `.execute(k.db)
        ).rows;
        places.push({
          geohash5: cell,
          name,
          count,
          years: yearRows.map((r) => ({ year: Number(r.y), count: Number(r.n) })),
        });
      }

      return {
        year,
        totalPhotos: rows.length,
        months,
        places,
        placeCount: cellCount.size,
        scenes: topLabels(sceneCount, 12),
        activities: topLabels(actCount, 12),
        people: topLabels(peopleCount, 12),
        cameras: topLabels(cameraCount, 8),
        busiestDays: topLabels(dayCount, 5).map((d) => ({ label: d.label, count: d.count })),
        earliest: rows.length ? Number(rows[0].taken_at) : null,
        latest: rows.length ? Number(rows[rows.length - 1].taken_at) : null,
      };
    },
  );

  // ---------------------------------------------------------------- 记忆（候选 / 已确认 / 已忽略）

  app.get(
    '/api/v1/photo/memories',
    secured('photo:read', {
      schema: {
        operationId: 'photoMemories',
        tags: TAG,
        summary: '记忆：候选 / 已确认 / 已忽略 + 年度章节',
        querystring: ref('PhotoMemoryQuery'),
        response: { 200: ref('PhotoMemoryList') },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String(req.user?.sub || '');
      const q = (req.query || {}) as { days?: number; minPhotos?: number; limit?: number; locale?: string };
      const days = Math.max(1, Math.min(Number(q.days) || 3650, 3650));
      const minPhotos = Math.max(1, Math.min(Number(q.minPhotos) || 12, 100));
      const limit = Math.max(1, Math.min(Number(q.limit) || 40, 100));
      const now = Math.floor(Date.now() / 1000);
      const rows = await photosBetween(k.db, now - days * 86400, now + 86400, 20000, uid);
      const labels = await labelsOf(
        k.db,
        rows.map((r) => r.id),
      );

      const marked = new Map<string, { status: string; note: string; updated_at: number }>();
      const marks = (
        await sql<{ date: string; status: string; note: string; updated_at: number }>`
          select day as date, status, note, updated_at from photo_memory_marks where owner_id = ${uid}
        `.execute(k.db)
      ).rows;
      for (const m of marks) marked.set(m.date, m);

      const byDay = new Map<string, PhotoRow[]>();
      for (const r of rows) {
        const day = dayOf(Number(r.taken_at));
        if (!byDay.has(day)) byDay.set(day, []);
        byDay.get(day)!.push(r);
      }

      const candidates: any[] = [];
      const memories: any[] = [];
      const ignored: any[] = [];
      for (const [day, list] of byDay) {
        const base = buildMemoryBase(day, list, labels, q.locale);
        const mark = marked.get(day);
        if (mark) {
          const item = {
            ...base,
            note: mark.note || base.note,
            status: mark.status,
            updatedAt: Number(mark.updated_at) || 0,
          };
          (mark.status === 'ignored' ? ignored : memories).push(item);
        } else if (
          list.length >= minPhotos &&
          (base.place || base.scenes.length > 0 || base.people.length > 0)
        ) {
          candidates.push({ ...base, status: 'candidate', updatedAt: 0 });
        }
      }

      // 已确认/忽略的日期即使当天照片已不在索引里，也保留在对应列表（照片可能被移入回收站）
      for (const [day, mark] of marked) {
        if (byDay.has(day)) continue;
        const item = {
          date: day,
          photoCount: 0,
          coverPath: '',
          place: '',
          scenes: <string[]>[],
          activities: <string[]>[],
          people: <string[]>[],
          note: mark.note || '',
          status: mark.status,
          updatedAt: Number(mark.updated_at) || 0,
        };
        (mark.status === 'ignored' ? ignored : memories).push(item);
      }

      const byYear = new Map<number, PhotoRow[]>();
      for (const r of rows) {
        const year = new Date(Number(r.taken_at) * 1000).getFullYear();
        if (!byYear.has(year)) byYear.set(year, []);
        byYear.get(year)!.push(r);
      }
      const chapters = [...byYear.entries()]
        .map(([year, list]) => ({
          year,
          coverPath: list[list.length - 1].rel_path,
          photoCount: list.length,
          start: dayOf(Number(list[0].taken_at)),
          end: dayOf(Number(list[list.length - 1].taken_at)),
        }))
        .sort((a, b) => b.year - a.year);

      const desc = (a: any, b: any) => (a.date < b.date ? 1 : -1);
      return {
        candidates: candidates.sort(desc).slice(0, limit),
        memories: memories.sort(desc).slice(0, limit),
        ignored: ignored.sort(desc).slice(0, limit),
        chapters,
      };
    },
  );

  const upsertMemory = async (uid: string, date: string, status: string, note: string) => {
    const ts = Math.floor(Date.now() / 1000);
    await sql`
      insert into photo_memory_marks (id, owner_id, day, status, note, created_at, updated_at)
      values (${crypto.randomUUID()}, ${uid}, ${date}, ${status}, ${note}, ${ts}, ${ts})
      on conflict(owner_id, day) do update set
        status = ${status}, note = ${note}, updated_at = ${ts}
    `.execute(k.db);
  };

  app.post(
    '/api/v1/photo/memories/save',
    secured('photo:write', {
      schema: {
        operationId: 'photoMemorySave',
        tags: TAG,
        summary: '确认一条记忆（可带备注）',
        body: ref('PhotoMemorySaveBody'),
        response: { 200: ref('PhotoAiOpResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { date: string; note?: string };
      await upsertMemory(
        String(req.user?.sub || ''),
        String(body.date),
        'saved',
        String(body.note || '').slice(0, 500),
      );
      return { ok: true, count: 1 };
    },
  );

  app.post(
    '/api/v1/photo/memories/ignore',
    secured('photo:write', {
      schema: {
        operationId: 'photoMemoryIgnore',
        tags: TAG,
        summary: '忽略一条记忆候选',
        body: ref('PhotoMemoryTargetBody'),
        response: { 200: ref('PhotoAiOpResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { date: string };
      await upsertMemory(String(req.user?.sub || ''), String(body.date), 'ignored', '');
      return { ok: true, count: 1 };
    },
  );

  app.post(
    '/api/v1/photo/memories/restore',
    secured('photo:write', {
      schema: {
        operationId: 'photoMemoryRestore',
        tags: TAG,
        summary: '把忽略的记忆恢复为已确认',
        body: ref('PhotoMemoryTargetBody'),
        response: { 200: ref('PhotoAiOpResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { date: string };
      await sql`
        update photo_memory_marks set status = 'saved', updated_at = ${Math.floor(Date.now() / 1000)}
         where owner_id = ${String(req.user?.sub || '')} and day = ${String(body.date)}
      `.execute(k.db);
      return { ok: true, count: 1 };
    },
  );

  app.post(
    '/api/v1/photo/memories/remove',
    secured('photo:write', {
      schema: {
        operationId: 'photoMemoryRemove',
        tags: TAG,
        summary: '删除一条已确认记忆',
        body: ref('PhotoMemoryTargetBody'),
        response: { 200: ref('PhotoAiOpResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { date: string };
      await sql`
        delete from photo_memory_marks
         where owner_id = ${String(req.user?.sub || '')} and day = ${String(body.date)}
      `.execute(k.db);
      return { ok: true, count: 1 };
    },
  );
}

/** 某一天的记忆内容（与人生章节同一套打分与标签口径） */
function buildMemoryBase(
  day: string,
  list: PhotoRow[],
  labels: {
    scenes: Map<string, string[]>;
    activities: Map<string, string[]>;
    people: Map<string, string[]>;
  },
  locale?: string,
) {
  const scored = list
    .map((r) => ({
      row: r,
      score: scoreOf(
        r,
        labels.scenes.get(r.id) || [],
        labels.activities.get(r.id) || [],
        labels.people.get(r.id) || [],
        list.length,
      ),
    }))
    .sort((a, b) => b.score - a.score);
  // 同列表页：有人脸的优先做封面
  const cover = scored.find((s) => (labels.people.get(s.row.id) || []).length > 0)?.row
    ?? scored[0].row;

  const cellCount = new Map<string, number>();
  for (const r of list) {
    const gh = String(r.geohash5 || '').trim();
    if (gh) cellCount.set(gh, (cellCount.get(gh) || 0) + 1);
  }
  let place = '';
  for (const [cell] of [...cellCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 4)) {
    const sample = list.find((r) => String(r.geohash5 || '') === cell);
    if (!sample) continue;
    place = describePlace(
      cell,
      sample.latitude == null ? null : Number(sample.latitude),
      sample.longitude == null ? null : Number(sample.longitude),
      locale,
    );
    if (place) break;
  }

  const sceneCount = new Map<string, number>();
  const actCount = new Map<string, number>();
  const peopleSet = new Set<string>();
  for (const r of list) {
    for (const s of labels.scenes.get(r.id) || []) sceneCount.set(s, (sceneCount.get(s) || 0) + 1);
    for (const a of labels.activities.get(r.id) || []) actCount.set(a, (actCount.get(a) || 0) + 1);
    for (const p of labels.people.get(r.id) || []) peopleSet.add(p);
  }
  const top = (m: Map<string, number>, n: number) =>
    [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([label]) => label);

  const scenes = top(sceneCount, 3);
  const activities = top(actCount, 3);
  const people = [...peopleSet].slice(0, 6);
  const noteParts = [
    place ? `在${place}` : '',
    scenes[0] ? `看到${scenes[0]}` : '',
    activities[0] ? `在${activities[0]}` : '',
    people.length ? `同行：${people.join('、')}` : '',
  ].filter(Boolean);

  return {
    date: day,
    photoCount: list.length,
    coverPath: cover.rel_path,
    place,
    scenes,
    activities,
    people,
    note: noteParts.join('，') || '这一天的影像还没有标签',
  };
}