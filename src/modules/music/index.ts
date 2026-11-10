import { sql } from 'kysely';
import type { KernelApi, ServerModule } from '../../../kernel/types';
import { writeCover, isAudioFile } from './ffmpeg';
import { MUSIC_SCHEMAS } from './schemas';
import { scanMusicLibrary, type MusicLibraryRow } from './scan';
import { registerMusicState } from './state';
import { bindLibraryWatch } from '../library-watch';

import { MUSIC_MIGRATIONS } from './migrations';
import { makeMusicHelpers } from './helpers';
import { absoluteInput, isAbsoluteInput, registerExtraRoot } from '../files/fs-root';
import { registerMusicLibrary } from './routes/library';
import { registerMusicItems } from './routes/items';
import { registerMusicPlayback } from './routes/playback';
import { registerMusicPlaylists } from './routes/playlists';
import { registerMusicAutoPlaylists } from './routes/auto-playlists';
import { registerMusicCollections } from './routes/collections';
import { registerMusicCompat } from './routes/compat';

/**
 * SP3-04 music：库 / 索引 / 列表 / 搜索 / 内嵌封面 / 播放 / 自建播放列表（一期）。
 *
 *   POST /api/v1/music/libraries        新建库
 *   GET  /api/v1/music/libraries        库列表
 *   POST /api/v1/music/libraries/remove 删除库（级联清理曲目与歌单引用）
 *   POST /api/v1/music/scan             扫描索引（ffmpeg 解析 tags / 时长 / 采样率）
 *   GET  /api/v1/music/list             列表（标题序 + 排序键 cursor，支持艺术家/专辑过滤）
 *   GET  /api/v1/music/item             详情
 *   GET  /api/v1/music/stats            曲目 / 专辑 / 艺术家 / 总时长
 *   GET  /api/v1/music/cover            内嵌封面（懒生成 + 文件缓存）
 *   GET  /api/v1/music/stream           播放 / 下载（复用 files 的 Range / ETag）
 *   GET  /api/v1/music/stream-url       带短期令牌的播放地址（供外部播放器）
 *   GET  /api/v1/music/playlists        当前用户歌单
 *   POST /api/v1/music/playlists        新建歌单
 *   GET  /api/v1/music/playlists/items  歌单曲目
 *   POST /api/v1/music/playlists/add    加入曲目
 *   POST /api/v1/music/playlists/remove 移出曲目
 *   POST /api/v1/music/playlists/delete 删除歌单
 *   GET  /api/v1/music/lyrics           歌词（旁挂 LRC / 内嵌 ID3·Vorbis / 双语对照）
 *   GET  /api/v1/music/auto-playlists   自动歌单概览（最近添加 / 最近播放 / 最常播放 / 从未播放）
 *   GET  /api/v1/music/auto-playlist    自动歌单曲目（服务端实时计算，不写用户数据）
 *
 * 二期：客户端常驻播放服务（后台播放 + Web Media Session）、桌面端均衡器、
 * Web 端按需 AAC 转码（stream-url?format=auto）。
 */
/**
 * 启动时把「开了启动扫描」的来源各入队一次。
 *
 * 必须等 `registerMusicLibrary` 里 `k.tasks.register('music.scan')` 跑完才能入队，
 * 所以调用点在它之后；这里自己吞异常，扫描失败不能影响内核启动。
 */
async function enqueueStartupScan(k: KernelApi): Promise<void> {
  try {
    const rows = await sql<{ id: string }>`
      select id from music_libraries where coalesce(scan_when_start, 1) <> 0
    `.execute(k.db);
    for (const r of rows.rows) {
      const t = await k.tasks.enqueueIfIdle('music.scan', { libraryId: r.id }, { maxAttempts: 1 });
      k.log.info({ libraryId: r.id, taskId: t.id, reused: t.reused }, 'music.scan.startup');
    }
  } catch (err) {
    k.log.warn({ error: String(err) }, 'music.scan.startup.enqueue failed');
  }
}

export const music: ServerModule = {
  id: 'music',
  prefix: '/api/v1/music',
  permissions: ['music:read', 'music:write'],

  migrations: MUSIC_MIGRATIONS,

  async register(app, k) {
    for (const schema of MUSIC_SCHEMAS) app.addSchema(schema);
    // 绝对路径来源（D:/music、\\host\share\music）在**创建时**登记过 extraRoots，
    // 但那是内存白名单，进程重启后就空了 —— 封面 / 歌词 / 转码都会 403。
    // 模块启动时按库里已有来源重建一遍，保证重启后媒体路径仍可解析。
    const libs = await sql<{ root_path: string }>`
      select root_path from music_libraries
    `.execute(k.db);
    for (const lib of libs.rows) {
      if (isAbsoluteInput(lib.root_path)) registerExtraRoot(absoluteInput(lib.root_path));
    }
    const libWatch = bindLibraryWatch<MusicLibraryRow>({
      k,
      domain: 'music',
      load: async () => (await sql<MusicLibraryRow>`select * from music_libraries`.execute(k.db)).rows,
      scan: (lib, subDir) => scanMusicLibrary(k.db, lib, undefined, subDir),
      accept: isAudioFile,
      // 每库「间隔扫描」的周期；0 表示跟随全局 6 小时校验
      intervalOf: (lib) => Number(lib.scan_interval_ms ?? 0),
    });
    // bindLibraryWatch 只建空壳 + 定时校验，订阅关系要 refresh() 才建立。
    // 不调的话「内核起来后往来源目录丢新歌」永远不会触发增量扫描（要等人工
    // 增删改一次来源才对齐），用户看到的就是「新歌死活搜不到」。
    await libWatch.refresh();
    await registerMusicState(app, k);
    const h = makeMusicHelpers(k, libWatch);
    await registerMusicLibrary(app, k, h);
    // 「启动时扫描」：这个开关以前是假的（表里没列，列表接口硬编码 1）。
    // 现在按库配置在内核起来后**异步**入队一次，不挡启动；已在扫描的直接复用任务。
    void enqueueStartupScan(k);
    await registerMusicItems(app, k, h);
    await registerMusicPlayback(app, k, h);
    await registerMusicPlaylists(app, k, h);
    await registerMusicAutoPlaylists(app, k, h);
    await registerMusicCollections(app, k, h);
    // 既有实现 形状的兼容适配层（前端音乐模块整页搬过来，只认这套形状）
    await registerMusicCompat(app, k, h);
  },
};
