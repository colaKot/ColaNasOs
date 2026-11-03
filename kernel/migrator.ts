import { sql } from 'kysely';
import { checkMigrationOrder, orderMigrations } from './migrations/manifest';

export interface Migration {
  id: string;
  up(db: any): Promise<void>;
}

/**
 * 版本化迁移：
 * - 传入 `order`（顺序清单）时，**严格按清单顺序执行**；清单外的迁移直接抛错（响亮失败）
 * - 未传 `order` 时退化为按 id 字典序（仅供单测/临时库使用）
 * - **每个迁移在独立事务中执行**，失败整体回滚（含 `_migrations` 记录）
 * - 不做 DDL 回滚：SQLite 的 DDL 回滚不可靠
 */
export class Migrator {
  constructor(private readonly db: any) {}

  private async ensureTable(): Promise<void> {
    await sql`
      create table if not exists _migrations (
        id text primary key,
        applied_at integer not null
      )
    `.execute(this.db);
  }

  /** 只计算、不执行：给 `migrate status / verify / up --dry-run` 用 */
  async plan(
    migrations: Migration[],
    order?: readonly string[],
  ): Promise<{ pending: string[]; applied: string[]; unregistered: string[]; missing: string[] }> {
    await this.ensureTable();
    const rows = (await sql`select id from _migrations`.execute(this.db)).rows as Array<{
      id: string;
    }>;
    const applied = rows.map((r) => r.id);
    const done = new Set(applied);

    if (order) {
      const check = checkMigrationOrder(
        migrations.map((m) => m.id),
        order,
      );
      const ordered = orderMigrations(migrations, order);
      return {
        pending: ordered.map((m) => m.id).filter((id) => !done.has(id)),
        applied,
        unregistered: check.unregistered,
        missing: check.missing,
      };
    }

    return {
      pending: [...migrations]
        .sort((a, b) => a.id.localeCompare(b.id))
        .map((m) => m.id)
        .filter((id) => !done.has(id)),
      applied,
      unregistered: [],
      missing: [],
    };
  }

  async run(migrations: Migration[], order?: readonly string[]): Promise<string[]> {
    await this.ensureTable();

    let list: Migration[];
    if (order) {
      const check = checkMigrationOrder(
        migrations.map((m) => m.id),
        order,
      );
      if (check.unregistered.length > 0) {
        throw new Error(
          `unregistered migrations: ${check.unregistered.join(', ')} ` +
            '(add them to kernel/migrations/manifest.ts at the end of MIGRATION_ORDER)',
        );
      }
      if (check.duplicated.length > 0) {
        throw new Error(`duplicated migrations in order: ${check.duplicated.join(', ')}`);
      }
      list = orderMigrations(migrations, order);
    } else {
      list = [...migrations].sort((a, b) => a.id.localeCompare(b.id));
    }

    const rows = (await sql`select id from _migrations`.execute(this.db)).rows as Array<{
      id: string;
    }>;
    const done = new Set(rows.map((r) => r.id));
    const applied: string[] = [];

    for (const m of list) {
      if (done.has(m.id)) continue;

      await this.db.transaction().execute(async (trx: any) => {
        await m.up(trx);
        await sql`insert into _migrations (id, applied_at) values (${m.id}, ${Date.now()})`.execute(
          trx,
        );
      });

      applied.push(m.id);
    }

    return applied;
  }

  async applied(): Promise<string[]> {
    await this.ensureTable();
    const rows = (await sql`select id from _migrations order by id`.execute(this.db))
      .rows as Array<{ id: string }>;
    return rows.map((r) => r.id);
  }
}