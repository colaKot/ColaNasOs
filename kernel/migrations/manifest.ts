import type { Migration } from '../migrator';

/**
 * 迁移顺序清单（schema-as-code 的唯一真源）。
 *
 * 规则：
 * 1. **只允许在末尾追加**。新迁移一律取比现有最大值更大的编号（当前最大 `060`，下一条用 `061`），
 *    不允许插到中间、不允许重排 —— 否则老库与新库的执行顺序会不一致，且这种问题只在用户机器上炸。
 * 2. 磁盘上（各模块 `migrations` 数组里）有、但这里没登记的迁移 ⇒ **启动直接抛错**。
 *    响亮失败优于静默乱序。
 * 3. 这里登记了、但模块已经不再提供 ⇒ 记 warning（允许裁剪模块），不阻断启动。
 * 4. 清单顺序即执行顺序；不再按 id 字典序隐式排序。
 * 5. **不做 DDL 回滚**：SQLite 的 DDL 回滚不可靠，假承诺比没承诺更糟。
 */
export const MIGRATION_ORDER: readonly string[] = Object.freeze([
  // 内核
  '001_config',
  // 基础域
  '001_share_links',
  '002_backup_jobs',
  '003_vaults',
  '004_rss_feeds',
  '005_sync_jobs',
  '006_users',
  '007_webhooks',
  '008_messages',
  '009_notes',
  '010_files_meta',
  '020_index_progress',
  // 媒体域
  '030_photo',
  '031_video',
  '032_music',
  '033_book',
  // 挂载与检索
  '034_remote_mounts',
  '035_video_series',
  '036_video_progress',
  '037_book_organize',
  // 工具与播放
  '040_media_tool',
  '041_player_sessions',
  '042_book_fulltext',
  '043_music_state',
  '044_video_meta',
  // 相册 AI 与地理
  '045_photo_ai',
  '050_photo_geo',
  '051_photo_cleanup',
  '052_photo_faces',
  '053_photo_faces_map',
  '054_photo_backup',
  // 影视库
  '060_video_libtype',
  // 多端同步 v2（三向比对）
  '061_sync_v2',
  // 相册可撤销操作日志
  '062_photo_operation_log',
  // 场景 v2 多标签
  '063_photo_scene_tags',
  // 人脸重建 v2 元信息
  '064_face_cluster_v2_meta',
  // 播放器按编码分档
  '065_player_codec',
  // 影视 SMB 片源
  '066_video_smb_source',
  // 相册库归属
  '067_photo_library_owner',
  // 日本片自动字幕 / 演员收藏
  '068_jp_auto_subtitle',
  // PT 站点 / 订阅
  '069_pt',
  '070_pt_mteam',
  // 相册集合（照片聚合分组）
  '071_photo_collections',
  // 相册记忆（确认 / 忽略 / 备注）
  '072_photo_memories',
  '073_photo_memory_marks',
  '074_photo_phash_gps',
  // 影视信息卡徽章（4K / HDR / 杜比；扫描期解析，无需重扫）
  '075_video_media_flags',
  // 影视自定义合集（每用户）
  '076_video_collections',
  // 笔记乐观锁版本号（多人编辑冲突检测）
  '077_notes_version',
  // 剧集级收藏（每用户，按 series + 库）
  '078_video_series_favorites',
  // 相册智能规则（自定义条件组合，每用户）
  '079_photo_smart_rules',
  // 影视媒体信息层（nfo_* 一组列：片名 / 年份 / 评分 / 类型 / 人物 / 海报 / 外部 id）
  '080_video_nfo',
  // 影视已观看标记（每用户，独立于播放进度）
  '081_video_watch',
  // 影视库级设置（首页可见 / 左栏排序 / 响度归一 / 是否参与刮削）
  '082_video_library_settings',
  // 人脸位置信息（bbox / 原图尺寸 / 簇头像）
  '083_photo_face_bbox',
  // 相册元数据（封面 / 简介 / 排序）+ 回收站删除批次 + 人脸合并审计
  '084_photo_p2',
  // 影视合集元数据（封面 / 简介 / 排序）+ 库级「入库即刮」开关
  '085_video_collection_meta',
  // 榜单快照（TMDB 发现页 / 日系榜单共用，替代进程内缓存）
  '086_media_catalog',
  // 人脸按 photo_id 的索引（删除 / 回忆 / 回填走点查，不再全表扫）
  '087_photo_faces_photo_idx',
  // 影视列表排序的表达式索引（刮削名 / mtime）
  '088_video_query_indexes',
  // 相册封面取「最早加入」的索引
  '089_photo_album_added_idx',
  // 音乐播放记录的 (owner, item) 点查索引（自动歌单）
  '090_music_plays_item_idx',
  // 删掉 image_items.favorite（死列：从不写、没人读，收藏走 video_favorites）
  '091_drop_image_favorite',
  // 影视库多来源（一个库扫多个目录 / 多台 SMB）
  '092_video_library_sources',
  // 日本片热度字段（JavDB 评价人数 / 评分，演员作品综合排序用）
  '093_video_jp_hot',
  // 图片库 / 混合库的排序与首字母检索列
  '094_video_image_search',
  // 同步任务名（同设备多任务可区分；老任务为空时显示设备名）
  '095_sync_task_name',
  // 同步任务的结构化过滤与策略（冲突/删除传播/间隔）
  '096_sync_task_config',
  // 媒体工具统一任务表（uid/统计/启停；旧 jobs 复制进来）
  '097_media_tool_tasks',
  // 账号资料（手机 / 备注 / 最近登录）
  '098_auth_user_profile',
  // 登录记录与用户管理审计
  '099_auth_events',
  // 长期访问令牌（Scoped Token）
  '100_auth_api_tokens',
  // 发现页收藏（每用户）
  '101_discover_favorites',
  // 下载台账 info hash（暂停/恢复/移除）
  '102_pt_download_hash',
  // 文件操作日志（上传 / 下载 / 改名 / 移动 / 删除 / 回收站）
  '103_file_op_logs',
  // RSS 自动下载规则（命中新条目 → 自动建 PT 订阅）
  '104_rss_rules',
  // 转码会话的客户端级音频覆盖（响度归一 / 降混双声道）
  '105_player_audio',
  // 每日刮削进度快照（待刮 / 已刮 / 无中字无字幕）
  '106_video_scrape_stats',
  // 音乐合集（用户自建的音乐目录分组，按 owner 隔离）
  '107_music_collections',
  // 书库类型（书籍 / 漫画）+ 阅读历史 + 用户自建图书合集
  '108_book_type_history',
  // 书库来源级扫描策略（启动 / 变更 / 定时）
  '109_book_scan_schedule',
  // 转码会话音轨选择 + HDR→SDR（audio_index / force_sdr / hdr_to_sdr）
  '129_player_audio_index',
  // FTS5 trigram 全文索引（>=3 字符走 MATCH，1-2 字回退 LIKE）
  '130_video_fts',
  '131_photo_fts',
  '132_files_fts',
  // 照片识别失败记账（避免坏图每轮被重新挑中，形成热循环）
  '133_photo_ai_skip',
]);

export interface OrderCheck {
  /** 模块提供但清单未登记（必须阻断启动） */
  unregistered: string[];
  /** 清单已登记但模块未提供（允许，仅告警） */
  missing: string[];
  /** 清单内部重复 */
  duplicated: string[];
}

export function checkMigrationOrder(
  ids: readonly string[],
  order: readonly string[] = MIGRATION_ORDER,
): OrderCheck {
  const known = new Set(order);
  const provided = new Set(ids);
  const seen = new Set<string>();
  const duplicated: string[] = [];
  for (const id of order) {
    if (seen.has(id)) duplicated.push(id);
    seen.add(id);
  }
  return {
    unregistered: [...provided].filter((id) => !known.has(id)).sort(),
    missing: [...known].filter((id) => !provided.has(id)).sort(),
    duplicated,
  };
}

/**
 * 按清单顺序排列迁移集合。
 * 未登记的迁移不会被执行（由调用方在 `checkMigrationOrder` 之后抛错拦截）。
 */
export function orderMigrations(
  migrations: readonly Migration[],
  order: readonly string[] = MIGRATION_ORDER,
): Migration[] {
  const byId = new Map(migrations.map((m) => [m.id, m]));
  const out: Migration[] = [];
  for (const id of order) {
    const m = byId.get(id);
    if (m) out.push(m);
  }
  return out;
}