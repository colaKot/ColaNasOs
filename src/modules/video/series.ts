/**
 * 剧集识别（零依赖，纯字符串规则）。
 *
 * 约定：**能解析出集号（episode）或季号（season）的文件才算剧集**，剧名取库根下的第一层目录名；
 * 其余按影片处理（`series = null`）。这样「电影/Inception.mkv」这种按类型分目录的库不会被误判成剧集。
 *
 * 支持：
 *   - `S01E02` / `s1e2` / `S01.E02` / `S01_E02`
 *   - `1x02`
 *   - `EP02` / `E02`
 *   - `第2集` / `第02话`
 * 季号还可来自目录：`Season 1` / `S01` / `第一季`。
 */
export interface EpisodeInfo {
  /** 剧名（库根下第一层目录）；影片为 null */
  series: string | null;
  season: number | null;
  episode: number | null;
}

const SEASON_DIR = [
  /^season[\s._-]*(\d{1,2})$/i,
  /^s(\d{1,2})$/i,
  /^第\s*([一二三四五六七八九十百\d]{1,3})\s*季$/,
];

const SXXEYY = /s(\d{1,2})[\s._-]*e(\d{1,3})/i;
const NXNN = /(?:^|[^\d])(\d{1,2})x(\d{1,3})(?:[^\d]|$)/;
const EP_N = /(?:^|[^\da-z])e(?:p)?[\s._-]*(\d{1,3})(?:[^\d]|$)/i;
const CN_EP = /第\s*(\d{1,3})\s*[集话話]/;

const CN_NUM: Record<string, number> = {
  一: 1,
  二: 2,
  三: 3,
  四: 4,
  五: 5,
  六: 6,
  七: 7,
  八: 8,
  九: 9,
  十: 10,
};

/** 「十二」这类两位数，够用即可；解析不出返回 NaN */
function cnNumber(raw: string): number {
  if (/^\d+$/.test(raw)) return Number(raw);
  if (raw.length === 1) return CN_NUM[raw] ?? NaN;
  if (raw.startsWith('十')) {
    const rest = raw.slice(1);
    return 10 + (rest ? (CN_NUM[rest] ?? NaN) : 0);
  }
  if (raw.endsWith('十')) {
    const head = raw.slice(0, -1);
    return (CN_NUM[head] ?? NaN) * 10;
  }
  if (raw.includes('十')) {
    const [head, tail] = raw.split('十');
    return (CN_NUM[head] ?? NaN) * 10 + (CN_NUM[tail] ?? NaN);
  }
  return NaN;
}

/** 从目录段解析季号（`Season 1` / `S01` / `第一季`） */
export function seasonFromDir(dir: string): number | null {
  for (const re of SEASON_DIR) {
    const m = re.exec(dir.trim());
    if (!m) continue;
    const n = cnNumber(m[1]);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return null;
}

/** 从文件名（不含扩展名）解析 `{season, episode}`；解析不出为 null */
export function episodeFromName(
  name: string,
): { season: number | null; episode: number | null } | null {
  const base = name.replace(/\.[^./\\]+$/, '');

  const sxxeyy = SXXEYY.exec(base);
  if (sxxeyy) return { season: Number(sxxeyy[1]), episode: Number(sxxeyy[2]) };

  const nxnn = NXNN.exec(base);
  if (nxnn) return { season: Number(nxnn[1]), episode: Number(nxnn[2]) };

  const ep = EP_N.exec(base);
  if (ep) return { season: null, episode: Number(ep[1]) };

  const cn = CN_EP.exec(base);
  if (cn) return { season: null, episode: Number(cn[1]) };

  return null;
}

/**
 * 解析库内相对路径（POSIX，相对库根）→ 剧集信息。
 * 目录段中出现的季号优先于文件名里的（目录通常更可靠）。
 */
export function parseEpisode(relPath: string): EpisodeInfo {
  const parts = relPath.split('/').filter((s) => s.length > 0);
  if (parts.length < 2) return { series: null, season: null, episode: null };

  const fileName = parts[parts.length - 1];
  const dirs = parts.slice(0, -1);
  const parsed = episodeFromName(fileName);

  let season: number | null = null;
  // 季号看目录（`Season 1` / `S01` / `第一季`），从最深层往上找，dirs[0] 是剧名不算
  for (let i = dirs.length - 1; i >= 1; i -= 1) {
    const s = seasonFromDir(dirs[i]);
    if (s !== null) {
      season = s;
      break;
    }
  }
  if (season === null && parsed?.season != null) season = parsed.season;

  const episode = parsed?.episode ?? null;
  if (season === null && episode === null) {
    return { series: null, season: null, episode: null };
  }

  return { series: dirs[0], season, episode };
}
/** 一条已索引剧集文件的最小信息（缺集计算只需要季 / 集号） */
export interface EpisodeRef {
  season: number | null;
  episode: number | null;
}

export interface SeasonGap {
  season: number;
  /** 该季缺的集号（升序） */
  episodes: number[];
}

const MAX_GAP_SPAN = 500;
const MAX_GAP_PER_SEASON = 200;

/**
 * 整季缺集：按季把已索引集号排成 min..max，列出中间缺的编号。
 *
 * 边界（避免异常命名刷出上百条）：
 *   - 季号为 null 视为第 1 季；
 *   - 集号缺失（null / ≤0）的文件不参与计算；
 *   - `max - min > 500` 的季跳过（`E01` 与 `E999` 并存通常是命名不规范）；
 *   - 每季最多返回 200 个缺号。
 *
 * 返回值只含**真有缺口**的季，按季号升序。
 */
export function missingEpisodes(rows: EpisodeRef[]): SeasonGap[] {
  const bySeason = new Map<number, number[]>();
  for (const row of rows) {
    if (row.episode == null || !Number.isFinite(row.episode) || row.episode <= 0) continue;
    const season = row.season != null && row.season > 0 ? row.season : 1;
    const list = bySeason.get(season) ?? [];
    list.push(row.episode);
    bySeason.set(season, list);
  }

  const gaps: SeasonGap[] = [];
  for (const [season, episodes] of bySeason) {
    const min = Math.min(...episodes);
    const max = Math.max(...episodes);
    if (max - min > MAX_GAP_SPAN) continue;
    const present = new Set(episodes);
    const missing: number[] = [];
    for (let ep = min + 1; ep < max; ep += 1) {
      if (!present.has(ep)) {
        missing.push(ep);
        if (missing.length >= MAX_GAP_PER_SEASON) break;
      }
    }
    if (missing.length) gaps.push({ season, episodes: missing });
  }

  return gaps.sort((a, b) => a.season - b.season);
}
