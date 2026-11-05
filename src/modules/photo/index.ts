import { sql } from 'kysely';
import type { ServerModule } from '../../../kernel/types';
import { PHOTO_SCHEMAS } from './schemas';
import { registerPhotoAi } from './ai';
import { enqueueScanOnce } from './ai/vision';
import { registerPhotoBackup } from './backup';
import { registerPhotoCleanup } from './curation';
import { registerPhotoMap } from './map';
import { registerPhotoMemories } from './memories';
import { registerPhotoRetrieval } from './retrieval';
import { scanLibrary, type LibraryRow } from './scan';
import { isImageFile } from './exif';
import { bindLibraryWatch } from '../library-watch';
import { registerExtraRoot } from '../files/fs-root';

import { PHOTO_MIGRATIONS } from './migrations';
import { makePhotoHelpers } from './helpers';
import { registerPhotoLibrary } from './routes/library';
import { registerPhotoTimeline } from './routes/timeline';
import { registerPhotoAlbums } from './routes/albums';
import { registerPhotoCollections } from './routes/collections';
import { registerPhotoSmartRules } from './routes/smart-rules';
import { registerPhotoDelete } from './routes/delete';
import { purgeExpiredTrash } from './delete';
import { registerPhotoGeo } from './routes/geo';
import { registerPhotoHome } from './routes/home';
import { registerPhotoMcp } from './mcp';
import { registerPhotoPhash } from './phash';
import { registerPhotoScanPolicy } from './routes/scan-policy';
import { shouldSkipName, watchPolicyOf } from './scan-policy';
import { registerPhotoUpload } from './routes/upload';
import { registerPhotoMapTile } from './routes/map-tile';

/**
 * SP3-02 photo：库 / 时间轴 / 搜索 / 相册（一期）。
 *
 *   POST /api/v1/photo/libraries        新建库（指向 files 根内的目录）
 *   GET  /api/v1/photo/libraries        库列表
 *   POST /api/v1/photo/libraries/remove 删除库（级联清理索引与相册成员）
 *   POST /api/v1/photo/scan             扫描索引（缺省扫描全部库）
 *   GET  /api/v1/photo/timeline         时间轴（taken_at 倒序，排序键 cursor）
 *   GET  /api/v1/photo/item             单张详情
 *   GET  /api/v1/photo/search           关键词 + 时间范围
 *   GET  /api/v1/photo/stats            总量与时间跨度
 *   POST /api/v1/photo/albums           新建相册
 *   GET  /api/v1/photo/albums           相册列表
 *   GET  /api/v1/photo/albums/items     相册成员（时间轴序）
 *   POST /api/v1/photo/albums/add       加入成员
 *   POST /api/v1/photo/albums/remove    移出成员
 *   POST /api/v1/photo/albums/delete    删除相册
 *
 * 人脸 / 场景 / 活动 / 地图 / 语义搜索 / 以图搜图 / 重复照片 依赖 AI 与向量库，
 * 属后续批次；一期先保证「库 → 索引 → 时间轴 / 相册 / 搜索」闭环。
 */
export const photo: ServerModule = {
  id: 'photo',
  prefix: '/api/v1/photo',
  permissions: ['photo:read', 'photo:write'],

  migrations: PHOTO_MIGRATIONS,

  async register(app, k) {
    for (const schema of PHOTO_SCHEMAS) app.addSchema(schema);
    // 相册来源可以是任意本机目录：启动时恢复已登记的绝对来源根，
    // 否则重启后的缩略图 / AI 识别会把绝对路径判成越界（403）。
    const libs = await sql<{ root_path: string }>`
  select distinct root_path from photo_libraries where root_path <> ''
`.execute(k.db);
    for (const r of libs.rows) {
      if (/^[a-zA-Z]:[\\/]/.test(r.root_path) || r.root_path.startsWith('\\\\')) {
        registerExtraRoot(r.root_path);
      }
    }

    const libWatch = bindLibraryWatch<LibraryRow>({
      k,
      domain: 'photo',
      load: async () => (await sql<LibraryRow>`select * from photo_libraries`.execute(k.db)).rows,
      scan: (lib, subDir) => scanLibrary(k.db, lib, undefined, subDir),
      accept: (name) => isImageFile(name) && !shouldSkipName(k, name),
      policy: () => watchPolicyOf(k),
    });
    await registerPhotoAi(app, k);
    await registerPhotoMap(app, k);
    await registerPhotoRetrieval(app, k);
    await registerPhotoCleanup(app, k);
    await registerPhotoMemories(app, k);
    await registerPhotoBackup(app, k);
    const h = makePhotoHelpers(k, libWatch);
    await registerPhotoLibrary(app, k, h);
    await registerPhotoTimeline(app, k, h);
    await registerPhotoAlbums(app, k, h);
    await registerPhotoCollections(app, k, h);
    await registerPhotoSmartRules(app, k, h);
    await registerPhotoGeo(app, k, h);
    await registerPhotoHome(app, k, h);
    await registerPhotoMcp(app, k);
    await registerPhotoPhash(app, k);
    await registerPhotoScanPolicy(app, k, h, libWatch);
    await registerPhotoUpload(app, k);
    await registerPhotoMapTile(app, k);
    await registerPhotoDelete(app, k, h);

    // 重启后自动接着识别：还有没识别的照片就入队一次。
    // 开关关着 / 已暂停 / 已经全部识别完 都直接跳过（判断在 enqueueScanOnce 里）。
    void enqueueScanOnce(k).catch(() => null);

    // 回收站保留 30 天：启动先清一次，之后每小时一次（unref 不阻止进程退出）
    void purgeExpiredTrash(k).catch(() => null);
    const purgeTimer = setInterval(() => {
      void purgeExpiredTrash(k).catch(() => null);
    }, 3600_000);
    purgeTimer.unref?.();
  },
};
