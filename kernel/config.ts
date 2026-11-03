import { sql } from 'kysely';

/** 键值配置（内存缓存 + SQLite 持久化） */
export interface ConfigStore {
  get<T = unknown>(key: string): T | undefined;
  set(key: string, value: unknown): Promise<void>;
  all(): Record<string, unknown>;
}

export async function createConfig(db: any): Promise<ConfigStore> {
  await sql`
    create table if not exists config (
      key text primary key,
      value text not null,
      updated_at integer not null
    )
  `.execute(db);

  const cache = new Map<string, unknown>();
  const rows = (await sql`select key, value from config`.execute(db)).rows as Array<{
    key: string;
    value: string;
  }>;

  for (const r of rows) {
    try {
      cache.set(r.key, JSON.parse(r.value));
    } catch {
      /* 损坏的单条配置不影响启动 */
    }
  }

  return {
    get<T>(key: string): T | undefined {
      return cache.get(key) as T | undefined;
    },
    async set(key: string, value: unknown): Promise<void> {
      cache.set(key, value);
      const v = JSON.stringify(value ?? null);
      const now = Date.now();
      await sql`
        insert into config (key, value, updated_at) values (${key}, ${v}, ${now})
        on conflict(key) do update set value = ${v}, updated_at = ${now}
      `.execute(db);
    },
    all(): Record<string, unknown> {
      return Object.fromEntries(cache);
    },
  };
}
