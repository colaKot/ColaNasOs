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
  const AppNavSpec({
    required this.appId,
    required this.style,
    required this.sections,
    this.mobileTabs = const <String>[],
    this.mobileTabLabels = const <String, String>{},
    this.mobileTabAliases = const <String, List<String>>{},
  });

  final String appId;
  final NavStyle style;
  final List<NavSectionSpec> sections;

  /// 手机端底部 tab（契约 `nav.mobile.tabs`）。空 = 手机端不显示底部 tab。
  /// 末项可以是 [kNavMoreTabId]，表示「更多」整页。
  final List<String> mobileTabs;

  /// 底部 tab 的文案覆盖（tab id → i18n 键）。不给就用菜单项自己的 labelKey。
  final Map<String, String> mobileTabLabels;

  /// 选中别名：tab → 菜单项 id 列表。用于「一个 tab 涵盖多个菜单项」
  /// （如影视的「库」tab 同时涵盖 `home` 与动态的 `lib:<id>`）。
  final Map<String, List<String>> mobileTabAliases;

  bool get hasMobileTabs => mobileTabs.isNotEmpty;

  /// 全部静态项 id（不含动态项），用于「契约 ↔ 实现」对账与测试遍历
  Iterable<String> get staticItemIds => sections
      .expand((s) => s.items)
      .where((i) => !i.isDynamic)
      .map((i) => i.id);

  /// 按 id 取菜单项（不含动态项）；找不到返回 null
  NavItemSpec? itemById(String id) {
    for (final section in sections) {
      for (final item in section.items) {
        if (!item.isDynamic && item.id == id) return item;
      }
    }
    return null;
  }
}

/// 契约里表示「更多」的伪 tab id
const String kNavMoreTabId = '@more';

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
          NavItemSpec(id: 'favorites', labelKey: 'nav.favorites', icon: 'favorite_outline'),
          NavItemSpec(id: 'folders', labelKey: 'nav.filesView', icon: 'folder_outlined'),
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
          NavItemSpec(id: 'timeContrast', labelKey: 'photo.nav.timeContrast', icon: 'history'),
          NavItemSpec(id: 'journey', labelKey: 'photo.nav.journey', icon: 'travel_explore_outlined'),
          NavItemSpec(id: 'growth', labelKey: 'photo.nav.growth', icon: 'timeline_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'albums',
        titleKey: 'ui.photo.053',
        icon: 'collections_bookmark_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'album', labelKey: 'ui.photo.053', icon: 'photo_album_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'ai',
        titleKey: 'photo.nav.ai',
        icon: 'auto_awesome_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'photoAiCenter', labelKey: 'photo.nav.aiCenter', icon: 'auto_awesome_outlined'),
          NavItemSpec(id: 'assistant', labelKey: 'photo.nav.assistant', icon: 'help_outline'),
          NavItemSpec(id: 'faces', labelKey: 'ui.photo.038', icon: 'face_retouching_natural_outlined'),
          NavItemSpec(id: 'relations', labelKey: 'photo.relations.title', icon: 'hub_outlined'),
          NavItemSpec(id: 'scenes', labelKey: 'ui.photo.036', icon: 'landscape_outlined'),
          NavItemSpec(id: 'activities', labelKey: 'photo.nav.activities', icon: 'sports_handball_outlined'),
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
          NavItemSpec(id: 'aiSettings', labelKey: 'photo.nav.aiSettings', icon: 'tag_faces_outlined', when: 'superAdmin'),
          NavItemSpec(id: 'trash', labelKey: 'photo.nav.trash', icon: 'delete_sweep_outlined'),
          NavItemSpec(id: 'backup', labelKey: 'photo.nav.backup', icon: 'cloud_upload_outlined', when: 'mobileApp'),
        ],
      ),
    ],
    mobileTabs: <String>['timeline', 'footprint', 'album', 'photoAiCenter', '@more'],
    mobileTabLabels: <String, String>{'timeline': 'ui.photo.041'},
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
          NavItemSpec(id: 'favorites', labelKey: 'nav.favorites', icon: 'favorite_outline'),
          NavItemSpec(id: 'jp_rank', labelKey: 'video.nav.jpRank', icon: 'leaderboard_outlined', when: 'hasJpLibrary'),
          NavItemSpec(id: 'jp_actor', labelKey: 'video.nav.jpActor', icon: 'people_outline', when: 'hasJpLibrary'),
          NavItemSpec(id: 'browse', labelKey: 'video.browse.title', icon: 'photo_library_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'collections',
        titleKey: 'video.collection.group',
        icon: 'collections_bookmark_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'collections', labelKey: 'video.collection.title', icon: 'collections_bookmark_outlined'),
          NavItemSpec(id: 'duplicates', labelKey: 'video.duplicate.title', icon: 'content_copy_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'settings',
        titleKey: 'video.nav.settingsGroup',
        icon: 'settings_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'settings.library', labelKey: 'video.nav.librarySettings', icon: 'video_library_outlined', when: 'superAdmin'),
          NavItemSpec(id: 'settings.app', labelKey: 'video.nav.appSettings', icon: 'tune', when: 'superAdmin'),
          NavItemSpec(id: 'settings.client', labelKey: 'video.nav.clientSettings', icon: 'devices'),
        ],
      ),
    ],
    mobileTabs: <String>['home', 'history', 'collections', 'favorites', '@more'],
    mobileTabLabels: <String, String>{'home': 'video.nav.libraries'},
    mobileTabAliases: <String, List<String>>{'home': <String>['lib']},
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
    mobileTabs: <String>['discover', 'pt', 'rss', 'tasks', 'settings'],
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
          NavItemSpec(id: 'songs', labelKey: 'music.nav.songs', icon: 'music_note_outlined'),
          NavItemSpec(id: 'favorites', labelKey: 'nav.favorites', icon: 'favorite_outline'),
          NavItemSpec(id: 'history', labelKey: 'music.nav.history', icon: 'history_outlined'),
          NavItemSpec(id: 'albums', labelKey: 'music.nav.albums', icon: 'album_outlined'),
          NavItemSpec(id: 'artists', labelKey: 'music.nav.artists', icon: 'people_outlined'),
          NavItemSpec(id: 'files', labelKey: 'nav.filesView', icon: 'folder_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'playlists',
        titleKey: 'ui.music.010',
        icon: 'queue_music',
        items: <NavItemSpec>[
          NavItemSpec(id: 'playlists', labelKey: 'ui.music.030', icon: 'queue_music_outlined'),
        ],
      ),
      NavSectionSpec(
        id: 'settings',
        titleKey: 'ui.settings.017',
        icon: 'settings_outlined',
        items: <NavItemSpec>[
          NavItemSpec(id: 'settings.source', labelKey: 'music.nav.sources', icon: 'folder_outlined', when: 'superAdmin'),
          NavItemSpec(id: 'settings.app', labelKey: 'music.nav.appSettings', icon: 'tune', when: 'superAdmin'),
          NavItemSpec(id: 'settings.client', labelKey: 'music.nav.cache', icon: 'devices'),
        ],
      ),
    ],
    mobileTabs: <String>['songs', 'playlists', 'favorites', 'history', '@more'],
    mobileTabLabels: <String, String>{'songs': 'music.nav.songs'},
  ),
  'blog': AppNavSpec(
    appId: 'blog',
    style: NavStyle.side,
    sections: <NavSectionSpec>[
      NavSectionSpec(
        id: 'content',
        titleKey: 'blog.nav.content',
        icon: 'podcast',
        items: <NavItemSpec>[
          NavItemSpec(id: 'aiNews', labelKey: 'blog.nav.aiNews', icon: 'newspaper_outlined'),
        ],
      ),
    ],
  ),
  'sync': AppNavSpec(
    appId: 'sync',
    style: NavStyle.side,
    sections: <NavSectionSpec>[
      NavSectionSpec(
        id: 'main',
        titleKey: 'sync.menu.group',
        icon: 'sync',
        items: <NavItemSpec>[
          NavItemSpec(id: 'tasks', labelKey: 'sync.menu.tasks', icon: 'sync'),
          NavItemSpec(id: 'help', labelKey: 'sync.menu.help', icon: 'help_outline'),
        ],
      ),
    ],
    mobileTabs: <String>['tasks', 'help'],
  ),
};

/// 取某个 App 的菜单结构（没有二级菜单时返回 null）
AppNavSpec? appNavSpecOf(String appId) => kAppNavSpecs[appId];
