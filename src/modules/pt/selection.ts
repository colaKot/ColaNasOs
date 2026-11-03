/**
 * PT 择种引擎（纯函数，便于单测）。
 *
 * 设计原则：**可解释、可复现、不猜**。标题只用于排序与硬性过滤，
 * 不凭标题文本断定真实画质；被排除的候选必须带可读原因。
 */
export interface PtMedia {
  title?: string | null;
  originalTitle?: string | null;
  year?: string | null;
  season?: number | null;
  /** TMDB 风格类型（含 Animation 时按动画处理音轨要求） */
  genres?: string[] | null;
  originalLanguage?: string | null;
}

export interface PtCandidate {
  siteId: string;
  torrentId: string;
  infoHash?: string | null;
  title: string;
  sizeBytes?: number | null;
  seeders?: number | null;
  leechers?: number | null;
  resolution?: string | null;
  publishedAt?: string | null;
  /** 来自 IMDb / TMDB 精确搜索的候选，已用 ID 校验 */
  matchedById?: boolean;
  downloadUrl?: string | null;
}

export interface PtRule {
  maxSizeBytes?: number | null;
  minSeeders?: number | null;
  excludedKeywords?: string[];
  season?: number | null;
  resolutionOrder?: string[];
  quality?: 'all' | '1080p' | '1440p' | '4k' | null;
  hdr?: 'all' | 'hdr' | 'hdr10' | 'hdr10plus' | 'dolby' | null;
  audioLangs?: string[];
}

export interface ExcludedCandidate extends PtCandidate {
  excludedReason: string;
}

export interface SelectResult {
  selected: PtCandidate | null;
  sorted: PtCandidate[];
  excluded: ExcludedCandidate[];
  reason: string;
}

const TITLE_STOPWORDS = new Set([
  'the',
  'a',
  'an',
  'of',
  'and',
  'or',
  'to',
  'in',
  'on',
  'for',
  'with',
  'at',
  'by',
  'de',
  'di',
  'le',
  'la',
  'les',
  'el',
  'los',
  'las',
  'der',
  'die',
  'das',
  '第',
  '部',
  '篇',
  '之',
  '集',
  '季',
  '章',
]);

export const TITLE_MATCH_THRESHOLD = 0.5;
export const DEFAULT_RESOLUTION_ORDER = ['2160p', '1080p', '720p', '480p'];

export function normalizeTitle(title: string): string {
  return String(title || '')
    .toLowerCase()
    .replace(/[\u3000\s]+/g, ' ')
    .replace(/[._\-[\]()【】（）]/g, ' ')
    .replace(/\b(19|20)\d{2}\b/g, ' ')
    .replace(/[^\p{L}\p{N} ]/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
}

export function seasonMarkers(season: number): string[] {
  const n = Number(season) || 0;
  if (n <= 0) return [];
  const pad = String(n).padStart(2, '0');
  return [`s${pad}`, `s${n}`, `season ${n}`, `season${n}`, `第${n}季`, `第${pad}季`];
}

/** 由媒体信息生成有序、去重的搜索关键词（season > 0 时只产「按季」关键词） */
export function buildKeywordVariants(media: PtMedia | null, season = 0): string[] {
  if (!media) return [];
  const title = String(media.title || '').trim();
  const original = String(media.originalTitle || '').trim();
  const year = String(media.year || '').slice(0, 4);
  const names: string[] = [];
  if (original) names.push(original);
  if (title && title !== original) names.push(title);

  const out: string[] = [];
  const push = (v: string) => {
    const s = String(v || '').trim();
    if (s && !out.includes(s)) out.push(s);
  };

  if (season > 0) {
    const pad = String(season).padStart(2, '0');
    for (const n of names) {
      push(`${n} S${pad}`);
      push(`${n} Season ${season}`);
    }
    return out;
  }
  if (year) for (const n of names) push(`${n} ${year}`);
  for (const n of names) push(n);
  if (out.length === 0 && year) out.push(year);
  return out;
}

export function titleMatchScore(title: string, media: PtMedia | null): number {
  const ct = normalizeTitle(title);
  if (!ct || !media) return 0;
  const variants = [media.title, media.originalTitle]
    .map((v) => normalizeTitle(String(v || '')))
    .filter(Boolean);
  let best = 0;
  for (const v of variants) {
    const tokens = v.split(' ').filter(Boolean);
    if (tokens.length === 0) continue;
    const content = tokens.filter((t) => t.length > 1 && !TITLE_STOPWORDS.has(t));
    const pool = content.length > 0 ? content : tokens;
    const hit = pool.filter((t) => ct.includes(t)).length;
    best = Math.max(best, hit / pool.length);
  }
  return best;
}

export function qualityHeight(title: string): number | null {
  const t = String(title || '').toLowerCase();
  if (/\b(2160p|4k|uhd)\b/.test(t)) return 2160;
  if (/\b1440p\b/.test(t)) return 1440;
  if (/\b1080p\b/.test(t)) return 1080;
  if (/\b720p\b/.test(t)) return 720;
  if (/\b480p\b/.test(t)) return 480;
  return null;
}

/** 0 无 / 1 HDR / 2 HDR10 / 3 HDR10+ / 4 杜比视界 */
export function hdrLevel(title: string): number {
  const t = String(title || '').toUpperCase();
  if (/(DOLBY\s*VISION|DOVI|\bDV\b|杜比视界)/.test(t)) return 4;
  if (/HDR10\+/.test(t)) return 3;
  if (/HDR10(?!\+)/.test(t)) return 2;
  if (/\bHDR\b/.test(t)) return 1;
  return 0;
}

const AUDIO_KEYWORDS: Record<string, string[]> = {
  zh: ['中配', '国语', '国配', '普通话', '中文配音', 'mandarin', 'chinese', 'chs', 'chi'],
  zh_tw: ['台配', '台版国语', '繁中配音', '台灣配音'],
  yue: ['粤语', '粵語', 'canton', 'cantonese'],
  ja: ['日语', '日配', 'japanese', 'jpn'],
  ko: ['韩语', '韩配', 'korean', 'kor'],
  en: ['英语', '英配', 'english', 'eng'],
  fr: ['法语', 'french', 'fra'],
  de: ['德语', 'german', 'ger', 'deu'],
  es: ['西语', '西班牙语', 'spanish', 'spa'],
  ru: ['俄语', 'russian', 'rus'],
  th: ['泰语', 'thai', 'tha'],
  vi: ['越南语', 'vietnamese', 'vie'],
  id: ['印尼语', 'indonesian', 'ind'],
  ar: ['阿拉伯语', 'arabic', 'ara'],
  hi: ['印地语', 'hindi', 'hin'],
};

export function detectAudioLangs(title: string): string[] {
  const t = String(title || '').toLowerCase();
  const out: string[] = [];
  for (const [code, words] of Object.entries(AUDIO_KEYWORDS)) {
    if (words.some((w) => t.includes(w.toLowerCase()))) out.push(code);
  }
  return out;
}

const QUALITY_MIN: Record<string, number> = { all: 0, '1080p': 1080, '1440p': 1440, '4k': 2160 };
const HDR_MIN: Record<string, number> = { all: 0, hdr: 1, hdr10: 2, hdr10plus: 3, dolby: 4 };

function nativeAudioLang(originalLanguage: string | null | undefined): string {
  const p = String(originalLanguage || '')
    .trim()
    .toLowerCase()
    .split(/[-_]/)[0];
  if (!p) return '';
  return p === 'cn' ? 'zh' : p;
}

export function applySmartFilter(opts: {
  filter?: PtRule;
  candidate: PtCandidate;
  isAnimation?: boolean;
  originalLanguage?: string | null;
}): { pass: boolean; reason: string } {
  const f = opts.filter || {};
  const title = opts.candidate.title || '';

  const minH = QUALITY_MIN[String(f.quality || 'all')] || 0;
  if (minH > 0) {
    const h = qualityHeight(title);
    if (h === null) return { pass: false, reason: 'QUALITY_UNKNOWN' };
    if (h < minH) return { pass: false, reason: 'QUALITY_TOO_LOW' };
  }

  const minHdr = HDR_MIN[String(f.hdr || 'all')] || 0;
  if (minHdr > 0 && hdrLevel(title) < minHdr) return { pass: false, reason: 'HDR_TOO_LOW' };

  const langs = Array.isArray(f.audioLangs) ? f.audioLangs : [];
  if (opts.isAnimation && langs.length > 0) {
    // 原声就是所需语言（如国产动画）⇒ 天然满足，不再要求标题写「国语/中配」
    const native = nativeAudioLang(opts.originalLanguage);
    if (!(native && langs.includes(native))) {
      const found = detectAudioLangs(title);
      if (!langs.some((c) => found.includes(c))) return { pass: false, reason: 'AUDIO_MISSING' };
    }
  }
  return { pass: true, reason: '' };
}

export function hardFilter(
  rule: PtRule,
  candidate: PtCandidate,
  media: PtMedia | null,
): { pass: boolean; reason: string } {
  const maxSize = Number(rule.maxSizeBytes || 0) || 0;
  if (maxSize > 0 && candidate.sizeBytes != null && Number(candidate.sizeBytes) > maxSize) {
    return { pass: false, reason: 'SIZE_EXCEEDED' };
  }

  const minSeeders = Number(rule.minSeeders || 0) || 0;
  if (minSeeders > 0) {
    if (candidate.seeders == null) return { pass: false, reason: 'SEEDERS_UNKNOWN' };
    if (Number(candidate.seeders) < minSeeders) return { pass: false, reason: 'SEEDERS_TOO_LOW' };
  }

  const excluded = (rule.excludedKeywords || [])
    .map((k) => String(k).toLowerCase())
    .filter(Boolean);
  if (excluded.length > 0) {
    const t = String(candidate.title || '').toLowerCase();
    const hit = excluded.find((k) => t.includes(k));
    if (hit) return { pass: false, reason: `EXCLUDED_KEYWORD:${hit}` };
  }

  const needSeason = Number(rule.season || 0) || 0;
  if (needSeason > 0) {
    const ct = normalizeTitle(candidate.title);
    if (!seasonMarkers(needSeason).some((m) => ct.includes(m))) {
      return { pass: false, reason: 'SEASON_MISMATCH' };
    }
  }

  if (media && !candidate.matchedById) {
    const hasVariant = [media.title, media.originalTitle]
      .map((v) => normalizeTitle(String(v || '')))
      .filter(Boolean);
    if (hasVariant.length > 0 && titleMatchScore(candidate.title, media) < TITLE_MATCH_THRESHOLD) {
      return { pass: false, reason: 'TITLE_MISMATCH' };
    }
  }

  // 画质 / HDR / 音轨门槛（与智能筛选同一套规则）
  const smart = applySmartFilter({
    filter: rule,
    candidate,
    isAnimation: (media?.genres || []).includes('Animation'),
    originalLanguage: media?.originalLanguage ?? null,
  });
  if (!smart.pass) return smart;

  return { pass: true, reason: '' };
}

function resolutionRank(rule: PtRule, resolution: string | null | undefined): number {
  const order = (rule.resolutionOrder || []).map((s) => String(s).toLowerCase()).filter(Boolean);
  const list = order.length > 0 ? order : DEFAULT_RESOLUTION_ORDER;
  const idx = list.indexOf(String(resolution || '').toLowerCase());
  return idx < 0 ? 999 : idx;
}

/** 排序：分辨率偏好 → 做种降序 → 体积升序 → 发布时间降序 */
export function sortCandidates(rule: PtRule, candidates: PtCandidate[]): PtCandidate[] {
  return [...candidates].sort((a, b) => {
    const ra = resolutionRank(rule, a.resolution);
    const rb = resolutionRank(rule, b.resolution);
    if (ra !== rb) return ra - rb;

    const sa = a.seeders == null ? -1 : Number(a.seeders);
    const sb = b.seeders == null ? -1 : Number(b.seeders);
    if (sa !== sb) return sb - sa;

    const za = a.sizeBytes == null ? Number.MAX_SAFE_INTEGER : Number(a.sizeBytes);
    const zb = b.sizeBytes == null ? Number.MAX_SAFE_INTEGER : Number(b.sizeBytes);
    if (za !== zb) return za - zb;

    const pa = a.publishedAt ? new Date(a.publishedAt).getTime() : 0;
    const pb = b.publishedAt ? new Date(b.publishedAt).getTime() : 0;
    return pb - pa;
  });
}

export function dedupe(candidates: PtCandidate[]): PtCandidate[] {
  const seen = new Set<string>();
  const out: PtCandidate[] = [];
  for (const c of candidates) {
    const key = c.infoHash ? `ih:${c.infoHash}` : `st:${c.siteId}:${c.torrentId}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(c);
  }
  return out;
}

export function selectBest(
  rule: PtRule,
  candidates: PtCandidate[],
  media: PtMedia | null,
): SelectResult {
  const list = dedupe(candidates);
  const passed: PtCandidate[] = [];
  const excluded: ExcludedCandidate[] = [];
  for (const c of list) {
    const verdict = hardFilter(rule, c, media);
    if (verdict.pass) passed.push(c);
    else excluded.push({ ...c, excludedReason: verdict.reason });
  }
  const sorted = sortCandidates(rule, passed);
  const selected = sorted[0] ?? null;
  let reason: string;
  if (selected) {
    const parts: string[] = [];
    if (selected.resolution) parts.push(`分辨率 ${selected.resolution}`);
    if (selected.seeders != null) parts.push(`做种 ${selected.seeders}`);
    if (selected.sizeBytes != null) {
      parts.push(`大小 ${(Number(selected.sizeBytes) / 1024 / 1024 / 1024).toFixed(2)}GB`);
    }
    reason = `选中 ${selected.title}：${parts.join('、') || '满足规则'}`;
    if (excluded.length > 0) reason += `；其余 ${excluded.length} 个候选被排除`;
  } else {
    reason = `没有符合条件的候选（排除 ${excluded.length} 个）`;
  }
  return { selected, sorted, excluded, reason };
}
