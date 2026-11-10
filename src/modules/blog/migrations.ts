import { sql } from 'kysely';
import type { Migration } from '../../../kernel/migrator';

/**
 * blog（AI 播客）表结构。
 *
 * `blog_settings` 固定一行（id = 1）：读的时候不用处理"多条取哪条"，
 * 写的时候 upsert，避免半保存状态。
 *
 * `blog_episodes` 的一期 = 一个 mp3 + 一份稿件 + 本期新闻清单。
 * 进度（parts / done_parts）落库而不是放内存：生成要几分钟，
 * 前端轮询、甚至进程重启后都要能看见「卡在哪一步」。
 */
export const BLOG_MIGRATIONS: Migration[] = [
  {
    id: '148_blog_episode_news',
    async up(db) {
      // 本期素材清单（标题 / 原文链接 / 来源 / 分类）：文稿弹窗底部要列引用链接。
      // 老期次是空数组，接口会用 headlines_json 兜底成「只有标题、没有链接」的条目。
      await sql`
        alter table blog_episodes add column news_json text not null default '[]'
      `.execute(db);
    },
  },
  {
    id: '145_blog_llm_usage',
    async up(db) {
      // 每期节目的云端模型用量：出账后能直接按 episode_id 对账，不用再猜「钱花在哪」。
      // 兼容重发（400 后剥参数）单独计数，它只影响请求次数不影响 token。
      await sql`
        create table if not exists blog_llm_usage (
          episode_id text primary key,
          model text not null default '',
          calls integer not null default 0,
          prompt_tokens integer not null default 0,
          completion_tokens integer not null default 0,
          total_tokens integer not null default 0,
          search_calls integer not null default 0,
          compat_retries integer not null default 0,
          created_at integer not null
        )
      `.execute(db);
    },
  },
  {
    id: '144_blog_translations',
    async up(db) {
      // 英文素材的本地翻译缓存：同一条新闻（link + title 哈希）只翻一次。
      // 不做 TTL：新闻标题与摘要不会变，模型换了也没必要重翻（旧译文仍然可用）。
      await sql`
        create table if not exists blog_translations (
          hash text primary key,
          title text not null,
          summary text not null default '',
          model text not null default '',
          created_at integer not null
        )
      `.execute(db);
    },
  },
  {
    id: '143_blog_tts_engine',
    async up(db) {
      // 合成引擎：local = 本地 Kokoro（离线，慢），edge = 微软在线（快，需联网）
      await sql`
        alter table blog_settings add column tts_engine text not null default 'local'
      `.execute(db);
    },
  },
  {
    id: '142_blog',
    async up(db) {
      await sql`
        create table if not exists blog_settings (
          id integer primary key check (id = 1),
          voice text not null default 'default',
          speed real not null default 1.0,
          counts_json text not null default '{}',
          plan_hour integer not null default 4,
          plan_minute integer not null default 0,
          plan_enabled integer not null default 1,
          api_provider text not null default 'deepseek',
          api_key text not null default '',
          api_base text not null default 'https://api.deepseek.com',
          api_model text not null default 'deepseek-flash',
          last_plan_date text,
          updated_at integer not null default 0
        )
      `.execute(db);

      await sql`
        create table if not exists blog_episodes (
          id text primary key,
          title text not null,
          voice text not null,
          speed real not null,
          duration_sec real not null default 0,
          size_bytes integer not null default 0,
          item_count integer not null default 0,
          parts integer not null default 0,
          done_parts integer not null default 0,
          status text not null default 'pending',
          error text,
          script text not null default '',
          sections_json text not null default '[]',
          headlines_json text not null default '[]',
          created_at integer not null,
          finished_at integer
        )
      `.execute(db);
      await sql`
        create index if not exists idx_blog_episodes_created on blog_episodes (created_at desc)
      `.execute(db);
    },
  },
];
