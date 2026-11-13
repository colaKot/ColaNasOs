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
  '004_rss_feeds',
  '005_sync_jobs',
  '006_users',
  '007_webhooks',
  '010_files_meta',
  '020_index_progress',
  // 媒体域
  '030_photo',
  '031_video',
  '032_music',
  // 影视库扩展
  '035_video_series',
  '036_video_progress',
  // 工具与播放
  '041_player_sessions',
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
  // 071 保留登记：迁移定义仍在（历史库靠它建过表），169 负责把表删掉并清掉执行记录。
  // 从清单里摘掉会让 checkMigrationOrder 报「磁盘有而未登记」。
  '071_photo_collections',
  // 相册记忆（确认 / 忽略 / 备注）
  '072_photo_memories',
  '073_photo_memory_marks',
  '074_photo_phash_gps',
  // 影视信息卡徽章（4K / HDR / 杜比；扫描期解析，无需重扫）
  '075_video_media_flags',
  // 影视自定义合集（每用户）
  '076_video_collections',
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
  '097_sync_task_client',
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
  // 转码会话音轨选择 + HDR→SDR（audio_index / force_sdr / hdr_to_sdr）
  '129_player_audio_index',
  // FTS5 trigram 全文索引（>=3 字符走 MATCH，1-2 字回退 LIKE）
  '130_video_fts',
  '131_photo_fts',
  '132_files_fts',
  // 照片识别失败记账（避免坏图每轮被重新挑中，形成热循环）
  '133_photo_ai_skip',
  // HDR/DV 标记的解析口径版本（老行重探一次，修 DV P5 偏色的历史脏数据）
  '134_video_hdr_meta_version',
  // 转码会话的提前转码时长（lead_ms；老行 0 = 整片，新会话默认 3 分钟）
  '135_player_lead',
  // 转码会话的起转偏移（start_ms；>0 = 进度条跳到未转码位置后另起的会话）
  '141_player_start',
  // AI 播客（每期节目 / 设置 / 定时计划）
  '142_blog',
  // AI 播客的合成引擎（本地 Kokoro / 在线 Edge）
  '143_blog_tts_engine',
  // 英文素材的本地翻译缓存（AI 新闻英转中）
  '144_blog_translations',
  // 每期节目的云端模型 token 用量（对账用）
  '145_blog_llm_usage',
  // 照片识别完成标记（位：基础/OCR/活动）；老库按已有结果回填
  '146_photo_ai_done_mask',
  // 人脸认领护栏元数据（quality / pose），老库按 score 回填
  '147_photo_faces_claim_guard',
  // AI 播客每期的素材清单（文稿弹窗底部的引用链接）
  '148_blog_episode_news',
  // 相册从「只收图片」扩到「图片 + 视频」，并记录动态照片尾部视频的位置
  '148_photo_media_kind',
  // 媒体解析版本号：老行 media_ver=0，升级后第一次扫描自动重读文件头补 live_* 字段
  '149_photo_media_ver',
  // 动态照片多品牌识别：视频起点 / 来源 / 配对路径
  '150_photo_live_span',
  // 手机备份判重：固化「上传时那份原始内容」的字节数（补 GPS / 重编码后 size 会变）
  '151_photo_orig_size',
  // 在 NAS 上删过的照片留指纹墓碑，清空回收站后也不再被手机重新上传
  '152_photo_deleted_fp',
  // 影视发现 兼容适配：PT 下载闭环 / 收藏三态 / RSS 台账与条目状态
  '153_pt_download_idem',
  '154_discover_favorite_state',
  '155_rss_compat',
  // 评分体系 TMDB↔豆瓣：豆瓣评分/榜单缓存；择种规则 + 订阅按 media_id + 站点连通性留痕
  '156_douban_rating_cache',
  '157_pt_rules_sub_media',
  // 音乐来源的「启动时扫描 / 有变动时扫描 / 间隔扫描」三个开关落成真列
  '158_music_library_scan_policy',
  // 传输中心：上传 / 下载会话（谁、哪一端、传到哪）
  '159_transfer_sessions',
  // 清理已移除的六个模块（书房 / 笔记 / 挂载 / 分享 / 安全 / 消息）遗留的表
  '160_drop_removed_modules',
  // 人脸重建的「前快照」两张表从没被任何代码读写过，清掉 18.5 万行死数据
  '161_drop_dead_face_snapshot',
  // 收藏表主键列序修正：(item_id, owner_id) → (owner_id, item_id)，让 where owner_id=? 能走索引
  '162_music_favorites_owner_first',
  // 音乐库归属列（与 photo_libraries 对齐；NULL = 所有人可见，不改现有可见性）
  '163_music_library_owner',
  // 影视库归属列（同上）
  '164_video_library_owner',
  // 裁掉 photo_items 上三个查询计划永远命中不到的索引（纯写放大）
  '166_photo_items_drop_unused_indexes',
  // FTS 增量同步触发器由「AFTER UPDATE」收紧为「AFTER UPDATE OF 被索引列」，
  // 避免改 sub_fetch_state / jp_hot_votes 这类字段也重建 trigram（实测占该次更新 97%）
  '167_video_fts_update_scope',
  // 媒体工具整块移除，清掉两张从没被写过的任务表
  '168_drop_media_tool',
  // 集合并入相册（集合表全库 0 行），同时给相册加规则列
  '169_photo_album_rules',
  // 音乐键值设置（Last.fm 的 Key / Secret）+ 在线热度缓存 + 每用户 Last.fm 绑定
  '170_music_settings_lastfm',
  '171_discover_favorite_meta',
  '172_rss_feed_download_target',
  // 下载台账关联影视元数据（media_id / library_id / 完成时间），订阅可选归档库
  '173_pt_media_link',
  // 图片 / 混合库目录列预写入库（列表 / 文件夹聚合改走索引）
  '174_video_dir_path',
  // 权限域合并：player→video / security→user / integration→system（只改存量值）
  '175_scope_domain_merge',
  // 成长轨迹：阶段预计算表 + 封面候选池 + 增量凭据
  '176_photo_growth',
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