// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/apps.json#nav
// regenerate: npm run gen:apps

/// 二级菜单的呈现形态。
///   - [side]：左侧栏（绝大多数模块）
///   - [hub]：模块自己画的入口页（如「发现」），不渲染侧栏
///   - [none]：没有二级菜单
enum NavStyle { side, hub, none }

/// 一个菜单项。动态项（[dynamic] 非空）由运行时数据撑开成一串项。
class NavItemSpec {
  const NavItemSpec({
    required this.id,
    this.labelKey,
    this.icon,
    this.dynamic,
    this.idPrefix,
    this.labelFrom,
    this.iconFrom,
    this.when,
  });

  final String id;

  /// 静态项的文案键；动态项为 null（文案来自运行时数据）
  final String? labelKey;

  /// 图标名（见客户端 `AppVisuals.iconFor`）；动态项为 null，用 [iconFrom] 从数据取
  final String? icon;

  /// 动态项的数据源键，如 `video.libraries`
  final String? dynamic;

  /// 动态项 id 前缀，如 `lib:`
  final String? idPrefix;

  /// 动态项从数据对象的哪个字段取文案
  final String? labelFrom;

  /// 动态项从数据对象的哪个字段取图标
  final String? iconFrom;

  /// 条件键：只有当该条件为真时才显示（由模块提供）
  final String? when;

  bool get isDynamic => dynamic != null;
}

class NavSectionSpec {
  const NavSectionSpec({
    required this.id,
    required this.titleKey,
    required this.icon,
    required this.items,
  });

  final String id;
  final String titleKey;
  final String icon;
  final List<NavItemSpec> items;
}

class AppNavSpec {
  const AppNavSpec({required this.appId, required this.style, required this.sections});

  final String appId;
  final NavStyle style;
  final List<NavSectionSpec> sections;

  /// 全部静态项 id（不含动态项），用于「契约 ↔ 实现」对账与测试遍历
  Iterable<String> get staticItemIds => sections
      .expand((s) => s.items)
      .where((i) => !i.isDynamic)
      .map((i) => i.id);
}

/// 有二级菜单的 App（生成自契约，新增模块只要在 apps.json 写 nav）
const Map<String, AppNavSpec> kAppNavSpecs = <String, AppNavSpec>{
  'photo': AppNavSpec(
    appId: 'photo',
    style: NavStyle.side,
    sections: <NavSectionSpec>[
      NavSectionSpec(
        id: 'photos',
        titleKey: 'ui.photo.041',
        icon: 'photo_library_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'home', labelKey: 'photo.nav.home', icon: 'home_outlined'),
          NavItemSpec(id: 'timeline', labelKey: 'ui.photo.056', icon: 'timeline_outlined'),
          NavItemSpec(id: 'footprint', labelKey: 'ui.photo.021', icon: 'place_outlined'),
          NavItemSpec(id: 'favorites', labelKey: 'photo.nav.favorites', icon: 'favorite_outline'),
          NavItemSpec(id: 'folders', labelKey: 'photo.nav.files', icon: 'folder_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'memories',
        titleKey: 'ui.photo.026',
        icon: 'auto_stories_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'memory', labelKey: 'photo.nav.memory', icon: 'auto_stories_outlined'),
          NavItemSpec(id: 'dayFrame', labelKey: 'photo.nav.dayFrame', icon: 'auto_awesome_mosaic_outlined'),
          NavItemSpec(id: 'tickets', labelKey: 'photo.nav.tickets', icon: 'confirmation_number_outlined'),
          NavItemSpec(id: 'year', labelKey: 'photo.nav.year', icon: 'bar_chart'),
        ],
      ),
      NavSectionSpec(
        id: 'albums',
        titleKey: 'ui.photo.053',
        icon: 'collections_bookmark_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'album', labelKey: 'ui.photo.053', icon: 'photo_album_outlined'),
          NavItemSpec(id: 'collection', labelKey: 'photo.nav.collection', icon: 'collections_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'ai',
        titleKey: 'photo.nav.ai',
        icon: 'auto_awesome_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'faces', labelKey: 'ui.photo.038', icon: 'face_retouching_natural_outlined'),
          NavItemSpec(id: 'relations', labelKey: 'photo.relations.title', icon: 'hub_outlined'),
          NavItemSpec(id: 'scenes', labelKey: 'ui.photo.036', icon: 'landscape_outlined'),
          NavItemSpec(id: 'activities', labelKey: 'photo.nav.activities', icon: 'sports_handball_outlined'),
          NavItemSpec(id: 'smartRules', labelKey: 'photo.smartRule.title', icon: 'rule'),
          NavItemSpec(id: 'search', labelKey: 'common.search', icon: 'search'),
          NavItemSpec(id: 'gps', labelKey: 'photo.nav.gps', icon: 'gps_fixed_outlined'),
          NavItemSpec(id: 'cleanup', labelKey: 'photo.nav.similarCleanup', icon: 'cleaning_services_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'settings',
        titleKey: 'ui.settings.017',
        icon: 'settings_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'source', labelKey: 'photo.nav.source', icon: 'folder_special_outlined'),
          NavItemSpec(id: 'preview', labelKey: 'photo.nav.preview', icon: 'photo_size_select_large_outlined'),
          NavItemSpec(id: 'aiSettings', labelKey: 'photo.nav.aiSettings', icon: 'tag_faces_outlined'),
          NavItemSpec(id: 'trash', labelKey: 'photo.nav.trash', icon: 'delete_sweep_outlined'),
        ],
      ),
    ],
  ),
  'video': AppNavSpec(
    appId: 'video',
    style: NavStyle.side,
    sections: <NavSectionSpec>[
      NavSectionSpec(
        id: 'libraries',
        titleKey: 'video.nav.libraries',
        icon: 'movie_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'home', labelKey: 'video.nav.home', icon: 'home_outlined'),
          NavItemSpec(id: 'lib', dynamic: 'video.libraries', idPrefix: 'lib:', labelFrom: 'name', iconFrom: 'libType'),
          NavItemSpec(id: 'history', labelKey: 'video.nav.history', icon: 'history'),
          NavItemSpec(id: 'favorites', labelKey: 'photo.nav.favorites', icon: 'favorite_outline'),
          NavItemSpec(id: 'jp_rank', labelKey: 'video.nav.jpRank', icon: 'leaderboard_outlined', when: 'hasJpLibrary'),
          NavItemSpec(id: 'jp_actor', labelKey: 'video.nav.jpActor', icon: 'people_outline', when: 'hasJpLibrary'),
          NavItemSpec(id: 'series', labelKey: 'video.nav.series', icon: 'video_library_outlined'),
          NavItemSpec(id: 'browse', labelKey: 'video.browse.title', icon: 'photo_library_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'collections',
        titleKey: 'video.collection.group',
        icon: 'collections_bookmark_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'collections', labelKey: 'video.collection.title', icon: 'collections_bookmark_outlined'),
          NavItemSpec(id: 'smartAlbums', labelKey: 'video.smart.title', icon: 'auto_awesome_outlined'),
          NavItemSpec(id: 'duplicates', labelKey: 'video.duplicate.title', icon: 'content_copy_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'settings',
        titleKey: 'video.nav.settingsGroup',
        icon: 'settings_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'settings.library', labelKey: 'video.nav.librarySettings', icon: 'video_library_outlined'),
          NavItemSpec(id: 'settings.scrape', labelKey: 'video.nav.scrapeSettings', icon: 'auto_awesome_outlined'),
          NavItemSpec(id: 'settings.other', labelKey: 'video.nav.otherSettings', icon: 'tune'),
        ],
      ),
    ],
  ),
  'discover': AppNavSpec(
    appId: 'discover',
    style: NavStyle.side,
    sections: <NavSectionSpec>[
      NavSectionSpec(
        id: 'explore',
        titleKey: 'discover.nav.explore',
        icon: 'travel_explore_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'discover', labelKey: 'ui.discover.006', icon: 'explore_outlined'),
          NavItemSpec(id: 'pt', labelKey: 'discover.pt', icon: 'download_outlined'),
          NavItemSpec(id: 'rss', labelKey: 'discover.rss', icon: 'rss_feed'),
        ],
      ),
      NavSectionSpec(
        id: 'manage',
        titleKey: 'discover.nav.manage',
        icon: 'tune',
        items: <NavItemSpec>[
          NavItemSpec(id: 'tasks', labelKey: 'discover.tasks', icon: 'task_alt_outlined'),
          NavItemSpec(id: 'settings', labelKey: 'discover.settings', icon: 'settings_outlined'),
        ],
      ),
    ],
  ),
  'music': AppNavSpec(
    appId: 'music',
    style: NavStyle.side,
    sections: <NavSectionSpec>[
      NavSectionSpec(
        id: 'library',
        titleKey: 'music.nav.library',
        icon: 'library_music_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'songs', labelKey: 'ui.music.009', icon: 'music_note_outlined'),
          NavItemSpec(id: 'favorites', labelKey: 'photo.nav.favorites', icon: 'favorite_outline'),
          NavItemSpec(id: 'history', labelKey: 'music.nav.history', icon: 'history_outlined'),
          NavItemSpec(id: 'albums', labelKey: 'music.nav.albums', icon: 'album_outlined'),
          NavItemSpec(id: 'artists', labelKey: 'music.nav.artists', icon: 'people_outlined'),
          NavItemSpec(id: 'files', labelKey: 'photo.nav.files', icon: 'folder_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'playlists',
        titleKey: 'ui.music.010',
        icon: 'queue_music',
        items: <NavItemSpec>[
          NavItemSpec(id: 'playlists', labelKey: 'ui.music.030', icon: 'queue_music_outlined'),
          NavItemSpec(id: 'recentAdded', labelKey: 'ui.music.026', icon: 'new_releases_outlined'),
          NavItemSpec(id: 'recentPlayed', labelKey: 'ui.music.027', icon: 'history'),
          NavItemSpec(id: 'mostPlayed', labelKey: 'ui.music.028', icon: 'trending_up'),
          NavItemSpec(id: 'neverPlayed', labelKey: 'ui.music.029', icon: 'play_circle_outline'),
        ],
      ),
      NavSectionSpec(
        id: 'settings',
        titleKey: 'ui.settings.017',
        icon: 'settings_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'settings', labelKey: 'music.nav.settings', icon: 'tune'),
        ],
      ),
    ],
  ),
};

/// 取某个 App 的菜单结构（没有二级菜单时返回 null）
AppNavSpec? appNavSpecOf(String appId) => kAppNavSpecs[appId];
