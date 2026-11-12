import { sql } from 'kysely';
import { resolveRemoteDir } from '../files/fs-root';
import type { FastifyRequest } from 'fastify';
import { SyncTaskRow } from './util';
import type { KernelApi } from '../../../kernel/types';

/** 多端同步 register 作用域内的闭包辅助函数（原样抽出，工厂化） */
export function makeSyncHelpers(k: KernelApi) {
    const now = () => Math.floor(Date.now() / 1000);

    const roots = (body: { source?: string; target?: string }) => {
      if (!body.source || !body.target) {
        throw Object.assign(new Error('source/target required'), { code: 'E_PARAM' });
      }
      return {
        src: resolveRemoteDir(body.source),
        dst: resolveRemoteDir(body.target),
      };
    };

    const uidOf = (req: FastifyRequest) => String(req.user?.sub || '');

    /**
     * 发起请求的客户端机器标识（`x-colanas-client`）。
     *
     * 同步任务按「用户 + 机器」隔离：同一个账号在两台电脑上互不可见，
     * 但同一台机器上的主客户端与独立同步客户端算出同一个 id，共享任务。
     * 缺这个头（SDK / 老客户端 / 直接 curl）时退化成 ''，与历史数据同组，
     * 不会因为没头就看不到自己的任务。
     */
    const clientIdOf = (req: FastifyRequest) => {
      const raw = (req.headers as Record<string, unknown>)['x-colanas-client'];
      const value = Array.isArray(raw) ? String(raw[0] ?? '') : String(raw ?? '');
      return value.trim().slice(0, 128);
    };

    const loadTask = async (req: FastifyRequest, id: string): Promise<SyncTaskRow | null> => {
      const cid = clientIdOf(req);
      const rows = (
        await sql<SyncTaskRow>`
          select * from sync_tasks
           where id = ${id} and uid = ${uidOf(req)}
             and (client_id = ${cid} or client_id = '')
        `.execute(k.db)
      ).rows;
      if (rows[0] && !rows[0].client_id && cid) {
        // 老任务没有 client_id：谁先碰到就归谁（一次性认领），
        // 之后别的机器上的同账号就看不到它了。
        await sql`
          update sync_tasks set client_id = ${cid} where id = ${id} and client_id = ''
        `.execute(k.db);
        rows[0].client_id = cid;
      }
      return rows[0] ?? null;
    };
  return { now, roots, uidOf, clientIdOf, loadTask };
}

export type SyncHelpers = ReturnType<typeof makeSyncHelpers>;
