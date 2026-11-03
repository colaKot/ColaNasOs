import { sql } from 'kysely';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, newId } from '../util';
import { deletePhotosPermanently } from '../delete';
import type { PhotoHelpers } from '../helpers';

/**
 * 批量删除。两种去向：
 *   - `toTrash: true` → 移入回收站（保留 30 天，可恢复）；
 *   - `toTrash: false` → 永久删除索引与派生数据（场景/活动/OCR/向量/人脸/相册·集合成员），
 *     磁盘原图保留（与「清空回收站只删索引」的既有口径一致）。
 */
export async function registerPhotoDelete(
  app: FastifyInstance,
  k: KernelApi,
  h: PhotoHelpers,
): Promise<void> {
  app.post(
    '/api/v1/photo/delete',
    secured('photo:write', {
      schema: {
        operationId: 'photoDelete',
        tags: TAG,
        summary: '批量删除（可选放入回收站）',
        body: h.ref('PhotoDeleteBody'),
        response: {
          200: h.ref('PhotoDeleteResponse'),
          400: h.ref('PhotoErrorResponse'),
        },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { ids?: string[]; toTrash?: boolean };
      const ids = [...new Set((body.ids || []).map((x) => String(x)).filter(Boolean))].slice(0, 500);
      if (ids.length === 0) {
        return reply.code(400).send({ error: Err.badRequest, message: 'ids required' });
      }
      const owner = String((req as any).user?.sub || '');

      if (body.toTrash === true) {
        const ts = Math.floor(Date.now() / 1000);
        const batchId = newId();
        const list = sql.join(
          ids.map((id) => sql`${id}`),
          sql`, `,
        );
        // 一次删除 = 一个批次：回收站据此分组，用户可以整批还原或整批清空。
        // 批次只在真的改动了行之后落库，避免空操作留下一堆空批次。
        const count = await k.db.transaction().execute(async (trx: any) => {
          const res = await sql`
            update photo_items set in_trash = 1, deleted_at = ${ts}, delete_batch_id = ${batchId}
             where id in (${list})
               and library_id in (select id from photo_libraries where owner_id = ${owner})
          `.execute(trx);
          const n = Number(res.numAffectedRows || 0);
          if (n > 0) {
            await sql`
              insert into photo_delete_batches (id, owner_id, kind, item_count, created_at)
              values (${batchId}, ${owner}, 'delete', ${n}, ${ts})
            `.execute(trx);
          }
          return n;
        });
        return { count, trashed: true, batchId: count > 0 ? batchId : null };
      }

      const count = await deletePhotosPermanently(k, owner, ids);
      return { count, trashed: false, batchId: null };
    },
  );
}