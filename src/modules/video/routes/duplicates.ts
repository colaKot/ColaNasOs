import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../../kernel/route';
import { TAG } from '../util';
import { filesRoot, httpError, resolveAnyPath } from '../../files/fs-root';
import { TRASH_DIR, movePath } from '../../files/ops';
import { normAbs, sidecarsOf, type ArtRefRow } from '../sidecars';
import { offlineCond, offlineSmbPrefixes } from '../sources';
import { parseActorNames } from '../jp-links';
import { actorKey } from '../jp-actor';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/**
 * 重复视频。
 *
 * 判据从「一把钥匙」升级到**四把硬钥匙 + 并查集**：
 *   ① `douban:<id>`  —— NFO 里的豆瓣 id
 *   ② `imdb:<tt…>`   —— IMDB id
 *   ③ `code:<番号>`  —— 文件名里的番号
 *   ④ `title:<归一化标题>[@年份]` —— 兜底
 *
 * 为什么必须用并查集：同一部片可能有 A、B、C 三份，A 命中 imdb、B 命中标题、
 * C 谁都不命中但和 B 同名 —— 单键分组只能捞到一部分，并查集能把它们连成一组。
 *
 * 三条**反误报**守卫（都是实际踩过的坑）：
 *   - 标题里必须至少有一个字母 / 汉字 / 假名。录屏文件被写坏的标题
 *     （`2024-02-24 17.51.25` → `-02-24 17 51`）是纯数字，会把一整批录屏并成一部片；
 *   - 标题长度 < 4 不参与（「上」「前編」「无码」做键会到处误并）；
 *   - 年份不同不并（同名不同年 = 续集）。年份为 0 的只在「只有一种年份」时跟着并，
 *     否则挂到最早那一年 —— 绝不能挂到每一年，否则会通过「无年份」这条边把 2020 和 2022 连起来。
 *
 * 性能：先只捞 7 个轻列在内存里分组，命中的 id 再回表补封面 / 大小 / 时长。
 * 不做 limit 截断（旧实现 `limit 20000` 会静默漏掉后面的片子）。
 */
export function duplicateKey(title: string): string {
  let s = String(title || '').toLowerCase();
  s = s.replace(/\[[^\]]*\]/g, ' ').replace(/\([^)]*\)/g, ' ');
  s = s.replace(/\b(2160p|1440p|1080p|1080i|720p|480p|4k|8k)\b/g, ' ');
  s = s.replace(
    /\b(x264|x265|h264|h265|hevc|avc|av1|10bit|8bit|hdr10\+?|hdr|sdr|remux|bluray|blu-ray|web-dl|webdl|webrip|dvdrip|hdrip)\b/g,
    ' ',
  );
  s = s.replace(/\b(uncensored|leak|chs|cht|中字|无码|流出)\b/g, ' ');
  // 结尾的发布组 `-GROUP`
  s = s.replace(/\s-\s?[a-z0-9]+$/g, ' ');
  // 日系标记 `-U` / `-C` / `-UC`
  s = s.replace(/-u?c?$/g, ' ');
  return s.replace(/[^a-z0-9\u4e00-\u9fff]+/g, '');
}

/**
 * 匹配用的「去噪」写法：`actorKey` 之后再剥掉连字符 / 下划线 / 括号这类分隔符。
 *
 * 这样 `Riko.Tachibana` / `Riko-Tachibana` / `立花里子` 都能和文件名对得上；
 * 「演员排除」在没有 NFO 的条目上就只能靠这一层兜底。
 */
export function nameSlug(text: string): string {
  return actorKey(text).replace(/[^a-z0-9\u4e00-\u9fff\u3040-\u30ff]/g, '');
}

/** 技术标记前缀，不当番号用 */const CODE_PREFIX_BLACKLIST = new Set([
  'S', 'EP', 'E', 'PART', 'PT', 'VOL', 'DISC', 'CD', 'CH', 'WEB', 'BD', 'HD', 'FHD', 'UHD',
  'SD', 'MP4', 'MKV', 'AVI', 'X264', 'X265', 'H264', 'H265', 'HEVC', 'AV1', 'AAC', 'DTS',
  'AC3', 'FLAC', 'HDR', 'REMUX', 'BLURAY', 'XXX', 'DD', 'DDP', 'TRUEHD', 'ATMOS',
]);

/**
 * 从文件名提番号。比 `parseJpCode` 更严：**必须带 `-` 或 `_` 分隔**，
 * 且数字不能是年份 —— 否则 `Movie 2020` 会被当成 `MOVIE-2020`，全库同名系列要炸。
 */
export function extractDupCode(name: string): string {
  const stem = String(name || '')
    .replace(/\.[^.]+$/, '')
    .toUpperCase();
  const re = /(?:^|[^A-Z0-9])([A-Z]{2,6})[-_](\d{2,5})(?![0-9])/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(stem)) !== null) {
    const prefix = m[1];
    const num = m[2];
    if (CODE_PREFIX_BLACKLIST.has(prefix)) continue;
    const n = Number(num);
    if (n >= 1900 && n <= 2099) continue;
    return `${prefix}-${num}`;
  }
  return '';
}

/** 标题里必须至少有一个字母 / 汉字 / 假名；纯数字与纯符号不参与判重 */
export function hasWord(text: string): boolean {
  return /[a-z\u4e00-\u9fff\u3040-\u30ff]/.test(text);
}

/**
 * CD1 / CD2 / 上卷 / 下卷这类「分片标记」。
 *
 * 同一部片的 CD1 与 CD2 不是重复，必须分开；同一个 CD1 有多份才算法重复。
 * 文件名和 NFO 都要看：有些片子 NFO 只写片名，分片信息只在文件名里。
 *
 * ⚠️ 「上 / 下」必须是**独立的一段**（前后都是分隔符或首尾），
 * 否则日文标题里的普通汉字会误判：
 *   `OKAD-109-身长170cm以上の女スパイ…` → 「以上」的上
 *   `SNOS-420 … お下品少女`            → 「下品」的下
 * 以前用 `(?:^|[^a-z0-9])` 当左边界，汉字和假名都不属于 `[a-z0-9]`，
 * 于是同一部片的两个版本被拆成 `part上` / `part下` 两组各 1 条，直接不成组
 * —— 表现就是「重复视频里少了一大截」（2026-11-03）。
 */
const PART_BOUNDARY = '[\\s._\\-\\[\\](){}/\\\\|,，、:：]';

export function partToken(text: string): string {
  const s = String(text || '');
  const m1 = /(?:^|[^a-z0-9])(cd|part|pt|disc|disk)[\s._-]*([0-9]{1,2})(?![0-9])/i.exec(s);
  if (m1) return `${m1[1].toLowerCase()}${Number(m1[2]) || m1[2]}`;
  const m2 = /(?:^|[^0-9])第\s*([0-9]{1,3})\s*[集话話篇]/i.exec(s);
  if (m2) return `ep${Number(m2[1]) || m2[1]}`;
  const m3 = new RegExp(
    `(?:^|${PART_BOUNDARY})(上|下|前編|後編|前篇|后篇)(?=$|${PART_BOUNDARY})`,
  ).exec(s);
  if (m3) return `part${m3[1]}`;
  return '';
}

/** 并查集（路径压缩 + 按秩合并） */
function makeUnionFind(size: number) {
  const parent = new Array<number>(size);
  const rank = new Array<number>(size).fill(0);
  for (let i = 0; i < size; i += 1) parent[i] = i;
  const find = (x: number): number => {
    let root = x;
    while (parent[root] !== root) root = parent[root];
    let cur = x;
    while (parent[cur] !== cur) {
      const next = parent[cur];
      parent[cur] = root;
      cur = next;
    }
    return root;
  };
  const union = (a: number, b: number): void => {
    const ra = find(a);
    const rb = find(b);
    if (ra === rb) return;
    if (rank[ra] < rank[rb]) parent[ra] = rb;
    else if (rank[ra] > rank[rb]) parent[rb] = ra;
    else {
      parent[rb] = ra;
      rank[ra] += 1;
    }
  };
  return { find, union };
}

interface LightRow {
  id: string;
  title: string;
  nfo_name: string | null;
  nfo_original_name: string | null;
  nfo_imdb_id: string | null;
  nfo_douban_id: string | null;
  code: string | null;
  nfo_year: number | null;
  rel_path: string;
}

interface FullRow {
  id: string;
  title: string;
  rel_path: string;
  size: number;
  /** 文件修改时间（毫秒）。同规格的两份靠它判断哪份更早 */
  mtime: number | null;
  duration: number | null;
  width: number | null;
  height: number | null;
  video_codec: string | null;
  code: string | null;
  nfo_year: number | null;
  nfo_score: number | null;
  nfo_poster: string | null;
  nfo_fanart: string | null;
  nfo_thumb: string | null;
  uncensored: number | null;
  chinese_sub: number | null;
  is_4k: number | null;
  hdr10: number | null;
  hdr10plus: number | null;
  hlg: number | null;
  dolby_vision: number | null;
  dolby_atmos: number | null;
  /** NFO 里的演员（JSON 数组字符串）；查重页「演员排除」靠它认人 */
  nfo_actors: string | null;
}

/** 「LTX」标记：文件名里独立出现（不是某个单词的一部分） */
const LTX_RE = /(^|[._\-\s])ltx([._\-\s]|$)/i;

/** 重复视频：四钥匙并查集分组，只返回 >= 2 条的分组 */
export async function registerVideoDuplicates(
  app: FastifyInstance,
  k: KernelApi,
  h: VideoHelpers,
): Promise<void> {
  app.get(
    '/api/v1/video/duplicates',
    secured('video:read', {
      schema: {
        operationId: 'videoDuplicates',
        tags: TAG,
        summary: '重复视频（豆瓣 / IMDB / 番号 / 标题+年份 四把钥匙，并查集分组）',
        querystring: h.ref('VideoDuplicatesQuery'),
        response: { 200: h.ref('VideoDuplicatesResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const started = Date.now();
      const q = (req.query || {}) as {
        libraryId?: string;
        limit?: number;
        excludeActors?: string;
      };
      const limit = Math.max(1, Math.min(Number(q.limit) || 100, 500));

      // ① 轻量投影：只取判重需要的列。
      // 离线 SMB 来源不参与查重：文件不在线，列出来「删除」必然失败。
      const offline = await offlineSmbPrefixes(k.db);
      const rows = (
        await sql<LightRow>`
          select id, title, nfo_name, nfo_original_name, nfo_imdb_id, nfo_douban_id,
                 code, nfo_year, rel_path
            from video_items
           where media_type = 'video'
             ${q.libraryId ? sql`and library_id = ${q.libraryId}` : sql``}
             ${offline.length > 0 ? sql`and ${offlineCond(offline, 'rel_path')}` : sql``}
           order by id asc
        `.execute(k.db)
      ).rows;

      if (rows.length < 2) {
        return { groups: [], totalGroups: 0, scanned: rows.length, tookMs: Date.now() - started };
      }

      // ② 每行算钥匙（**不再用文件名片名**）：
      //   * 标题钥匙只认 NFO 的 nfo_name / nfo_original_name；
      //   * 番号钥匙优先用扫描到的真实番号，其次从 NFO 标题里提；
      //   * CD1 / CD2 / 上卷 / 下卷的分片标记必须参与钥匙，分片之间不合并。
      const meta = rows.map((r) => {
        const imdb = String(r.nfo_imdb_id || '')
          .trim()
          .toLowerCase();
        const douban = String(r.nfo_douban_id || '').trim();
        const nfoName = String(r.nfo_name || '').trim();
        const nfoOriginal = String(r.nfo_original_name || '').trim();
        const code =
          String(r.code || '')
            .trim()
            .toUpperCase() || extractDupCode(`${nfoName} ${nfoOriginal}`);
        const nfoTitle = duplicateKey(nfoName) || duplicateKey(nfoOriginal);
        const titleOk = nfoTitle.length >= 4 && hasWord(nfoTitle);
        const part = partToken(`${r.rel_path} ${nfoName} ${nfoOriginal}`);
        const year = Number(r.nfo_year) || 0;
        return {
          imdb,
          douban,
          code,
          title: titleOk ? nfoTitle : '',
          titleOk,
          part,
          year: year > 1800 && year < 2200 ? year : 0,
        };
      });

      // ③ 硬钥匙先并：**不再按分片拆钥匙**
      //
      // 以前 `code:IPSD-045#cd1` / `#cd2` 各成一组，结果是「一部片分成 CD1-CD8」
      // 这种组每个分片只有 1 条，直接不成组 → 用户看到的是「重复视频里少了一大截」。
      // 现在同一番号一律同组，分片信息作为 `part` 字段带到条目上：
      //   - 有完整版（part 为空）时，自动勾选会把分片全部勾掉（留完整版）；
      //   - 只有分片、没有完整版时不自动勾选，避免把一部片删得只剩一半。
      const { find, union } = makeUnionFind(rows.length);
      const firstByKey = new Map<string, number>();
      const keyOfIndex = new Map<number, string>();
      const addKey = (key: string, i: number) => {
        if (!key) return;
        const prev = firstByKey.get(key);
        if (prev === undefined) {
          firstByKey.set(key, i);
          if (!keyOfIndex.has(i)) keyOfIndex.set(i, key);
        } else {
          union(prev, i);
        }
      };
      for (let i = 0; i < rows.length; i += 1) {
        const m = meta[i];
        if (m.imdb) addKey(`imdb:${m.imdb}`, i);
        if (m.douban) addKey(`douban:${m.douban}`, i);
        if (m.code) addKey(`code:${m.code}`, i);
      }

      // ④ 标题 + 年份（只对 NFO 标题生效）
      const byTitle = new Map<string, number[]>();
      for (let i = 0; i < rows.length; i += 1) {
        if (!meta[i].titleOk) continue;
        const key = meta[i].title;
        const arr = byTitle.get(key);
        if (arr) arr.push(i);
        else byTitle.set(key, [i]);
      }
      for (const [titleKey, idxs] of byTitle) {
        if (idxs.length < 2) continue;
        const years = [...new Set(idxs.map((i) => meta[i].year).filter((y) => y > 0))].sort(
          (a, b) => a - b,
        );
        if (years.length <= 1) {
          for (let n = 1; n < idxs.length; n += 1) union(idxs[0], idxs[n]);
          if (!keyOfIndex.has(idxs[0])) keyOfIndex.set(idxs[0], `title:${titleKey}`);
          continue;
        }
        // 多种年份 = 同名的不同片子（续集 / 重拍）。按年份分组，无年份的挂到最早那一年。
        const earliest = years[0];
        const firstOfYear = new Map<number, number>();
        for (const i of idxs) {
          const y = meta[i].year === 0 ? earliest : meta[i].year;
          const anchor = firstOfYear.get(y);
          if (anchor === undefined) firstOfYear.set(y, i);
          else union(anchor, i);
        }
        for (const [y, anchor] of firstOfYear) {
          if (!keyOfIndex.has(anchor)) keyOfIndex.set(anchor, `title:${titleKey}@${y || '?'}`);
        }
      }

      // ⑤ 聚组
      const groupsMap = new Map<number, number[]>();
      for (let i = 0; i < rows.length; i += 1) {
        const root = find(i);
        const arr = groupsMap.get(root);
        if (arr) arr.push(i);
        else groupsMap.set(root, [i]);
      }
      const dup = [...groupsMap.entries()]
        .filter(([, idxs]) => idxs.length >= 2)
        .map(([root, idxs]) => ({ root, idxs }))
        .sort((a, b) => b.idxs.length - a.idxs.length || a.root - b.root);

      // ⑥ 只对命中的 id 回表补全（走主键）
      const top = dup.slice(0, limit);
      const ids = [...new Set(top.flatMap((g) => g.idxs.map((i) => rows[i].id)))];
      const full = new Map<string, FullRow>();
      if (ids.length > 0) {
        const fullRows = (
          await sql<FullRow>`
            select id, title, rel_path, size, mtime, duration, width, height, video_codec,
                   code, nfo_year, nfo_score, nfo_poster, nfo_fanart, nfo_thumb,
                   uncensored, chinese_sub, is_4k, hdr10, hdr10plus, hlg,
                   dolby_vision, dolby_atmos, nfo_actors
              from video_items
             where id in (${sql.join(ids.map((v) => sql`${v}`), sql`, `)})
          `.execute(k.db)
        ).rows;
        for (const r of fullRows) full.set(r.id, r);
      }

      // ⑦ 每组算「建议保留」：分辨率优先，其次时长（更完整），最后体积
      const groups = top.map((g) => {
        const items = g.idxs.map((i) => {
          const r = full.get(rows[i].id);
          const relPath = String(r?.rel_path || rows[i].rel_path);
          const fileName = relPath.split('/').pop() || relPath;
          return {
            id: rows[i].id,
            title: String(r?.title || rows[i].nfo_name || rows[i].title),
            path: relPath,
            size: Number(r?.size) || 0,
            mtime: Number(r?.mtime) || 0,
            durationMs: r?.duration == null ? null : Number(r.duration),
            width: r?.width == null ? null : Number(r.width),
            height: r?.height == null ? null : Number(r.height),
            videoCodec: r?.video_codec ?? null,
            code: r?.code ?? null,
            year: r?.nfo_year == null ? null : Number(r.nfo_year),
            score: r?.nfo_score == null ? null : Number(r.nfo_score),
            hasArt:
              !!(
                String(r?.nfo_poster ?? '').trim() ||
                String(r?.nfo_fanart ?? '').trim() ||
                String(r?.nfo_thumb ?? '').trim()
              ),
            imdbId: rows[i].nfo_imdb_id ?? null,
            doubanId: rows[i].nfo_douban_id ?? null,
            // 判断「留哪条」真正要看的东西。
            // 没有这些，用户只能靠分辨率和体积猜，而「1080p 有中字」常常比
            // 「2160p 没字幕」更值得留。
            uncensored: Number(r?.uncensored) === 1,
            chineseSub: Number(r?.chinese_sub) === 1,
            is4k: Number(r?.is_4k) === 1,
            hdr:
              Number(r?.hdr10) === 1 ||
              Number(r?.hdr10plus) === 1 ||
              Number(r?.hlg) === 1 ||
              Number(r?.dolby_vision) === 1,
            dolbyVision: Number(r?.dolby_vision) === 1,
            dolbyAtmos: Number(r?.dolby_atmos) === 1,
            ltx: LTX_RE.test(fileName),
            // 能提出番号 = 日本片。默认勾选规则与「建议保留」的取舍都依赖它。
            isJp: Boolean(extractDupCode(fileName)),
            // NFO 演员的归一化键（`actorKey`）：前端「演员排除」拿它比对，
            // 这样「三上悠亜 / 三上悠亚」这种跨写法也能算同一个人。
            actorKeys: parseActorNames(r?.nfo_actors).map((n) => actorKey(n)).filter(Boolean),
            // 分片标记（cd1 / 上 / 空）。同一番号现在同组，前端靠它区分
            // 「完整版」和「CD1-CD8」，自动勾选时只勾分片、不碰完整版
            part: meta[i]?.part ?? '',
            suggestedKeep: false,
          };
        });
        // 「建议保留」：分辨率面积为主，同面积时更长的优先，再退体积；
        // 有中文字幕的给一点加成 —— 同分辨率下中字版通常更该留。
        const quality = (x: (typeof items)[number]) =>
          (Number(x.width) || 0) * (Number(x.height) || 0) * 1000 * (x.chineseSub ? 1.05 : 1) +
          (Number(x.durationMs) || 0) / 1000;
        // 完全同规格（面积 / 时长 / 体积都一样）时保留**修改时间更早**那份：
        // 后下的那份常是重下 / 二压，原始那份更值得留（2026-11-03 用户口径）。
        const better = (a: (typeof items)[number], b: (typeof items)[number]): boolean => {
          const qa = quality(a);
          const qb = quality(b);
          if (qa !== qb) return qa > qb;
          const sa = Number(a.size) || 0;
          const sb = Number(b.size) || 0;
          if (sa !== sb) return sa > sb;
          const ma = Number(a.mtime) || 0;
          const mb = Number(b.mtime) || 0;
          if (ma > 0 && mb > 0 && ma !== mb) return ma < mb;
          return false;
        };
        // 「建议保留」按**分片桶**算：`''`（完整版）一桶，`cd1` / `cd2` / `part上` 各自一桶。
        //
        // 只有同一个桶里有多份才算重复：CD1 与 CD2 是同一部片的两段，天生不是重复
        // （见文件头 partToken 注释，2026-11-03 用户反馈再次强调）。
        // 于是「CD1 + CD2 各一份」「完整版 + CD1 + CD2 各一份」这类组，每桶都只有一条
        // → 全组都是 keep → 被下面的过滤整组丢掉，不再出现在「重复视频」里。
        const byPart = new Map<string, typeof items>();
        for (const it of items) {
          const arr = byPart.get(it.part);
          if (arr) arr.push(it);
          else byPart.set(it.part, [it]);
        }
        for (const list of byPart.values()) {
          let keep = list[0];
          for (const it of list) if (better(it, keep)) keep = it;
          keep.suggestedKeep = true;
        }

        const keys = [...new Set(g.idxs.map((i) => keyOfIndex.get(i)).filter(Boolean))] as string[];
        return {
          key: keys[0] ?? `group:${g.root}`,
          title: items[0]?.title || '',
          count: items.length,
          keys,
          items,
        };
      })
        // 整组都「建议保留」= 组里没有该删的东西 → 不是重复组。
        // 典型：一部片只有 CD1 + CD2（各一份），以前会被当成「2 个重复」推给用户。
        .filter((g) => g.items.some((it) => !it.suggestedKeep));

      // --- 演员排除（整组口径）-----------------------------------------------
      //
      // 一组 = 同一部片的不同版本（四钥匙判据），演员必然相同。所以只要组里
      // **任何一条**命中被排除的演员，整组都不展示 —— 这样「没 NFO / 没封面」
      // 的版本也会跟着消失，不会留一堆孤儿卡片（2026-11-03 反馈）。
      //
      // 命中判定两层：
      //   ① NFO 演员键（actorKey 归一，「三上悠亜 / 三上悠亚」算同一个人）；
      //   ② 标题 / 文件名里出现演员名（只对 ≥4 字的名字做，两个字的名字在路径里遍地都是）。
      const excludedKeys = new Set<string>();
      const excludedSlugs: string[] = [];
      for (const raw of String(q.excludeActors || '').split('|')) {
        const name = raw.trim();
        if (!name) continue;
        const key = actorKey(name);
        if (!key) continue;
        excludedKeys.add(key);
        // 文件名兜底只对「够长」的名字做：两个字的名字（"あい" / "Aya"）
        // 在路径里遍地都是，会把无关的片子一起吞掉。汉字名 3 字起，罗马音 6 字符起。
        const slug = nameSlug(name);
        const hasCjk = /[\u4e00-\u9fff\u3040-\u30ff]/.test(slug);
        if (hasCjk ? slug.length >= 3 : slug.length >= 6) excludedSlugs.push(slug);
      }

      const visible =
        excludedKeys.size === 0
          ? groups
          : groups.filter(
              (g) =>
                !g.items.some((it) => {
                  if (it.actorKeys.some((k) => excludedKeys.has(k))) return true;
                  if (excludedSlugs.length === 0) return false;
                  const hay = nameSlug(`${it.title} ${it.path}`);
                  return excludedSlugs.some((n) => hay.includes(n));
                }),
            );

      return {
        groups: visible,
        totalGroups: visible.length,
        scanned: rows.length,
        tookMs: Date.now() - started,
      };
    },
  );

  // ---------------------------------------------------------------- 演员候选（查重页「演员排除」）
  //
  // 数据本来就在 `video_items.nfo_actors`（NFO / 刮削写入的 JSON 数组），
  // 不新建表也不联网：整库 distinct 一次，按 actorKey 归一后缓存 5 分钟。
  // 用户要的是「搜得到人、能多选」，不需要演员头像和档案，所以不走 JavDB。

  /** 名字键 → { 展示名, 出现条数 } */
  interface ActorEntry {
    name: string;
    key: string;
    count: number;
  }
  let actorCache: { at: number; items: ActorEntry[] } | null = null;

  const actorList = async (): Promise<ActorEntry[]> => {
    if (actorCache && Date.now() - actorCache.at < 5 * 60_000) return actorCache.items;
    const rows = (
      await sql<{ nfo_actors: string | null }>`
        select nfo_actors from video_items
         where nfo_actors is not null and nfo_actors <> ''
      `.execute(k.db)
    ).rows;
    const map = new Map<string, ActorEntry>();
    for (const r of rows) {
      // 同一条目里重复写的名字只算一次（NFO 手工编辑时见过）
      const seen = new Set<string>();
      for (const raw of parseActorNames(r.nfo_actors)) {
        const key = actorKey(raw);
        if (!key || seen.has(key)) continue;
        seen.add(key);
        const prev = map.get(key);
        if (prev) prev.count += 1;
        else map.set(key, { name: raw, key, count: 1 });
      }
    }
    const items = [...map.values()].sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
    actorCache = { at: Date.now(), items };
    return items;
  };

  app.get(
    '/api/v1/video/actors',
    secured('video:read', {
      schema: {
        operationId: 'videoActors',
        tags: TAG,
        summary: '演员候选（从 NFO 演员聚合，供查重页排除指定演员）',
        querystring: Type.Object({
          q: Type.Optional(Type.String({ maxLength: 80, description: '名字片段，忽略大小写' })),
          limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 })),
        }),
        response: {
          200: Type.Object({
            items: Type.Array(
              Type.Object({
                name: Type.String({ description: '展示用原名' }),
                key: Type.String({ description: '归一化键（与查重条目的 actorKeys 同一套）' }),
                count: Type.Integer({ description: '有几个条目含这位演员' }),
              }),
            ),
            total: Type.Integer({ description: '库里的演员总数（未按 q 过滤）' }),
          }),
        },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { q?: string; limit?: number };
      const limit = Math.max(1, Math.min(Number(q.limit) || 60, 200));
      const all = await actorList();
      const needle = actorKey(String(q.q || '').trim());
      const lower = String(q.q || '')
        .trim()
        .toLowerCase();
      const hit = needle
        ? all.filter((a) => a.key.includes(needle) || a.name.toLowerCase().includes(lower))
        : all;
      return { items: hit.slice(0, limit), total: all.length };
    },
  );

  // ---------------------------------------------------------------- 删除（查重页的「执行」动作）
  //
  // 此前查重只出报告：用户看完了还得自己去文件管理器一个个删，而且删完索引里
  // 还留着幽灵条目。这里一次做完三件事：文件移入回收站、清掉索引与观看/收藏记录、
  // 重算库条目数。
  app.post(
    '/api/v1/video/items/delete',
    secured('video:write', {
      schema: {
        operationId: 'videoItemsDelete',
        tags: TAG,
        summary: '删除视频（移入回收站，并清掉索引 / 观看进度 / 收藏）',
        body: h.ref('VideoDeleteItemsBody'),
        response: { 200: h.ref('VideoDeleteItemsResponse') },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as { ids?: string[]; permanent?: boolean };
      const ids = (body.ids || []).filter((v) => typeof v === 'string' && v.trim() !== '');
      if (ids.length === 0) throw httpError(400, 'ids required');
      return deleteVideoItems(k, ids, { permanent: body.permanent === true });
    },
  );

  // 后台版：客户端弹窗显示进度、不阻塞请求（也就不会撞 30s 超时）。
  // 任务表已经有 `done_count / total_count`，前端拿 `/tasks/:id` 就能画「已完成/总数」。
  app.post(
    '/api/v1/video/items/delete-task',
    secured('video:write', {
      schema: {
        operationId: 'videoItemsDeleteTask',
        tags: TAG,
        summary: '删除视频（后台任务，返回 taskId，用 /tasks/:id 看进度）',
        body: h.ref('VideoDeleteItemsBody'),
        response: {
          200: Type.Object({
            taskId: Type.String(),
            total: Type.Integer({ description: '本次要删的条目数' }),
          }),
        },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as { ids?: string[]; permanent?: boolean };
      const ids = (body.ids || []).filter((v) => typeof v === 'string' && v.trim() !== '');
      if (ids.length === 0) throw httpError(400, 'ids required');
      // maxAttempts=1：重跑会把已经在回收站的文件再移一次，只会产生噪音失败
      const taskId = await k.tasks.enqueue(
        'video.items.delete',
        { ids, permanent: body.permanent === true },
        { maxAttempts: 1 },
      );
      return { taskId, total: ids.length };
    },
  );
}

/**
 * 删除视频条目：文件移入回收站 → 清索引 / 观看进度 / 收藏 → 重算库条目数。
 *
 * 抽成独立函数是因为有两个入口：
 *   - `POST /video/items/delete`（同步，少量条目 / 老客户端）；
 *   - `POST /video/items/delete-task`（入队，客户端拿 taskId 轮询进度）。
 * 大库 / SMB 上删几十个文件要几分钟，同步接口会被客户端 30s 超时掐断
 * （2026-11-03 报的 `TimeoutException after 0:00:30`）。
 */
export interface DeleteVideoResult {
  done: string[];
  failed: Array<{ path: string; error: string }>;
  trashedTo: string;
  sidecars: string[];
}

export interface DeleteVideoOptions {
  onProgress?: (done: number, total: number) => void;
  shouldStop?: () => Promise<boolean>;
  /** true = 直接永久删除，不进回收站（用户勾掉「放入回收站」时） */
  permanent?: boolean;
}

export async function deleteVideoItems(
  k: KernelApi,
  ids: string[],
  opts: DeleteVideoOptions = {},
): Promise<DeleteVideoResult> {
  const { onProgress, shouldStop, permanent = false } = opts;
  const idList = sql.join(ids.map((v) => sql`${v}`), sql`, `);
  const videoRows = (
    await sql<(ArtRefRow & { id: string; library_id: string })>`
      select id, library_id, rel_path, nfo_poster, nfo_fanart, nfo_thumb from video_items
       where id in (${idList})
    `.execute(k.db)
  ).rows;
  const imageRows = (
    await sql<{ id: string; library_id: string; rel_path: string }>`
      select id, library_id, rel_path from image_items where id in (${idList})
    `.execute(k.db)
  ).rows;

  const root = filesRoot();
  const batch = new Date()
    .toISOString()
    .replace(/[-:]/g, '')
    .replace(/\..+$/, '')
    .replace('T', '-');
  const done: string[] = [];
  const failed: Array<{ path: string; error: string }> = [];
  const movedSidecars: string[] = [];
  const moved = new Set<string>();
  const dirOf = (rel: string) => rel.replace(/\\/g, '/').replace(/[^/]+$/, '');

  /**
   * 回收站目录：**跟源文件同一个卷**。
   *
   * 以前统一放到 `filesRoot/.colanas-trash`（默认就是 `C:\Users\<用户>`），
   * 而影视库常在别的盘或 SMB 上 —— `rename` 跨卷会失败，`movePath` 退化成
   * 「整文件复制 + 删源」，等于把片子往系统盘搬一份。实测一次删 16 个片是
   * **93 GB**，C 盘 93.6 GB 可用，差点把系统盘撑爆，而且一个 8 GB 的片要复制
   * 两分钟，界面上看起来就是「卡住不动」（2026-11-03）。
   *
   * 同卷 rename 是瞬时的、零拷贝，也不占额外空间。
   */
  const trashDirs = new Map<string, string>();
  const trashDirOf = (abs: string): string => {
    const underRoot = abs === root || abs.startsWith(root + path.sep);
    const vol = underRoot ? root : path.parse(abs).root || root;
    const cached = trashDirs.get(vol);
    if (cached) return cached;
    // 卷根可能不可写（只读盘 / 系统盘根目录），退回到 files 根下的回收站
    for (const dir of [
      path.join(vol, TRASH_DIR, batch),
      path.join(root, TRASH_DIR, batch),
    ]) {
      try {
        fs.mkdirSync(dir, { recursive: true });
        trashDirs.set(vol, dir);
        return dir;
      } catch {
        /* 这个卷建不了目录，试下一个 */
      }
    }
    trashDirs.set(vol, path.join(root, TRASH_DIR, batch));
    return path.join(root, TRASH_DIR, batch);
  };

  const uniqueDest = (abs: string): string => {
    const dir = trashDirOf(abs);
    const base = path.basename(abs);
    let dest = path.join(dir, base);
    let n = 1;
    while (fs.existsSync(dest)) {
      const ext = path.extname(base);
      const stem = path.basename(base, ext);
      dest = path.join(dir, `${stem}-${n}${ext}`);
      n += 1;
    }
    return dest;
  };

  // ---- 保护集合：保留下来的条目也引用的侧车不能删 -------------------------
  const protectedSet = new Set<string>();
  const libIds = [...new Set([...videoRows, ...imageRows].map((r) => r.library_id))];
  const targetDirs = new Set(
    [...videoRows, ...imageRows].map((r) => dirOf(r.rel_path)).filter(Boolean),
  );
  if (libIds.length > 0) {
    const libList = sql.join(libIds.map((v) => sql`${v}`), sql`, `);
    const others = (
      await sql<(ArtRefRow & { id: string })>`
        select id, rel_path, nfo_poster, nfo_fanart, nfo_thumb
          from video_items
         where library_id in (${libList})
      `.execute(k.db)
    ).rows.filter((r) => !ids.includes(r.id));
    // 同目录的兄弟条目 + 任何登记了 NFO 图片的条目都可能共用侧车
    for (const r of others) {
      const sameDir = targetDirs.has(dirOf(r.rel_path));
      const hasArt = !!(r.nfo_poster || r.nfo_fanart || r.nfo_thumb);
      if (!sameDir && !hasArt) continue;
      try {
        protectedSet.add(normAbs(resolveAnyPath(root, r.rel_path)));
      } catch {
        /* 路径越界：不影响删除 */
      }
      for (const p of await sidecarsOf(r)) protectedSet.add(normAbs(p));
    }
    // 同目录的图片条目本身也不能被当成侧车删掉
    const imgRows = (
      await sql<{ rel_path: string }>`
        select rel_path from image_items where library_id in (${libList})
      `.execute(k.db)
    ).rows;
    for (const r of imgRows) {
      if (!targetDirs.has(dirOf(r.rel_path))) continue;
      try {
        protectedSet.add(normAbs(resolveAnyPath(root, r.rel_path)));
      } catch {
        /* 忽略 */
      }
    }
  }

  // ---- 移动视频文件 + 只属于它的侧车 --------------------------------------
  for (const row of videoRows) {
    // 长任务要能被取消：跨卷复制一个 8 GB 的片要两分钟，用户在界面上点了
    // 「取消」/ 重启内核时，至少要在文件之间停下来
    if (shouldStop && (await shouldStop())) break;
    onProgress?.(done.length + failed.length, ids.length);
    try {
      const abs = resolveAnyPath(root, row.rel_path);
      if (moved.has(normAbs(abs))) continue;
      if (permanent) {
        // 永久删除：force 让「文件已经不在」也算成功（断电重跑时不会卡在幽灵条目）
        await fsp.rm(abs, { force: true });
        moved.add(normAbs(abs));
        done.push(row.id);
        k.log.info({ name: path.basename(abs) }, 'video.items.delete: removed permanently');
      } else {
        const dest = uniqueDest(abs);
        await movePath(abs, dest);
        moved.add(normAbs(abs));
        done.push(row.id);
        // 每条都留痕：文件被搬到哪个盘哪个目录，事后想手动找回只能靠这条
        k.log.info(
          { name: path.basename(abs), dest },
          'video.items.delete: moved to trash',
        );
      }

      for (const side of await sidecarsOf(row)) {
        const key = normAbs(side);
        if (protectedSet.has(key) || moved.has(key)) continue;
        if (!fs.existsSync(side)) continue;
        try {
          if (permanent) {
            await fsp.rm(side, { force: true });
          } else {
            await movePath(side, uniqueDest(side));
          }
          moved.add(key);
          movedSidecars.push(path.basename(side));
        } catch (err) {
          k.log.warn({ side, err: String(err) }, 'video.items.delete: sidecar failed');
        }
      }
    } catch (err) {
      const message = (err as Error).message || String(err);
      failed.push({ path: row.rel_path, error: message });
      k.log.warn({ path: row.rel_path, err: message }, 'video.items.delete: item failed');
    }
  }

  // ---- 图片条目（图片库 / 混合库） ----------------------------------------
  for (const row of imageRows) {
    if (shouldStop && (await shouldStop())) break;
    onProgress?.(done.length + failed.length, ids.length);
    try {
      const abs = resolveAnyPath(root, row.rel_path);
      if (moved.has(normAbs(abs))) {
        done.push(row.id);
        continue;
      }
      if (permanent) {
        await fsp.rm(abs, { force: true });
        moved.add(normAbs(abs));
        done.push(row.id);
        k.log.info({ name: path.basename(abs) }, 'video.items.delete: removed permanently');
      } else {
        const dest = uniqueDest(abs);
        await movePath(abs, dest);
        moved.add(normAbs(abs));
        done.push(row.id);
        k.log.info(
          { name: path.basename(abs), dest },
          'video.items.delete: moved to trash',
        );
      }
    } catch (err) {
      const message = (err as Error).message || String(err);
      failed.push({ path: row.rel_path, error: message });
      k.log.warn({ path: row.rel_path, err: message }, 'video.items.delete: item failed');
    }
  }

  if (done.length > 0) {
    const videoDone = done.filter((id) => videoRows.some((r) => r.id === id));
    const imageDone = done.filter((id) => imageRows.some((r) => r.id === id));
    await k.db.transaction().execute(async (trx: any) => {
      if (videoDone.length > 0) {
        const list = sql.join(videoDone.map((v) => sql`${v}`), sql`, `);
        await sql`delete from video_items where id in (${list})`.execute(trx);
        // 关联表不清会留下「孤儿进度 / 孤儿收藏」，列表里按 item_id 反查就会扑空
        await sql`delete from video_watch where item_id in (${list})`.execute(trx);
        await sql`delete from video_progress where item_id in (${list})`.execute(trx);
        await sql`delete from video_favorites where item_id in (${list})`.execute(trx);
      }
      if (imageDone.length > 0) {
        const list = sql.join(imageDone.map((v) => sql`${v}`), sql`, `);
        await sql`delete from image_items where id in (${list})`.execute(trx);
      }
      // 库条目数：视频 + 图片都算，否则图片库会显示 0
      await sql`
        update video_libraries
           set items = (select count(*) from video_items where library_id = video_libraries.id)
                     + (select count(*) from image_items where library_id = video_libraries.id)
      `.execute(trx);
    });
  }

  k.log.info(
    {
      requested: ids.length,
      done: done.length,
      failed: failed.length,
      sidecars: movedSidecars.length,
      batch,
    },
    'video.items.delete',
  );
  // 永久删除没有批次可还；契约里 trashedTo 是必填字符串，给空串
  return { done, failed, trashedTo: permanent ? '' : batch, sidecars: movedSidecars };
}
