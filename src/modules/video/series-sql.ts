import { sql } from 'kysely';

/**
 * 剧级聚合的三个公共 SQL 片段。
 *
 * 剧在库里没有自己的表（一部剧 = `video_items` 里同 `series` 的一批行），
 * 凡是「一剧一条」的地方（剧库列表、首页推荐、最近更新、智能合集）都必须
 * 用同一套口径算封面和已看进度，否则同一个剧在不同页面会显示不同的封面 /
 * 不同的「已看完」。放在一处，改就是全改。
 */

const col = (alias: string | undefined, name: string) =>
  sql.ref(alias ? `${alias}.${name}` : name);

/**
 * 能当封面用的那一集（`coalesce` 兜底链）。
 *
 * 优先取本剧里「有海报的那一集」，都没有才退回缩略图，最后退最小 id；
 * 一条都给不出时 `/video/art` 会 404，卡片整排灰块。
 */
export function seriesCoverIdSql(alias?: string) {
  return sql<string | null>`coalesce(
    min(case when nullif(${col(alias, 'nfo_poster')}, '') is not null then ${col(alias, 'id')} end),
    min(case when nullif(${col(alias, 'nfo_thumb')}, '') is not null then ${col(alias, 'id')} end),
    min(${col(alias, 'id')})
  )`;
}

/**
 * 只认真有**竖版海报**的那一集（没有就是 null）。
 *
 * `coverId` 是「能当封面用」的兜底，可能只是横版剧照或视频首帧，铺进 2:3
 * 的封面位会被裁成一条。需要「整部剧一张竖版封面」的地方（剧库、首页剧卡、
 * 智能合集）优先用它：有值只信它，没值走 TMDB 剧海报，最后才退回 coverId。
 */
export function seriesPosterIdSql(alias?: string) {
  return sql<string | null>`min(case when nullif(${col(alias, 'nfo_poster')}, '') is not null then ${col(alias, 'id')} end)`;
}

/**
 * 当前用户已看集数。
 *
 * `watchAlias` 是 `video_watch` 的别名（`left join video_watch w on w.item_id = ...
 * and w.owner_id = ?`）。没有 join 时用 `episodeWatchedSql` 的单条口径。
 */
export function watchedEpisodesSql(watchAlias: string) {
  return sql<number>`sum(case when ${sql.ref(`${watchAlias}.item_id`)} is not null then 1 else 0 end)`;
}

/** 剧级三态：0 未看 / 0<n<总 未看完 / = 总 已看完 */
export type SeriesWatchState = 'unwatched' | 'watching' | 'watched';
