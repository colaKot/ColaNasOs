import { sql } from 'kysely';
import type { Migration } from '../migrator';

/** 内核自带的基础迁移（不属于任何域模块，但同样受顺序清单约束） */
export const BASE_MIGRATIONS: Migration[] = [
  {
    id: '001_config',
    async up(db) {
      await sql`
        create table if not exists config (
          key text primary key,
          value text not null,
          updated_at integer not null
        )
      `.execute(db);
    },
  },
  {
    id: '160_drop_removed_modules',
    async up(db) {
      // 六个模块（书房 / 笔记 / 挂载 / 分享 / 安全 / 消息）已经整块移除：
      // 客户端页面、服务端模块、契约、文案都没了，这些表不再有任何读写方。
      // 留着它们只会让人以为功能还在，所以一并清掉。
      //
      // 顺序：先子表后主表（SQLite 不强制外键，但读起来要对得上）；
      // 全部 `if exists`——从未建过这些表的库（新装 / 早先就没升级到那个版本）不该报错。
      const childTables = [
        'book_list_items',
        'book_favorites',
        'book_progress',
        'book_archived',
        'book_user_collections',
        'book_history',
        'book_libraries',
        'note_versions',
        'vault_items',
      ];
      const rootTables = [
        'book_lists',
        'books',
        'notes',
        'remote_mounts',
        'share_links',
        'backup_jobs',
        'vaults',
        'app_messages',
      ];
      for (const table of [...childTables, ...rootTables]) {
        await sql`drop table if exists ${sql.table(table)}`.execute(db);
      }

      // FTS5 虚拟表：drop 主表会连带清掉 book_search_data / _idx / _content /
      // _docsize / _config 这些影子表，不需要逐个处理。
      await sql`drop table if exists ${sql.table('book_search')}`.execute(db);

      // 把这批迁移的执行记录也清掉。
      //
      // 为什么必须清：只 drop 表而留记录，日后若把模块代码从 git 恢复回来，
      // 迁移器会认为「已经跑过」而跳过建表 —— 表不存在，功能一启动就炸。
      // 清掉记录后恢复代码即可自愈：迁移重跑，建回空表。
      const retired = [
        '001_share_links',
        '002_backup_jobs',
        '003_vaults',
        '008_messages',
        '009_notes',
        '033_book',
        '034_remote_mounts',
        '037_book_organize',
        '042_book_fulltext',
        '077_notes_version',
        '108_book_type_history',
        '109_book_scan_schedule',
      ];
      for (const id of retired) {
        await sql`delete from _migrations where id = ${id}`.execute(db);
      }
    },
  },
  {
    id: '168_drop_media_tool',
    async up(db) {
      // 媒体工具整块移除：批量缩略图 / 音频转写 / 图片压缩 / 视频转码这些批处理能力
      // 是照搬来的，实际没人用（真库两张表都是 0 行），留着只增加维护面。
      //
      // 与 160 同理：drop 表 + 清迁移记录，日后从 git 恢复代码可自愈。
      await sql`drop table if exists ${sql.table('media_tool_tasks')}`.execute(db);
      await sql`drop table if exists ${sql.table('media_tool_jobs')}`.execute(db);

      for (const id of ['040_media_tool', '097_media_tool_tasks']) {
        await sql`delete from _migrations where id = ${id}`.execute(db);
      }
    },
  },
];