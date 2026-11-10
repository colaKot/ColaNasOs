import { sql } from 'kysely';
import type { Migration } from '../../../kernel/migrator';

/**
 * 传输会话：把「谁、在哪一端、传什么、传到哪」落成一行。
 *
 * 为什么单独建表而不是复用 `file_op_logs`：操作日志是**事后审计**（只记成功/失败），
 * 传输中心要的是**事前可见**——正在传的文件也要能在别的设备上看到进度。
 *
 * 为什么不用 `tasks` 任务队列：那套是服务端自己跑的活（扫描 / 刮削 / 转码），
 * worker 会 claim 并执行；上传是客户端推字节，服务端只是接收方，没有活可干。
 */
export const TRANSFER_MIGRATIONS: Migration[] = [
  {
    id: '159_transfer_sessions',
    async up(db) {
      await sql`
        create table if not exists transfer_sessions (
          id text primary key,
          owner text not null,
          direction text not null,
          path text not null,
          name text not null default '',
          size integer not null default 0,
          transferred integer not null default 0,
          total_chunks integer not null default 0,
          done_chunks text not null default '[]',
          state text not null default 'active',
          origin text not null default '',
          device text not null default '',
          error text,
          created_at integer not null,
          updated_at integer not null,
          finished_at integer
        )
      `.execute(db);

      // 面板默认按「最近的在前」翻页；state 用来筛进行中 / 已完成。
      await sql`
        create index if not exists idx_transfer_state_updated
        on transfer_sessions (state, updated_at desc)
      `.execute(db);

      // 同一用户对同一路径只保留一条「活跃」会话：重复点上传不会刷出一排重复行。
      // 部分索引（where）避免历史记录也撞唯一键。
      await sql`
        create unique index if not exists uniq_transfer_active
        on transfer_sessions (owner, direction, path)
        where state in ('pending', 'active', 'paused')
      `.execute(db);
    },
  },
];
