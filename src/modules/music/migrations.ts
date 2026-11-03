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
];
