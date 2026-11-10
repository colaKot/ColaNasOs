import { sql } from 'kysely';

/**
 * 日本电影库的筛选口径（分辨率 / 标签 / 题材）。
 *
 * 单独成文件的原因：列表筛选（`routes/items.ts`）与筛选项聚合（`routes/facets.ts`）
 * 必须用**同一份**判断，否则一定会出现「面板上写着 138 条，点进去只剩 3 条」。
 * 列名一律由调用方传，方便以后带表别名复用。
 */

/** 「LTX」标记：文件名里独立出现（与 `routes/duplicates.ts` 的 `LTX_RE` 同义） */
export function ltxCond(column = 'rel_path'): ReturnType<typeof sql> {
  // SQLite 默认没有正则。把文件名里的分隔符（. _ - / \）统一成空格、首尾各补一个空格，
  // 再用 like '% ltx %' 判「独立单词」—— 与 JS 侧 /(^|[._\-\s])ltx([._\-\s]|$)/i 等价
  // （文件名里能用到的分隔符只有这几种）。
  // 反斜杠必须写成 char(92)：SQLite 字符串字面量不认反斜杠转义，'\\' 是两个字符。
  const normed =
    `(' ' || replace(replace(replace(replace(replace(lower(${column}), '.', ' '), '_', ' '),` +
    ` '-', ' '), '/', ' '), char(92), ' ') || ' ')`;
  return sql`${sql.raw(normed)} like ${'% ltx %'}`;
}

/**
 * 标签筛选（用户口径）：
 *   `uncensored` 无码 —— `uncensored` 列（扫描时由 `-U` 后缀 / 无码·流出 关键词得出）
 *   `cracked`    破解 —— 无码 **或** 文件名带 ltx（所以天然包含 ltx）
 *   `ltx`        只认文件名里的 ltx 标记
 */
export function jpTagCond(
  tag: unknown,
  column = 'rel_path',
  uncensoredColumn = 'uncensored',
): ReturnType<typeof sql> | null {
  const t = String(tag ?? '')
    .trim()
    .toLowerCase();
  const unc = sql.raw(`${uncensoredColumn} = 1`);
  if (t === 'uncensored') return unc;
  if (t === 'ltx') return ltxCond(column);
  if (t === 'cracked') return sql`(${unc} or ${ltxCond(column)})`;
  return null;
}

/**
 * 分辨率筛选：
 *   `4k`   —— `is_4k = 1`（扫描时 width>=3840 或 height>=2160）
 *   `1080` —— 非 4K 且 height>=1080（含 1440x1080 这类变形 HD）
 *
 * 宽高来自 ffprobe，探测失败的历史行是 null，这类行两个档都筛不出来 ——
 * 这是有意的：把「未知」硬塞进 1080 会让用户以为片源很好。
 *
 * `prefix` 用于带表别名的查询（如演员列表 `from video_items i join …`）：
 * 不传就退回裸列名，保持所有旧调用点不变。
 */
export function resolutionCond(key: unknown, prefix = ''): ReturnType<typeof sql> | null {
  const k = String(key ?? '')
    .trim()
    .toLowerCase();
  const col = (name: string) => sql.raw(prefix ? `${prefix}.${name}` : name);
  if (k === '4k' || k === '2160') return sql`${col('is_4k')} = 1`;
  if (k === '1080') return sql`(${col('is_4k')} = 0 and coalesce(${col('height')}, 0) >= 1080)`;
  return null;
}

/**
 * NFO 题材里的「单体作品」不入筛选列表。
 *
 * NFO 来自不同站点，同一个标签有三种写法：`單體作品`（繁）/ `单体作品`（简）/
 * `単体作品`（日文汉字）。三者都含「体作品」「體作品」，按这两个词判就够，
 * 不用维护三份常量。
 */
export function isSingleWorkGenre(name: string): boolean {
  return /[体體]作品/.test(name);
}

/** 题材筛选默认展示条数（用户口径：按数量取前 30） */
export const GENRE_FACET_LIMIT = 30;
