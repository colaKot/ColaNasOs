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
];