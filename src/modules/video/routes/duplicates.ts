import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { TAG } from '../util';
import { filesRoot, httpError, resolveAnyPath } from '../../files/fs-root';
import { TRASH_DIR, movePath } from '../../files/ops';
import { normAbs, sidecarsOf, type ArtRefRow } from '../sidecars';
import { offlineCond, offlineSmbPrefixes } from '../sources';
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

/** 技术标记前缀，不当番号用 */
const CODE_PREFIX_BLACKLIST = new Set([
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
 */
export function partToken(text: string): string {
  const s = String(text || '');
  const m1 = /(?:^|[^a-z0-9])(cd|part|pt|disc|disk)[\s._-]*([0-9]{1,2})(?![0-9])/i.exec(s);
  if (m1) return `${m1[1].toLowerCase()}${Number(m1[2]) || m1[2]}`;
  const m2 = /(?:^|[^0-9])第\s*([0-9]{1,3})\s*[集话話篇]/i.exec(s);
  if (m2) return `ep${Number(m2[1]) || m2[1]}`;
  const m3 = /(?:^|[^a-z0-9])(上|下|前編|後編|前篇|后篇)(?![a-z])/i.exec(s);
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
      const q = (req.query || {}) as { libraryId?: string; limit?: number };
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

      const keyWithPart = (base: string, part: string) => (part ? `${base}#${part}` : base);

      // ③ 硬钥匙先并
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
        if (m.imdb) addKey(keyWithPart(`imdb:${m.imdb}`, m.part), i);
        if (m.douban) addKey(keyWithPart(`douban:${m.douban}`, m.part), i);
        if (m.code) addKey(keyWithPart(`code:${m.code}`, m.part), i);
      }

      // ④ 标题 + 年份（只对 NFO 标题生效）
      const byTitle = new Map<string, number[]>();
      for (let i = 0; i < rows.length; i += 1) {
        if (!meta[i].titleOk) continue;
        const key = keyWithPart(meta[i].title, meta[i].part);
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
            select id, title, rel_path, size, duration, width, height, video_codec,
                   code, nfo_year, nfo_score, nfo_poster, nfo_fanart, nfo_thumb,
                   uncensored, chinese_sub, is_4k, hdr10, hdr10plus, hlg,
                   dolby_vision, dolby_atmos
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
            suggestedKeep: false,
          };
        });
        // 「建议保留」：分辨率面积为主，同面积时更长的优先，再退体积；
        // 有中文字幕的给一点加成 —— 同分辨率下中字版通常更该留。
        const quality = (x: (typeof items)[number]) =>
          (Number(x.width) || 0) * (Number(x.height) || 0) * 1000 * (x.chineseSub ? 1.05 : 1) +
          (Number(x.durationMs) || 0) / 1000;
        let keep = items[0];
        for (const it of items) if (quality(it) > quality(keep)) keep = it;
        keep.suggestedKeep = true;

        const keys = [...new Set(g.idxs.map((i) => keyOfIndex.get(i)).filter(Boolean))] as string[];
        return {
          key: keys[0] ?? `group:${g.root}`,
          title: items[0]?.title || '',
          count: items.length,
          keys,
          items,
        };
      });

      return {
        groups,
        totalGroups: dup.length,
        scanned: rows.length,
        tookMs: Date.now() - started,
      };
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
      const body = (req.body || {}) as { ids?: string[] };
      const ids = (body.ids || []).filter((v) => typeof v === 'string' && v.trim() !== '');
      if (ids.length === 0) throw httpError(400, 'ids required');

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
      const trashDir = path.join(root, TRASH_DIR, batch);
      fs.mkdirSync(trashDir, { recursive: true });
      const done: string[] = [];
      const failed: Array<{ path: string; error: string }> = [];
      const movedSidecars: string[] = [];
      const moved = new Set<string>();
      const dirOf = (rel: string) => rel.replace(/\\/g, '/').replace(/[^/]+$/, '');

      const uniqueDest = (abs: string): string => {
        const base = path.basename(abs);
        let dest = path.join(trashDir, base);
        let n = 1;
        while (fs.existsSync(dest)) {
          const ext = path.extname(base);
          const stem = path.basename(base, ext);
          dest = path.join(trashDir, `${stem}-${n}${ext}`);
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
        try {
          const abs = resolveAnyPath(root, row.rel_path);
          if (moved.has(normAbs(abs))) continue;
          await movePath(abs, uniqueDest(abs));
          moved.add(normAbs(abs));
          done.push(row.id);

          for (const side of await sidecarsOf(row)) {
            const key = normAbs(side);
            if (protectedSet.has(key) || moved.has(key)) continue;
            if (!fs.existsSync(side)) continue;
            try {
              await movePath(side, uniqueDest(side));
              moved.add(key);
              movedSidecars.push(path.basename(side));
            } catch (err) {
              k.log.warn({ side, err: String(err) }, 'video.items.delete: sidecar failed');
            }
          }
        } catch (err) {
          failed.push({ path: row.rel_path, error: (err as Error).message || String(err) });
        }
      }

      // ---- 图片条目（图片库 / 混合库） ----------------------------------------
      for (const row of imageRows) {
        try {
          const abs = resolveAnyPath(root, row.rel_path);
          if (moved.has(normAbs(abs))) {
            done.push(row.id);
            continue;
          }
          await movePath(abs, uniqueDest(abs));
          moved.add(normAbs(abs));
          done.push(row.id);
        } catch (err) {
          failed.push({ path: row.rel_path, error: (err as Error).message || String(err) });
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
      return { done, failed, trashedTo: batch, sidecars: movedSidecars };
    },
  );
}
