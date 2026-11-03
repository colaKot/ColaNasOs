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
];
