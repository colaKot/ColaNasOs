import type { FastifyInstance } from 'fastify';
import { secured } from '../../../../kernel/route';
import type { KernelApi } from '../../../../kernel/types';
import type { LibraryWatch } from '../../library-watch';
import type { PhotoHelpers } from '../helpers';
import { TAG } from '../util';
import { PHOTO_SCAN_POLICY_KEY, readPhotoScanPolicy, type PhotoScanPolicy } from '../scan-policy';

/**
 * 相册扫描策略：三个开关（自动监视 / 周期校验 / 跳过隐藏文件）。
 *
 * 改动后会调用 `libWatch.refresh()`，让「退订 / 重订」与周期校验定时器立即按新策略重建。
 */
export async function registerPhotoScanPolicy(
  app: FastifyInstance,
  k: KernelApi,
  h: PhotoHelpers,
  libWatch: LibraryWatch,
): Promise<void> {
  app.get(
    '/api/v1/photo/scan-policy',
    secured('photo:read', {
      schema: {
        operationId: 'photoScanPolicy',
        tags: TAG,
        summary: '相册扫描策略（自动监视 / 周期校验 / 跳过隐藏文件）',
        response: { 200: h.ref('PhotoScanPolicy') },
      },
    }),
    async () => readPhotoScanPolicy(k),
  );

  app.post(
    '/api/v1/photo/scan-policy',
    secured('photo:write', {
      schema: {
        operationId: 'photoScanPolicySet',
        tags: TAG,
        summary: '更新相册扫描策略（立即生效）',
        body: h.ref('PhotoScanPolicyUpdateBody'),
        response: { 200: h.ref('PhotoScanPolicy') },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as Partial<PhotoScanPolicy>;
      const current = readPhotoScanPolicy(k);
      const next: PhotoScanPolicy = {
        autoWatch: typeof body.autoWatch === 'boolean' ? body.autoWatch : current.autoWatch,
        verifyHours:
          body.verifyHours === undefined
            ? current.verifyHours
            : Math.max(0, Math.min(168, Math.trunc(Number(body.verifyHours) || 0))),
        skipHidden: typeof body.skipHidden === 'boolean' ? body.skipHidden : current.skipHidden,
      };
      await k.config.set(PHOTO_SCAN_POLICY_KEY, next);
      await libWatch.refresh();
      return next;
    },
  );
}