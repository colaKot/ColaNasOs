import { sql } from 'kysely';
import type { Migration } from '../../../kernel/migrator';

export const MUSIC_MIGRATIONS: Migration[] = [
    {
      id: '032_music',
      async up(db) {
        await sql`
          create table if not exists music_libraries (
            id text primary key,
            name text not null,
            root_path text not null unique,
            created_at integer not null,
            last_scan_at integer,
            items integer not null default 0
          )
        `.execute(db);

        await sql`
          create table if not exists music_tracks (
            id text primary key,
            library_id text not null,
            rel_path text not null,
            title text not null,
            artist text,
            album text,
            album_artist text,
            genre text,
            track_no integer,
            year integer,
            duration integer,
            bitrate integer,
            sample_rate integer,
            channels text,
            codec text,
            has_cover integer not null default 0,
            size integer not null,
            mtime integer not null,
            created_at integer not null,
            unique(library_id, rel_path)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_music_tracks_title on music_tracks(title, id)
        `.execute(db);
        await sql`
          create index if not exists idx_music_tracks_album on music_tracks(album, track_no)
        `.execute(db);
        await sql`
          create index if not exists idx_music_tracks_artist on music_tracks(artist, title)
        `.execute(db);

        await sql`
          create table if not exists music_playlists (
            id text primary key,
            name text not null,
            owner_id text not null,
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_music_playlists_owner
            on music_playlists(owner_id, created_at desc)
        `.execute(db);

        await sql`
          create table if not exists music_playlist_items (
            playlist_id text not null,
            track_id text not null,
            position integer not null,
            added_at integer not null,
            primary key (playlist_id, track_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_music_playlist_items_track
            on music_playlist_items(track_id)
        `.execute(db);
      },
    },
    {
      id: '043_music_state',
      async up(db) {
        await sql`
          create table if not exists music_favorites (
            item_id text not null,
            owner_id text not null,
            created_at integer not null,
            primary key (item_id, owner_id)
          )
        `.execute(db);
        await sql`
          create table if not exists music_plays (
            id text primary key,
            item_id text not null,
            owner_id text not null,
            played_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_music_plays_owner on music_plays(owner_id, played_at desc)
        `.execute(db);
      },
    },
    {
      id: '090_music_plays_item_idx',
      async up(db) {
        // 自动歌单（未听过 / 最常听）都在按 (owner_id, item_id) 点查：
        //   `where not exists (select 1 from music_plays p where p.owner_id = ? and p.item_id = t.id)`
        // 只有 (owner_id, played_at) 时，索引只能定位到「这个用户的全部播放记录」，
        // 然后逐行比较 item_id —— 5 万条播放 × 1 万首歌就是 5 亿次比较。
        await sql`
          create index if not exists idx_music_plays_owner_item
            on music_plays(owner_id, item_id)
        `.execute(db);
      },
    },
    {
      id: '107_music_collections',
      async up(db) {
        // 音乐合集：**用户自建**的一组音乐目录（对齐既有实现的「音乐合集」）。
        // 曲库是全局共享的（music_libraries / music_tracks 没有 owner），
        // 合集跟歌单、收藏一样按 owner 隔离 —— 每个人整理自己的那一套。
        await sql`
          create table if not exists music_collections (
            id text primary key,
            owner_id text not null,
            name text not null,
            paths text not null,
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_music_collections_owner
            on music_collections(owner_id, created_at desc)
        `.execute(db);
      },
    },
    {
      id: '158_music_library_scan_policy',
      async up(db) {
        // 来源页上的三个开关以前是客户端自言自语：服务端没有列，`source/list`
        // 直接硬编码返回 scan_when_start=1 / scan_when_change=1 / scan_interval=0，
        // `source/update` 又只认 path —— 点一下开关弹回去还报「操作失败」。
        // 现在落成真列：启动时扫描 / 有变动时扫描 / 每库独立的间隔扫描。
        const info = await sql<{ name: string }>`pragma table_info(music_libraries)`.execute(db);
        const have = new Set(info.rows.map((r) => r.name));
        if (!have.has('scan_when_start')) {
          await sql`alter table music_libraries add column scan_when_start integer not null default 1`.execute(db);
        }
        if (!have.has('scan_when_change')) {
          await sql`alter table music_libraries add column scan_when_change integer not null default 1`.execute(db);
        }
        if (!have.has('scan_interval_ms')) {
          await sql`alter table music_libraries add column scan_interval_ms integer not null default 0`.execute(db);
        }
      },
    },
    {
      // 收藏表的主键列序反了。
      //
      // 旧定义 `primary key (item_id, owner_id)`：所有查询都是
      //     select ... where owner_id = ?
      // 而联合主键只有在**前缀列**上才能当索引用，owner_id 排在第二 ⇒ 全表扫。
      // 现在收藏量还小看不出来，但这张表会随曲库增长，且「收藏页 / 星标状态 / 兼容层
      // exists 子查询」三处都吃这个索引，属于典型的高频低效点。
      //
      // SQLite 改不了主键，只能重建表。数据全量搬过去，再把旧表丢掉。
      id: '162_music_favorites_owner_first',
      async up(db) {
        await sql`
          create table if not exists music_favorites_new (
            owner_id text not null,
            item_id text not null,
            created_at integer not null,
            primary key (owner_id, item_id)
          )
        `.execute(db);
        await sql`
          insert or ignore into music_favorites_new (owner_id, item_id, created_at)
            select owner_id, item_id, created_at from music_favorites
        `.execute(db);
        await sql`drop table if exists ${sql.table('music_favorites')}`.execute(db);
        await sql`alter table music_favorites_new rename to music_favorites`.execute(db);
        // 收藏页是「我的收藏，按收藏时间倒序」—— 补一条 (owner, created_at) 让排序也走索引
        await sql`
          create index if not exists idx_music_favorites_owner_time
            on music_favorites (owner_id, created_at desc)
        `.execute(db);
      },
    },
    {
      // 书库归属统一：`photo_libraries` 有 `owner_id`，`music_libraries` / `video_libraries`
      // 一直没有 —— 三张同构的表，只有一张能按用户隔离，另一个项目成员很容易以为
      // 另外两张也有，写出来的过滤条件静默失效（恒为真，等于不隔离）。
      //
      // ⚠️ 语义保持「NULL = 所有人可见」：**不加 NOT NULL、不回填**。
      // 音乐/视频库在家庭场景是共享资源，一加过滤就会让其他成员看不见库；
      // 所以这一版只统一列，不改变任何现有行为的可见性。
      // 将来要做「私有曲库」时，把 owner_id 填上并在查询里加
      //   and (owner_id is null or owner_id = ?)
      // 即可，不需要再改表。
      id: '163_music_library_owner',
      async up(db) {
        const info = await sql<{ name: string }>`pragma table_info(music_libraries)`.execute(db);
        if (!info.rows.some((r) => r.name === 'owner_id')) {
          await sql`alter table music_libraries add column owner_id text`.execute(db);
        }
        await sql`
          create index if not exists idx_music_libraries_owner
            on music_libraries (owner_id)
        `.execute(db);
      },
    },
    {
      // 音乐模块的键值设置 + 在线热度缓存。
      //
      // `music_settings`：目前只有 Last.fm 的 API Key（用户自己在设置页填）。
      // 单独一张表而不是复用 system settings：音乐库是全局共享的，key 也属于
      // 曲库级配置，跟某个用户的偏好无关。
      //
      // `music_lastfm_cache`：Last.fm 按 IP 限流，短时间高频并发会被临时封；
      // 歌手热门按 7 天、专辑热度按 24 小时落库缓存，失败不写（下次自动重试）。
      id: '170_music_settings_lastfm',
      async up(db) {
        await sql`
          create table if not exists music_settings (
            key text primary key,
            value text not null default '',
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists music_lastfm_cache (
            key text primary key,
            payload text not null,
            fetched_at integer not null
          )
        `.execute(db);
        // 每个用户绑定的 Last.fm 账号（session key 是长期凭证，按 owner 一行）。
        // 曲库本身是共享的，但「谁的听歌记录」是私人的，所以这张表带 owner_id。
        await sql`
          create table if not exists music_lastfm_accounts (
            owner_id text primary key,
            session_key text not null,
            username text not null default '',
            updated_at integer not null
          )
        `.execute(db);
      },
    },
];
