import { sql } from 'kysely';
import type { ServerModule } from '../../../kernel/types';
import { writeCover, isAudioFile } from './ffmpeg';
import { MUSIC_SCHEMAS } from './schemas';
import { scanMusicLibrary, type MusicLibraryRow } from './scan';
import { registerMusicState } from './state';
import { bindLibraryWatch } from '../library-watch';

import { MUSIC_MIGRATIONS } from './migrations';
import { makeMusicHelpers } from './helpers';
import { registerMusicLibrary } from './routes/library';
import { registerMusicItems } from './routes/items';
import { registerMusicPlayback } from './routes/playback';
import { registerMusicPlaylists } from './routes/playlists';
import { registerMusicAutoPlaylists } from './routes/auto-playlists';

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
export const music: ServerModule = {
  id: 'music',
  prefix: '/api/v1/music',
  permissions: ['music:read', 'music:write'],

  migrations: MUSIC_MIGRATIONS,

  async register(app, k) {
    for (const schema of MUSIC_SCHEMAS) app.addSchema(schema);
    const libWatch = bindLibraryWatch<MusicLibraryRow>({
      k,
      domain: 'music',
      load: async () => (await sql<MusicLibraryRow>`select * from music_libraries`.execute(k.db)).rows,
      scan: (lib, subDir) => scanMusicLibrary(k.db, lib, undefined, subDir),
      accept: isAudioFile,
    });
    await registerMusicState(app, k);
    const h = makeMusicHelpers(k, libWatch);
    await registerMusicLibrary(app, k, h);
    await registerMusicItems(app, k, h);
    await registerMusicPlayback(app, k, h);
    await registerMusicPlaylists(app, k, h);
    await registerMusicAutoPlaylists(app, k, h);
  },
};
