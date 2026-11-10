import { sql } from 'kysely';
import { EQUIV_RAW } from './search-equiv';

/**
 * 音乐搜索：简繁互通 + 跳字模糊 + 文件名。
 *
 * 曲库只有几千条，用 SQLite 的 `GLOB` 就够，不必上 FTS / 不加运行时依赖；
 * 而 FTS5 trigram 只能解决「连续片段」，解决不了用户要的「我台妹 → 我爱台妹」。
 *
 * 做法：查询拆成单字，每个字换成「简繁等价字符类」，再用 `*` 串起来：
 *   「我爱台妹」→ `*[我][爱愛][台枱檯臺颱][妹]*`        （连续 + 简繁互通）
 *              → `*[我]*[爱愛]*[台枱檯臺颱]*[妹]*`    （允许跳字）
 * 一个 GLOB 同时吃掉三件事：简繁、大小写、跳字。实测 SQLite 3.53 的 `GLOB [...]`
 * 按 Unicode 码点比较，中文字符类可用（回归用例见 tool/check/music-compat-smoke.js）。
 *
 * 等价表由 zhconv 离线生成（一次性，见 search-equiv.ts），运行时零依赖；
 * 每组首字为简体规范字。只处理单字，「乾杯 / 干杯」这类词组差异不在搜索层处理。
 */

const EQUIV: Map<string, string> = (() => {
  const m = new Map<string, string>();
  for (const group of EQUIV_RAW.split(/\s+/)) {
    if (!group) continue;
    for (const ch of group) if (!m.has(ch)) m.set(ch, group);
  }
  return m;
})();

const isCJK = (c: string) => /[\u3400-\u9fff\uf900-\ufaff]/.test(c);

/** 每个查询字 → 一个 GLOB 字符类；空格 / 标点等非文字返回 null，当作分隔跳过 */
function globClass(c: string): string | null {
  const g = EQUIV.get(c);
  if (g) return `[${g}]`;
  if (isCJK(c)) return `[${c}]`;
  if (/^[a-z0-9]$/i.test(c)) {
    const lo = c.toLowerCase();
    const hi = c.toUpperCase();
    return lo === hi ? `[${lo}]` : `[${lo}${hi}]`;
  }
  return null;
}

export interface MusicSearchPattern {
  op: 'like' | 'glob';
  pattern: string;
  /** 跳字模糊：命中范围大，排序时降权 */
  fuzzy?: boolean;
  /** 空格分词序号：同 term 内 OR，不同 term 间 AND；-1 = 整串精确兜底 */
  term: number;
}

/** 跳字太长会把整表都匹上，也拖慢 GLOB；正常歌名用不到这么长 */
const MAX_FUZZY_CHARS = 12;

const likeOf = (s: string) => `%${s.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;

export function musicSearchPatterns(q: string): MusicSearchPattern[] {
  const s = String(q ?? '').trim();
  if (!s) return [];
  const terms = s.split(/\s+/).filter(Boolean);
  const out: MusicSearchPattern[] = [];
  for (let i = 0; i < terms.length; i += 1) {
    const term = terms[i];
    // 每个词都留一条原串 LIKE：精确命中、含标点 / 纯 ASCII 的词靠它兜底
    out.push({ op: 'like', pattern: likeOf(term), term: i });
    const classes: string[] = [];
    let cjk = 0;
    for (const c of term) {
      const cl = globClass(c);
      if (!cl) continue;
      classes.push(cl);
      if (isCJK(c)) cjk += 1;
    }
    if (cjk === 0 || classes.length === 0) continue; // 纯 ASCII 词沿用旧行为
    out.push({ op: 'glob', pattern: `*${classes.join('')}*`, term: i });
    if (cjk >= 2 && classes.length >= 2 && classes.length <= MAX_FUZZY_CHARS) {
      out.push({ op: 'glob', pattern: `*${classes.join('*')}*`, fuzzy: true, term: i });
    }
  }
  // 「鲜花 回春丹」这类多词查询：整串（含空格）确实出现在文件名里时也该命中
  if (terms.length > 1) out.push({ op: 'like', pattern: likeOf(s), term: -1 });
  return out;
}

function clause(col: string, p: MusicSearchPattern) {
  return p.op === 'glob'
    ? sql`${sql.ref(col)} glob ${p.pattern}`
    : sql`${sql.ref(col)} like ${p.pattern} escape '\\'`;
}

function anyPattern(columns: string[], pats: MusicSearchPattern[]) {
  return pats.reduce<unknown>(
    (acc, p) => sql`${acc} or (${columns.reduce<unknown>(
      (a, col) => sql`${a} or ${clause(col, p)}`,
      sql`1 = 0` as unknown,
    )})`,
    sql`1 = 0` as unknown,
  );
}

function groupsOf(pats: MusicSearchPattern[]) {
  const groups = new Map<number, MusicSearchPattern[]>();
  for (const p of pats) {
    if (p.term < 0) continue;
    const list = groups.get(p.term) ?? [];
    list.push(p);
    groups.set(p.term, list);
  }
  return groups;
}

/** 每个词分别在自己的 OR 组里命中，组间 AND；直接塞进 `where ${...}` */
export function musicSearchWhere(columns: string[], q: string) {
  const pats = musicSearchPatterns(q);
  if (pats.length === 0) return null;
  let ands: unknown = sql`1 = 1`;
  for (const list of groupsOf(pats).values()) {
    ands = sql`${ands} and (${anyPattern(columns, list)})`;
  }
  const whole = pats.filter((p) => p.term === -1);
  if (whole.length > 0) return sql`((${ands}) or (${anyPattern(columns, whole)}))`;
  return sql`(${ands})`;
}

/**
 * 相关度：连续 / 精确命中排前面，纯跳字命中沉底。无搜索时返回 null。
 * 只能用于偏移分页（compat）；主模块用排序键 cursor，不能改 order by。
 */
export function musicSearchRank(columns: string[], q: string) {
  const strong = musicSearchPatterns(q).filter((p) => !p.fuzzy && p.term >= 0);
  if (strong.length === 0) return null;
  let ands: unknown = sql`1 = 1`;
  for (const list of groupsOf(strong).values()) {
    ands = sql`${ands} and (${anyPattern(columns, list)})`;
  }
  return sql`case when (${ands}) then 0 else 1 end`;
}
