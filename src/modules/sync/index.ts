import type { ServerModule } from '../../../kernel/types';

import { SYNC_MIGRATIONS } from './migrations';
import { makeSyncHelpers } from './helpers';
import { registerSyncJobs } from './routes/jobs';
import { registerSyncTasks } from './routes/tasks';

/**
 * SP3-12 sync（p2p / remote 已随 service 取消，这里只做同步任务本体）。
 *
 *   POST /api/v1/sync/run               执行一次同步（merge 语义，不删除目标多余文件）
 *   GET  /api/v1/sync/jobs              任务历史
 *   GET  /api/v1/sync/diff              只读差异预览
 *   GET  /api/v1/sync/conflicts         冲突列表
 *   POST /api/v1/sync/conflicts/resolve 冲突裁决（source / target）
 *
 * 冲突策略：overwrite（源覆盖）/ skip（记录冲突，目标不动）/ rename（目标改名为 *.conflict-<ts>）
 * 断点续传：本模块按文件粒度记录进度，跨设备大文件续传复用 files 的分片上传。
 */
export const sync: ServerModule = {
  id: 'sync',
  prefix: '/api/v1/sync',
  permissions: ['sync:read', 'sync:write'],

  migrations: SYNC_MIGRATIONS,

  async register(app, k) {

    const h = makeSyncHelpers(k);
    await registerSyncJobs(app, k, h);
    await registerSyncTasks(app, k, h);
  },
};
