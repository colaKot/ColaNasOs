import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { proxyFetch } from '../../../kernel/proxy-fetch';

/**
 * 日本片演员档案。
 *
 * 数据来源（缺一不可，顺序固定）：
 * 1. **JavDB 演员搜索**（`/search?f=actor&q=<name>`）：头像 + 精确确认是这个人；
 * 2. **日文维基 `?action=raw`**：身高 / 三围 / 生日 / 出身地（JavDB 演员页只有头像）。
 *
 * ⚠️ 精确匹配是本文件最重要的逻辑：JavDB 演员搜索是**模糊**的，
 *    「第一条」会给「汁系 / 丸一二三」这类结果配上真人头像。
 *    必须「双向包含且公共长度 ≥ 3」才认，否则返回 null（宁缺不错）。
 *
 * ⚠️ 死链判定：空串、Jellyfin 本地路径、javbus 的 302 年龄门页面都不能当头像。
 */
export interface ActorProfile {
  key: string;
  name: string;
  avatarUrl: string | null;
  birthday: string | null;
  heightCm: number | null;
  bust: number | null;
  waist: number | null;
  hips: number | null;
  birthplace: string | null;
  source: string[];
  fetchedAt: number;
}

/** 日文旧字 / 异体字 → 常用简体（演员名跨站写法不一致，收藏与聚合同规则） */
const VARIANTS: Record<string, string> = {
  亜: '亚',
  澤: '泽',
  邊: '边',
  濱: '滨',
  髙: '高',
  䑓: '台',
  竜: '龙',
  國: '国',
};

/** 演员名归一化：收藏与聚合共用同一规则 */
export function actorKey(name: string): string {
  return String(name || '')
    .normalize('NFKC')
    .replace(/[\s\u3000·・.．]/g, '')
    .replace(/[\u3041-\u3096]/g, (ch) => String.fromCharCode(ch.charCodeAt(0) + 0x60))
    .replace(/[亜澤邊濱髙䑓竜國]/g, (ch) => VARIANTS[ch] || ch)
    .toLowerCase();
}

/** 双向包含且公共长度 ≥ 3 才算同一个人 */
export function sameActorName(a: string, b: string): boolean {
  const x = actorKey(a);
  const y = actorKey(b);
  if (!x || !y) return false;
  if (x === y) return true;
  const [short, long] = x.length <= y.length ? [x, y] : [y, x];
  return short.length >= 3 && long.includes(short);
}

export function isDeadActorThumb(url: string | null | undefined): boolean {
  const u = String(url || '').trim();
  if (!u) return true;
  if (
    /^[a-z]:\\/i.test(u) ||
    u.startsWith('file:') ||
    u.includes('/Users/') ||
    u.includes('\\Users\\')
  ) {
    return true;
  }
  if (!/^https?:\/\//i.test(u)) return true;
  return !/\.(jpg|jpeg|png|webp|avif)(\?|$)/i.test(u);
}

const CACHE_DIR_NAME = 'jp-actor-cache';
const CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

function cachePath(dataDir: string, key: string): string {
  const hash = crypto.createHash('sha1').update(key).digest('hex').slice(0, 20);
  return path.join(dataDir, CACHE_DIR_NAME, `${hash}.json`);
}

function readCache(dataDir: string, key: string): ActorProfile | null {
  try {
    const file = cachePath(dataDir, key);
    if (!fs.existsSync(file)) return null;
    const parsed = JSON.parse(fs.readFileSync(file, 'utf-8')) as ActorProfile;
    if (!parsed || parsed.key !== key) return null;
    if (Date.now() - Number(parsed.fetchedAt || 0) > CACHE_TTL_MS) return null;
    return parsed;
  } catch {
    return null;
  }
}

function writeCache(dataDir: string, profile: ActorProfile): void {
  try {
    const file = cachePath(dataDir, profile.key);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(profile), 'utf-8');
  } catch {
    /* 缓存写失败不影响返回 */
  }
}

async function fetchText(
  url: string,
  timeoutMs: number,
  headers: Record<string, string> = {},
): Promise<string | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await proxyFetch(url, {
      signal: controller.signal,
      headers: {
        'user-agent': 'Mozilla/5.0 (compatible; ColaNasOs/1.0)',
        ...headers,
      },
    });
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function stripTags(html: string): string {
  return html
    .replace(/<[^>]+>/g, ' ')
    // wiki 标记：`{{JPN}}・[[東京都]][[新宿区]]` → `東京都新宿区`
    // 之前只去 HTML 标签，出生地原样留在库里，详情页显示成 `{{JPN}}・[[愛知県]]`（2026-11-04）
    .replace(/\{\{[^{}]*\}\}/g, ' ')
    .replace(/\[\[([^\]|]*\|)?([^\]]*)\]\]/g, '$2')
    .replace(/'{2,}/g, '')
    .replace(/[・\s]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** JavDB 演员搜索：返回 {name, avatarUrl} 或 null（模糊结果一律不认） */
export function pickExactActor(
  html: string,
  query: string,
): { name: string; avatarUrl: string | null } | null {
  const re = /<a[^>]+href="(\/actors\/[^"]+)"[^>]*>([\s\S]{0,300}?)<\/a>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const name = stripTags(m[2]);
    if (!name || !sameActorName(name, query)) continue;
    // 头像通常在同一条目的 img 里；先从整段附近找
    const around = html.slice(Math.max(0, m.index - 400), m.index + 600);
    const img = /<img[^>]+src="([^"]+)"/i.exec(around);
    const avatar = img && !isDeadActorThumb(img[1]) ? img[1] : null;
    return { name, avatarUrl: avatar };
  }
  return null;
}

/** 从日文维基 raw 里解析身高 / 三围 / 生日 / 出身地 */
export function parseWikiProfile(raw: string): Partial<ActorProfile> {
  const out: Partial<ActorProfile> = {};
  const height = /身長\s*[=＝]\s*([0-9]{2,3})/.exec(raw);
  if (height) out.heightCm = Number(height[1]);

  const three =
    /スリーサイズ\s*[=＝]\s*[Bb]?([0-9]{2,3})[\s\-/]*[Ww]?([0-9]{2,3})[\s\-/]*[Hh]?([0-9]{2,3})/.exec(
      raw,
    );
  if (three) {
    out.bust = Number(three[1]);
    out.waist = Number(three[2]);
    out.hips = Number(three[3]);
  }

  // 生日：优先完整日期；很多个人条目只有 `生年 = 1996`（如 桃乃木かな），
  // 之前只认 `生年月日`、解析不出来就整项留空，看起来像「没有详情」。
  const birthday =
    /生年月日\s*[=＝]\s*([0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日)/.exec(raw) ??
    /生年月日\s*[=＝]\s*([0-9]{4}-[0-9]{1,2}-[0-9]{1,2})/.exec(raw);
  if (birthday) {
    out.birthday = birthday[1];
  } else {
    const bornYear = /生年\s*[=＝]\s*([0-9]{4})/.exec(raw);
    if (bornYear) out.birthday = `${bornYear[1]}年`;
  }

  const birthplace = /出身地\s*[=＝]\s*([^\n|]+)/.exec(raw);
  if (birthplace) out.birthplace = stripTags(birthplace[1]).slice(0, 40);
  return out;
}

export interface FetchActorOptions {
  dataDir: string;
  timeoutMs?: number;
  /** 测试注入 */
  fetchImpl?: typeof fetch;
  /** JavDB 地址（可配置） */
  javdbBase?: string;
  wikiBase?: string;
  /**
   * 是否查 JavDB（默认 true）。
   *
   * 批量补档案时传 false：JavDB 在多数国内网络下不可达，`get()` 要等满
   * timeout（8s）才失败，1177 个演员就是 2.6 小时纯等待；而**头像本来就能从
   * 本地 NFO 的 `<actor><thumb>` 拿到**（见 jp-links.backfillActorThumbs），
   * 批量这趟只需要维基的身高 / 生日 / 出身地。
   */
  withJavdb?: boolean;
}

/**
 * 抓取演员档案：JavDB 确认身份 + 维基补三围；任一失败返回 null。
 * 结果按 actorKey 缓存 7 天（档案几乎不变，没必要每次打站点）。
 */
export async function fetchActorProfile(
  name: string,
  opts: FetchActorOptions,
): Promise<ActorProfile | null> {
  const key = actorKey(name);
  if (!key) return null;

  const cached = readCache(opts.dataDir, key);
  if (cached) return cached;

  const timeoutMs = Math.max(1500, opts.timeoutMs ?? 8000);
  const javdbBase = (opts.javdbBase || 'https://javdb.com').replace(/\/$/, '');
  const wikiBase = (opts.wikiBase || 'https://ja.wikipedia.org').replace(/\/$/, '');
  const headers = {
    // JavDB 必须带年龄确认与中文 locale，否则返回的是确认页
    cookie: 'over18=1; locale=zh',
  };
  const doFetch = opts.fetchImpl ?? (proxyFetch as unknown as typeof fetch);
  const get = async (url: string) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await doFetch(url, {
        signal: controller.signal,
        headers: { ...headers, 'user-agent': 'Mozilla/5.0 (compatible; ColaNasOs/1.0)' },
      });
      if (!res.ok) return null;
      return await res.text();
    } catch {
      return null;
    } finally {
      clearTimeout(timer);
    }
  };

  const sources: string[] = [];
  let avatarUrl: string | null = null;

  const search = opts.withJavdb === false
    ? null
    : await get(`${javdbBase}/search?f=actor&q=${encodeURIComponent(name)}`);
  if (search) {
    const picked = pickExactActor(search, name);
    if (picked) {
      avatarUrl = picked.avatarUrl;
      sources.push('javdb');
    }
  }

  const wiki = await get(`${wikiBase}/wiki/${encodeURIComponent(name)}?action=raw`);
  const prof: Partial<ActorProfile> = wiki ? parseWikiProfile(wiki) : {};
  if (wiki && Object.keys(prof).length > 0) sources.push('jawiki');

  if (sources.length === 0) return null;

  const profile: ActorProfile = {
    key,
    name,
    avatarUrl,
    birthday: prof.birthday ?? null,
    heightCm: prof.heightCm ?? null,
    bust: prof.bust ?? null,
    waist: prof.waist ?? null,
    hips: prof.hips ?? null,
    birthplace: prof.birthplace ?? null,
    source: sources,
    fetchedAt: Date.now(),
  };
  writeCache(opts.dataDir, profile);
  return profile;
}

/** 供路由使用：抓取 + 兜底（网络不通时返回仅含名字的占位，明确标注 source=[]） */
export async function actorProfileOrPlaceholder(
  name: string,
  opts: FetchActorOptions,
): Promise<ActorProfile> {
  const fetched = await fetchActorProfile(name, opts);
  if (fetched) return fetched;
  return {
    key: actorKey(name),
    name,
    avatarUrl: null,
    birthday: null,
    heightCm: null,
    bust: null,
    waist: null,
    hips: null,
    birthplace: null,
    source: [],
    fetchedAt: Date.now(),
  };
}

// 供纯函数测试/外部复用
export { fetchText as _fetchTextForTests };
