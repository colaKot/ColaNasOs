import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';

/// App 的视觉身份：图标、渐变色、侧栏分组。
///
/// 侧栏、工作台、compact 底部导航三处都从这里取，保证同一个 App 全站同色同图标。
/// **分组与配色都来自契约**（`contracts/apps.json#group` / `#accent`），新增 App 不用改这里；
/// 只有引入新的图标名时才需要在 [icons] 里补一行。
///
/// 为什么是「白名单表」而不是一个 `switch`：契约里的图标名是字符串，写错一个字母
/// 只会静默兜底成 [Icons.apps]，界面上完全看不出来。现在表是公开常量，
/// `test/icon_whitelist_test.dart` 能把「契约有名字、表里没有」和「表里有、没人用」
/// 两个方向都钉住。
class AppVisuals {
  const AppVisuals._();

  /// 图标名 → IconData。键名与 `contracts/apps.json` 里的 `icon` 字段一一对应。
  static const Map<String, IconData> icons = <String, IconData>{
    'album_outlined': Icons.album_outlined,
    'auto_awesome_mosaic_outlined': Icons.auto_awesome_mosaic_outlined,
    'auto_awesome_outlined': Icons.auto_awesome_outlined,
    'auto_stories_outlined': Icons.auto_stories_outlined,
    'backup': Icons.shield_outlined,
    'bar_chart': Icons.bar_chart,
    'camera': Icons.videocam_outlined,
    'cleaning_services_outlined': Icons.cleaning_services_outlined,
    'cloud_upload_outlined': Icons.cloud_upload_outlined,
    'collections_bookmark_outlined': Icons.collections_bookmark_outlined,
    'collections_outlined': Icons.collections_outlined,
    'compass': Icons.travel_explore,
    'confirmation_number_outlined': Icons.confirmation_number_outlined,
    'content_copy_outlined': Icons.content_copy_outlined,
    'delete_sweep_outlined': Icons.delete_sweep_outlined,
    'download': Icons.download_outlined,
    'download_outlined': Icons.download_outlined,
    'explore_outlined': Icons.explore_outlined,
    'face_retouching_natural_outlined': Icons.face_retouching_natural_outlined,
    'favorite_outline': Icons.favorite_outline,
    'folder': Icons.folder_outlined,
    'folder_outlined': Icons.folder_outlined,
    'folder_special_outlined': Icons.folder_special_outlined,
    'gear': Icons.settings_outlined,
    'gps_fixed_outlined': Icons.gps_fixed_outlined,
    'history': Icons.history,
    'history_outlined': Icons.history_outlined,
    'home': Icons.dashboard_outlined,
    'home_outlined': Icons.home_outlined,
    'hub_outlined': Icons.hub_outlined,
    'help_outline': Icons.help_outline,
    'landscape_outlined': Icons.landscape_outlined,
    'leaderboard_outlined': Icons.leaderboard_outlined,
    'library_music_outlined': Icons.library_music_outlined,
    'live_tv_outlined': Icons.live_tv_outlined,
    'local_movies_outlined': Icons.local_movies_outlined,
    'movie': Icons.movie_outlined,
    'movie_outlined': Icons.movie_outlined,
    'music': Icons.library_music_outlined,
    'music_note_outlined': Icons.music_note_outlined,
    'note': Icons.sticky_note_2_outlined,
    'people_outline': Icons.people_outline,
    'people_outlined': Icons.people_outlined,
    'photo': Icons.photo_library_outlined,
    'photo_album_outlined': Icons.photo_album_outlined,
    'photo_library_outlined': Icons.photo_library_outlined,
    'photo_size_select_large_outlined': Icons.photo_size_select_large_outlined,
    'place_outlined': Icons.place_outlined,
    'podcast': Icons.podcasts_outlined,
    'newspaper_outlined': Icons.newspaper_outlined,
    'pulse': Icons.monitor_heart_outlined,
    'queue_music': Icons.queue_music,
    'queue_music_outlined': Icons.queue_music_outlined,
    'rss_feed': Icons.rss_feed,
    'rule': Icons.rule,
    'search': Icons.search,
    'settings_outlined': Icons.settings_outlined,
    'share': Icons.link,
    'sparkles': Icons.auto_awesome_outlined,
    'sports_handball_outlined': Icons.sports_handball_outlined,
    'sync': Icons.sync_alt,
    'tag_faces_outlined': Icons.tag_faces_outlined,
    'task_alt_outlined': Icons.task_alt_outlined,
    'terminal': Icons.terminal,
    'timeline_outlined': Icons.timeline_outlined,
    'transfer': Icons.swap_vert,
    'devices': Icons.devices,
    'travel_explore_outlined': Icons.travel_explore_outlined,
    'tune': Icons.tune,
    'users': Icons.manage_accounts_outlined,
    'video_library_outlined': Icons.video_library_outlined,
  };

  /// 图标名 → IconData；名字不在白名单里时返回 null（调用方决定兜底成什么）
  static IconData? iconOrNull(String name) => icons[name];

  /// 兜底版：不认识的图标名统一用 [Icons.apps]（一级导航/工作台用这个）
  static IconData iconFor(String name) => iconOrNull(name) ?? Icons.apps;

  /// 工作台卡片渐变。数据来自契约（`contracts/apps.json#accent`），
  /// 新增应用只要在契约里写两个色值，不再改这里。
  static List<Color> accentFor(String appId) {
    final app = AppRegistry.byId(appId);
    final pair = app?.accent;
    if (pair == null || pair.length != 2) {
      return const [Color(0xFF64748B), Color(0xFF475569)];
    }
    return [Color(pair[0]), Color(pair[1])];
  }

  /// 一级菜单分组。契约里的 `group` 生成成 [AppGroup] 枚举，写错字母编译不过。
  static AppGroup groupOf(String appId) =>
      AppRegistry.byId(appId)?.group ?? AppGroup.system;
}
