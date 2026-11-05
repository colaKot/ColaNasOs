import { sql } from 'kysely';
import type { Migration } from '../../../kernel/migrator';

export const BOOK_MIGRATIONS: Migration[] = [
    {
      id: '033_book',
      async up(db) {
        await sql`
          create table if not exists book_libraries (
            id text primary key,
            name text not null,
            root_path text not null unique,
            created_at integer not null,
            last_scan_at integer,
            items integer not null default 0
          )
        `.execute(db);

        await sql`
          create table if not exists books (
            id text primary key,
            library_id text not null,
            rel_path text not null,
            title text not null,
            author text,
            language text,
            publisher text,
            format text not null default '',
            page_count integer,
            has_cover integer not null default 0,
            size integer not null,
            mtime integer not null,
            created_at integer not null,
            unique(library_id, rel_path)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_books_title on books(title, id)
        `.execute(db);
        await sql`
          create index if not exists idx_books_library on books(library_id, title, id)
        `.execute(db);

        await sql`
          create table if not exists book_favorites (
            book_id text not null,
            owner_id text not null,
            created_at integer not null,
            primary key (book_id, owner_id)
          )
        `.execute(db);

        await sql`
          create table if not exists book_progress (
            book_id text not null,
            owner_id text not null,
            position text not null default '',
            percent integer not null default 0,
            updated_at integer not null,
            primary key (book_id, owner_id)
          )
        `.execute(db);
      },
    },
    {
      id: '037_book_organize',
      async up(db) {
        // 合集（书系）是书的客观属性，全局维护；归档与自定义列表按用户隔离
        await sql`alter table books add column collection text`.execute(db);
        await sql`alter table books add column collection_index integer`.execute(db);
        await sql`
          create index if not exists idx_books_collection
            on books(collection, collection_index, title, id)
        `.execute(db);

        await sql`
          create table if not exists book_archived (
            book_id text not null,
            owner_id text not null,
            created_at integer not null,
            primary key (book_id, owner_id)
          )
        `.execute(db);

        await sql`
          create table if not exists book_lists (
            id text primary key,
            name text not null,
            owner_id text not null,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create unique index if not exists idx_book_lists_name
            on book_lists(owner_id, name)
        `.execute(db);

        await sql`
          create table if not exists book_list_items (
            list_id text not null,
            book_id text not null,
            position integer not null,
            primary key (list_id, book_id)
          )
        `.execute(db);
      },
    },
    {
      id: '042_book_fulltext',
      async up(db) {
        await sql`
          create virtual table if not exists book_search using fts5(
            book_id UNINDEXED, title, author, body, tokenize='unicode61'
          )
        `.execute(db);
      },
    },
    {
      id: '108_book_type_history',
      async up(db) {
        // 落到 books 上是为了让 `select b.*` 的既有查询不用每处再 join 一次。
        await sql`alter table book_libraries add column type text not null default 'book'`.execute(db);
        await sql`alter table books add column type text not null default 'book'`.execute(db);
        await sql`
          create index if not exists idx_books_type on books(type, title, id)
        `.execute(db);

        // 阅读历史单独一张表：进度保存会写一条，清空历史不动阅读位置。
        await sql`
          create table if not exists book_history (
            id text primary key,
            book_id text not null,
            owner_id text not null,
            read_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_book_history_owner
            on book_history(owner_id, read_at desc)
        `.execute(db);

        // 用户自建合集：按目录整理（和音乐合集同一模型），按 owner 隔离。
        await sql`
          create table if not exists book_user_collections (
            id text primary key,
            owner_id text not null,
            name text not null,
            paths text not null,
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_book_user_collections_owner
            on book_user_collections(owner_id, created_at desc)
        `.execute(db);
      },
    },
    {
      id: '109_book_scan_schedule',
      async up(db) {
        // 来源级扫描策略（默认全关，保守设计；用户显式打开后才自动扫描）
        await sql`
          alter table book_libraries add column scan_when_start integer not null default 0
        `.execute(db);
        await sql`
          alter table book_libraries add column scan_when_change integer not null default 0
        `.execute(db);
        await sql`
          alter table book_libraries add column scan_interval_hours integer not null default 0
        `.execute(db);
      },
    },
];
