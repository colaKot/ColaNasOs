import { sql } from 'kysely';
import { tmdbReady, searchTmdb } from './tmdb';
import { readScrapeSettings, tmdbConfigOf } from './scrape';
import type { KernelApi } from '../../../kernel/types';
import type { TmdbConfig } from '../discover/tmdb';

/**
 * 剧集显示名的「默认语言（简体中文）」解析。
 *
 * 为什么需要：`video_items.series` 是扫描时从发布名派生的（Elementary /
 * The.Last.of.Us / Human.Vapor.2026...），剧卡、剧列表、首页推荐一直直接把它
 * 当标题显示，于是整排英文；而每集的 `nfo_name` 其实是中文单集名（「试播集」），
 * 不能拿来当剧名。TMDB 的 `language=zh-CN` 是配好的，详情里也有中文剧名，
 * 只是从来没为「剧级名字」单独取过。
 *
 * 顺序：本地路径里的中文剧名 → media_catalog 快照缓存 → TMDB 搜索中文名。
 * 缓存连「查过但没有中文」也记，避免每次首页都重复联网；网络失败不缓存。
 */

const CJK = /[\u3400-\u9fff]/;
const CATALOG = 'series_title';

/** 从发布名 / 目录名里挑出一段中文剧名；没有中文返回空串。 */
export function zhTitleFrom(raw: string): string {
  const s = String(raw || '');
  if (!CJK.test(s)) return '';
  // `[七王国的骑士 第一季].A.Knight...` 这种方括号里的中文名最可靠
  // \x5B/[ \x5D/] \u3010/【 \u3011/】：字符类里直接写 \[ 会被 no-useless-escape 报错
  const bracket = /[\x5B\u3010]([^\x5D\u3011]*[\u3400-\u9fff][^\x5D\u3011]*)[\x5D\u3011]/.exec(s);
  if (bracket && String(bracket[1] || '').trim().length >= 2) {
    return String(bracket[1]).trim();
  }
  // 否则取连续中文段中最长的一段（遇到 . / _ / 数字以外的英文标签就断）
  const segs = s.match(/[\u3400-\u9fff][\u3400-\u9fff0-9A-Za-z·：:，,、\s]*/g) || [];
  let best = '';
  let bestCount = 0;
  for (const seg of segs) {
    const t = seg.trim().replace(/[\s.,·:：，、]+$/, '').trim();
    const count = (t.match(/[\u3400-\u9fff]/g) || []).length;
    if (count >= 2 && t.length <= 40 && count > bestCount) {
      best = t;
      bestCount = count;
    }
  }
  return best;
}

const norm = (s: string) =>
  String(s || '').toLowerCase().replace(/[^a-z0-9\u3400-\u9fff]+/g, '');

/**
 * 发布名 → TMDB 搜索词。
 *
 * 发布名格式恒为「片名.年份.规格.发布组」，所以**遇到第一个规格词就截断**比
 * 逐词剔除干净得多：`Human.Vapor.2026.S01.2160p...` 只剩 `Human Vapor`，
 * 用整串去搜 TMDB 会 0 命中（实测），片名就在开头几个词里。
 */
const SPEC_WORD = /^(?:s\d{1,2}e?\d*|e\d{1,2}|(?:19|20)\d{2}|\d{3,4}p|4k|8k|uhd|nf|amzn|hbo|max|apple|web|dl|webrip|bluray|remux|x26[45]|h26[45]|hevc|avc|hdr|dv|atmos|ddp|dts|aac|ac3|internal|complete|10bit|8bit|\d+(?:bit)?)$/i;

function searchQueryOf(series: string): string {
  const raw = String(series || '')
    .replace(/\[[^\]]*\]/g, ' ')
    .replace(/[._-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const words: string[] = [];
  for (const w of raw.split(' ')) {
    if (!w || SPEC_WORD.test(w)) break;
    words.push(w);
    if (words.length >= 8) break;
  }
  return words.join(' ').trim();
}

function pathHints(relPath: string): string[] {
  const parts = String(relPath || '').replace(/\\/g, '/').split('/');
  const file = parts.pop() || '';
  const dir = parts.pop() || '';
  return [file, dir];
}

async function cacheGet(k: KernelApi, key: string): Promise<string | null> {
  const rows = (
    await sql<{ payload: string }>`
      select payload from media_catalog
       where catalog_type = ${CATALOG} and key = ${key}
       limit 1
    `.execute(k.db)
  ).rows;
  if (!rows.length) return null;
  try {
    const v: unknown = JSON.parse(String(rows[0].payload || ''));
    return typeof v === 'string' ? v : null;
  } catch {
    return null;
  }
}

async function cachePut(k: KernelApi, key: string, value: string): Promise<void> {
  await sql`
    insert into media_catalog (catalog_type, key, payload, item_count, snapshot_at)
    values (${CATALOG}, ${key}, ${JSON.stringify(value)}, 1, ${Date.now()})
    on conflict(catalog_type, key) do update set
      payload = excluded.payload, snapshot_at = excluded.snapshot_at
  `.execute(k.db);
}

async function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      p,
      new Promise<T>((_, reject) => {
        timer = setTimeout(() => reject(new Error('series title timeout')), ms);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function pickZhTitle(list: Array<{ title: string; originalTitle: string }>, query: string): string {
  const want = norm(query);
  if (!want) return '';
  const zh = list.filter((c) => CJK.test(String(c.title || '')));
  if (zh.length === 0) return '';
  // ① 英文原名能对上，最可靠（Elementary → 福尔摩斯：基本演绎法）
  for (const c of zh) {
    const original = norm(c.originalTitle);
    if (original && (original === want || original.includes(want) || want.includes(original))) {
      return String(c.title).trim();
    }
  }
  // ② 译名与英文原名毫无字面重合时（Human Vapor → 气体人第一号 / Teach You a
  //    Lesson → 铁拳教育，原名分别是日文、韩文），只能信 TMDB 的相关性排序：
  //    查询至少两个词、且只回来一个中文候选才采用，避免把别的剧安上来。
  if (query.trim().split(/\s+/).length >= 2 && zh.length === 1) {
    return String(zh[0].title).trim();
  }
  return '';
}

async function resolveOne(
  k: KernelApi,
  cfg: TmdbConfig,
  online: boolean,
  name: string,
  relPath: string,
): Promise<string> {
  // ① 本地：series 名 / 文件名 / 上级目录名里自带的中文剧名，零网络开销
  for (const hint of [name, ...pathHints(relPath)]) {
    const zh = zhTitleFrom(hint);
    if (zh) return zh;
  }
  // ② 缓存（空串 = 之前查过但没有中文名，别再联网）
  const cached = await cacheGet(k, name);
  if (cached !== null) return cached || name;
  if (!online) return name;
  const query = searchQueryOf(name);
  if (!query) return name;
  // ③ TMDB：用英文剧名搜剧，取原名匹配且带中文译名的那个
  try {
    const list = await withTimeout(searchTmdb(cfg, query, 'tv'), 3500);
    const found = pickZhTitle(list, query);
    await cachePut(k, name, found);
    return found || name;
  } catch {
    // 网络失败 / 超时不写缓存，下次首页再试；绝不能让首页因为这些请求挂住
    return name;
  }
}

/**
 * 批量解析剧的中文显示名。返回 `原 series 名 → 显示名` 的映射；
 * 找不到中文就原样返回，调用方可以无脑替换。
 *
 * `series` 列仍是分组 / 查询键，禁止改它 —— 只替换展示用的标题字段。
 */
export async function localizeSeriesNames(
  k: KernelApi,
  entries: Array<{ name: string; path?: string | null }>,
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const unique = new Map<string, string>();
  for (const e of entries) {
    const name = String(e.name || '').trim();
    if (!name || unique.has(name)) continue;
    unique.set(name, String(e.path || '').trim());
  }
  if (unique.size === 0) return out;
  const cfg = tmdbConfigOf(readScrapeSettings(k));
  const online = tmdbReady(cfg);
  await Promise.all(
    [...unique.entries()].map(async ([name, path]) => {
      try {
        out.set(name, await resolveOne(k, cfg, online, name, path));
      } catch {
        out.set(name, name);
      }
    }),
  );
  return out;
}

/** 首页推荐区用：只改展示标题，seriesInfo.name 仍是剧的查询键。 */
export async function localizeHomeTitles(
  k: KernelApi,
  items: Array<Record<string, unknown>>,
): Promise<void> {
  const cards = items
    .map((item) => ({
      item,
      info: item.seriesInfo as { name?: string } | undefined,
    }))
    .filter((x) => !!String(x.info?.name || '').trim());
  if (cards.length === 0) return;
  const names = await localizeSeriesNames(
    k,
    cards.map((x) => ({ name: String(x.info?.name || ''), path: String(x.item.path || '') })),
  );
  for (const { item, info } of cards) {
    const name = String(info?.name || '');
    const zh = names.get(name);
    if (zh && zh !== name) item.title = zh;
  }
}
