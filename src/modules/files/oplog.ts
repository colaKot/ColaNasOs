import crypto from 'node:crypto';
import { sql } from 'kysely';

/**
 * 文件操作日志（U-F 余）。
 *
 * 此前只有登录记录与账号审计，文件域的上传 / 下载 / 删除 / 移动没有统一台账，
 * 出问题只能翻服务日志。这里落一张 `file_op_logs`，写入口统一走 `writeOpLogs`：
 * - 记录**谁**（uid / username / ip）在**什么时候**对**哪个路径**做了什么；
 * - 批量操作逐条记：成功一条、失败一条（带错误原因），不把整批糊成一条；
 * - 写日志失败**绝不阻断业务**（磁盘满 / 库锁住时业务仍应完成）。
 */

export type OpAction =
  | 'mkdir'
  | 'rename'
  | 'move'
  | 'copy'
  | 'upload'
  | 'download'
  | 'trash'
  | 'delete'
  | 'restore'
  | 'empty';

export type OpStatus = 'ok' | 'failed';

export interface OpEntry {
  action: OpAction;
  status: OpStatus;
  path: string;
  detail?: string;
}

export interface OpActor {
  uid: string;
  username: string;
  ip: string;
}

export interface OpLogQuery {
  uid?: string;
  action?: string;
  status?: string;
  q?: string;
  limit?: string | number;
  offset?: string | number;
}

/** 单次请求最多写多少条：批量删 500 条时正好够，再多就截断 */
const MAX_ENTRIES = 500;

const now = (): number => Math.floor(Date.now() / 1000);

/** 解析操作者：uid 来自 JWT；username 查账号表（dev-token 用户可能不在表里） */
export async function resolveActor(
  db: any,
  req: { user?: { sub?: string }; ip?: string },
): Promise<OpActor> {
  const uid = String(req.user?.sub || '');
  let username = '';
  if (uid) {
    try {
      const res = await sql<{ username: string }>`
        select username from auth_users where id = ${uid}
      `.execute(db);
      username = String(res.rows[0]?.username || '');
    } catch {
      /* 旧库没有 auth_users 时忽略 */
    }
  }
  return { uid, username, ip: String(req.ip || '') };
}

/** 批量写日志；失败静默（审计不能反过来弄挂业务） */
export async function writeOpLogs(
  db: any,
  actor: OpActor,
  entries: OpEntry[],
): Promise<void> {
  const rows = entries
    .filter((e) => e && e.action)
    .slice(0, MAX_ENTRIES)
    .map((e) => ({
      action: String(e.action),
      status: e.status === 'failed' ? 'failed' : 'ok',
      path: String(e.path || '').slice(0, 1000),
      detail: String(e.detail || '').slice(0, 1000),
    }));
  if (rows.length === 0) return;
  try {
    for (const row of rows) {
      await sql`
        insert into file_op_logs (id, uid, username, action, status, path, detail, ip, created_at)
        values (${crypto.randomBytes(8).toString('base64url')}, ${actor.uid}, ${actor.username},
                ${row.action}, ${row.status}, ${row.path}, ${row.detail}, ${actor.ip}, ${now()})
      `.execute(db);
    }
  } catch {
    /* 日志失败不阻断文件操作 */
  }
}


function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(Math.trunc(n), max));
}

/** GET /files/op-logs —— 按用户 / 类型 / 状态 / 关键词过滤，时间倒序 + 分页 */
export async function opLogListHandler(
  db: any,
  query: OpLogQuery,
): Promise<{
  items: Array<{
    id: string;
    uid: string;
    username: string;
    action: string;
    status: string;
    path: string;
    detail: string;
    ip: string;
    createdAt: number;
  }>;
  total: number;
  limit: number;
  offset: number;
}> {
  const limit = clampInt(query.limit, 1, 200, 50);
  const offset = clampInt(query.offset, 0, 1_000_000, 0);
  const uid = String(query.uid || '').trim();
  const action = String(query.action || '').trim();
  const status = String(query.status || '').trim();
  const q = String(query.q || '').trim();
  // 用 instr 而不是 LIKE：用户输入里的 % / _ 是字面量，不需要 ESCAPE（SQLite 的
  // ESCAPE 只接受单字符，模板里拼 `'\'` 会被转义成两个反斜杠直接报错）。
  const needle = q.toLowerCase();

  const where = sql`
    where 1 = 1
      ${uid ? sql`and uid = ${uid}` : sql``}
      ${action ? sql`and action = ${action}` : sql``}
      ${status ? sql`and status = ${status}` : sql``}
      ${
        q
          ? sql`and (instr(lower(path), ${needle}) > 0
                   or instr(lower(detail), ${needle}) > 0
                   or instr(lower(username), ${needle}) > 0)`
          : sql``
      }
  `;

  const rows = (
    await sql<any>`
      select id, uid, username, action, status, path, detail, ip, created_at
        from file_op_logs
        ${where}
       order by created_at desc, id desc
       limit ${limit} offset ${offset}
    `.execute(db)
  ).rows;

  const countRows = (
    await sql<{ n: number }>`select count(*) as n from file_op_logs ${where}`.execute(db)
  ).rows;

  return {
    items: rows.map((r) => ({
      id: String(r.id),
      uid: String(r.uid || ''),
      username: String(r.username || ''),
      action: String(r.action || ''),
      status: String(r.status || ''),
      path: String(r.path || ''),
      detail: String(r.detail || ''),
      ip: String(r.ip || ''),
      createdAt: Number(r.created_at) || 0,
    })),
    total: Number(countRows[0]?.n || 0),
    limit,
    offset,
  };
}