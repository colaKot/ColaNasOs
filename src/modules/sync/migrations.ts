import path from 'node:path';
import { sql } from 'kysely';
import type { Migration } from '../../../kernel/migrator';

export const SYNC_MIGRATIONS: Migration[] = [
    {
      id: '005_sync_jobs',
      async up(db) {
        await sql`
          create table if not exists sync_jobs (
            id text primary key,
            source text not null,
            target text not null,
            policy text not null default 'skip',
            copied integer not null default 0,
            skipped integer not null default 0,
            conflicts integer not null default 0,
            bytes integer not null default 0,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists sync_conflicts (
            id text primary key,
            job_id text not null,
            path text not null,
            created_at integer not null,
            resolved integer not null default 0,
            resolution text
          )
        `.execute(db);
      },
    },
    {
      id: '061_sync_v2',
      async up(db) {
        await sql`
          create table if not exists sync_tasks (
            id text primary key,
            uid text not null default '',
            device_id text not null,
            device_name text not null default '',
            mode text not null default 'bidirectional',
            status text not null default 'idle',
            local_dir text not null,
            remote_dir text not null,
            include_json text not null default '[]',
            exclude_json text not null default '[]',
            created_at integer not null,
            updated_at integer not null,
            last_run_at integer,
            last_error text
          )
        `.execute(db);
        await sql`
          create table if not exists sync_baseline (
            task_id text not null,
            rel_path text not null,
            size integer not null,
            mtime_ms integer not null,
            updated_at integer not null,
            primary key (task_id, rel_path)
          )
        `.execute(db);
        await sql`
          create table if not exists sync_runs (
            id text primary key,
            task_id text not null,
            started_at integer not null,
            finished_at integer not null,
            status text not null,
            uploaded integer not null default 0,
            downloaded integer not null default 0,
            deleted_local integer not null default 0,
            deleted_remote integer not null default 0,
            skipped integer not null default 0,
            conflicts integer not null default 0,
            bytes integer not null default 0,
            detail_json text
          )
        `.execute(db);
        await sql`
          create index if not exists idx_sync_runs_task
          on sync_runs (task_id, finished_at desc)
        `.execute(db);
        await sql`
          create index if not exists idx_sync_tasks_uid
          on sync_tasks (uid, updated_at desc)
        `.execute(db);
      },
    },
    {
      id: '095_sync_task_name',
      async up(db) {
        // 1:1：任务必须有名字，同设备多任务才分得清；老任务回退显示设备名
        await sql`
          alter table sync_tasks add column name text not null default ''
        `.execute(db);
      },
    },
    {
      id: '096_sync_task_config',
      async up(db) {
        // 结构化过滤（大小 / 隐藏文件 / 扩展名）与任务策略（按需/间隔/冲突/删除传播）
        await sql`
          alter table sync_tasks add column filter_json text not null default '{}'
        `.execute(db);
        await sql`
          alter table sync_tasks add column sync_json text not null default '{}'
        `.execute(db);
      },
    },
];
