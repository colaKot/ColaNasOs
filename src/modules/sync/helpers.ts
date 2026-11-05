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

    const loadTask = async (req: FastifyRequest, id: string): Promise<SyncTaskRow | null> => {
      const rows = (
        await sql<SyncTaskRow>`
          select * from sync_tasks where id = ${id} and uid = ${uidOf(req)}
        `.execute(k.db)
      ).rows;
      return rows[0] ?? null;
    };
  return { now, roots, uidOf, loadTask };
}

export type SyncHelpers = ReturnType<typeof makeSyncHelpers>;
