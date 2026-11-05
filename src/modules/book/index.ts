import { sql } from 'kysely';
import type { ServerModule } from '../../../kernel/types';
import { mimeOf, readBookCover, isBookFile } from './metadata';
import { BOOK_SCHEMAS } from './schemas';
import { registerBookFulltext } from './fulltext';
import { scanBookLibrary, type BookLibraryRow } from './scan';
import { bindLibraryWatch } from '../library-watch';

import { BOOK_MIGRATIONS } from './migrations';
import { makeBookHelpers } from './helpers';
import { registerBookLibrary } from './routes/library';
import { registerBookShelf } from './routes/shelf';
import { registerBookReading } from './routes/reading';
import { registerBookFavorites } from './routes/favorites';
import { registerBookCollections } from './routes/collections';
import { registerBookLists } from './routes/lists';
import { registerBookHistory } from './routes/history';
import { registerBookUserCollections } from './routes/user-collections';
import { absoluteInput, isAbsoluteInput, registerExtraRoot } from '../files/fs-root';
import { applyBookScanSchedule, scheduleStartupScan } from './schedule';

/**
 * SP3-05 book：库 / 索引 / 列表 / 搜索 / 封面 / 阅读文件 / 收藏 / 进度（一期）。
 *
 *   POST /api/v1/book/libraries        新建书库
 *   GET  /api/v1/book/libraries        书库列表
 *   POST /api/v1/book/libraries/remove 删除书库（级联清理收藏与进度）
 *   POST /api/v1/book/scan             扫描索引（epub/cbz 解析元数据）
 *   GET  /api/v1/book/list             书架（标题序 + cursor；可按格式/收藏过滤）
 *   GET  /api/v1/book/item             详情（含当前用户收藏与进度）
 *   GET  /api/v1/book/stats            书库 / 藏书 / 收藏数
 *   GET  /api/v1/book/cover            封面（epub/cbz 内嵌，懒提取 + 缓存）
 *   GET  /api/v1/book/file             阅读 / 下载（复用 files 的 Range / ETag）
 *   GET  /api/v1/book/file-url         带短期令牌的阅读地址（供外部阅读器）
 *   GET  /api/v1/book/toc              内置阅读器目录（epub spine / txt 分章 / cbz 页）
 *   GET  /api/v1/book/page             内置阅读器单页（文本或图片 base64）
 *   POST /api/v1/book/favorites/add    收藏
 *   POST /api/v1/book/favorites/remove 取消收藏
 *   GET  /api/v1/book/progress         当前用户阅读进度
 *   POST /api/v1/book/progress/save    保存阅读进度
 *
 * 合集 / 归档 / 自定义列表属二期；内置阅读器已支持 epub / txt / cbz（pdf 等暂不支持）。
 */
export const book: ServerModule = {
  id: 'book',
  prefix: '/api/v1/book',
  permissions: ['book:read', 'book:write'],

  migrations: BOOK_MIGRATIONS,

  async register(app, k) {
    for (const schema of BOOK_SCHEMAS) app.addSchema(schema);
    // 绝对路径来源的 extraRoots 是内存白名单，重启后要按库里已有来源重建
    const libs = await sql<{ root_path: string }>`
      select root_path from book_libraries
    `.execute(k.db);
    for (const lib of libs.rows) {
      if (isAbsoluteInput(lib.root_path)) registerExtraRoot(absoluteInput(lib.root_path));
    }
    const libWatch = bindLibraryWatch<BookLibraryRow>({
      k,
      domain: 'book',
      load: async () => (await sql<BookLibraryRow>`select * from book_libraries`.execute(k.db)).rows,
      scan: (lib, subDir) => scanBookLibrary(k.db, lib, undefined, subDir),
      accept: isBookFile,
    });
    await registerBookFulltext(app, k);
    const h = makeBookHelpers(k, libWatch);
    await registerBookLibrary(app, k, h);
    await registerBookShelf(app, k, h);
    await registerBookReading(app, k, h);
    await registerBookFavorites(app, k, h);
    await registerBookCollections(app, k, h);
    await registerBookLists(app, k, h);
    await registerBookHistory(app, k, h);
    await registerBookUserCollections(app, k, h);
    await applyBookScanSchedule(k);
    scheduleStartupScan(k);
  },
};
