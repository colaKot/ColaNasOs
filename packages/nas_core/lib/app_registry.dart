// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/apps.json
// regenerate: npm run gen:apps

/// 客户端形态。AppleTV 为原生壳（ADR-006），其余为 Flutter 同一份代码。
enum ClientEndpoint {
  desktop,
  tablet,
  mobile,
  tv,
  web,
  appleTv,
}

/// 一级菜单的分组。契约里用字符串写，生成成枚举——写错一个字母就编译不过。
enum AppGroup { media, data, service, system }

extension AppGroupI18n on AppGroup {
  /// 侧栏分组标题的 i18n 键（nav.group.media 等）。
  String get i18nKey => 'nav.group.${name}';
}

/// 一个 App（功能域）在 6 端的分发声明。
class AppDescriptor {
  const AppDescriptor({
    required this.id,
    required this.nameKey,
    required this.route,
    required this.icon,
    required this.group,
    required this.accent,
    required this.endpoints,
    required this.available,
  });

  final String id;

  /// i18n 键（见 l10n/keys.dart），名称不硬编码。
  final String nameKey;
  final String route;
  final String icon;

  /// 一级菜单分组（侧栏 / 工作台按它聚合）。
  final AppGroup group;

  /// 工作台卡片渐变的两端颜色（0xAARRGGBB）。
  final List<int> accent;
  final Set<ClientEndpoint> endpoints;

  /// false = 尚未实现，UI 显示为「即将推出」，入口仍注册。
  final bool available;

  bool supports(ClientEndpoint endpoint) => endpoints.contains(endpoint);
}

/// 生成自 contracts/apps.json；新增 App 只需改契约后重跑 npm run gen:apps。
class AppRegistry {
  static const List<AppDescriptor> apps = <AppDescriptor>[
    AppDescriptor(
      id: 'photo',
      nameKey: 'app.photo',
      route: '/photo',
      icon: 'photo',
      group: AppGroup.media,
      accent: <int>[0xFFFF6B6B, 0xFFFF9F43],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.tv, ClientEndpoint.web, ClientEndpoint.appleTv},
      available: true,
    ),
    AppDescriptor(
      id: 'files',
      nameKey: 'app.files',
      route: '/files',
      icon: 'folder',
      group: AppGroup.data,
      accent: <int>[0xFF3B82F6, 0xFF60A5FA],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.tv, ClientEndpoint.web, ClientEndpoint.appleTv},
      available: true,
    ),
    AppDescriptor(
      id: 'video',
      nameKey: 'app.video',
      route: '/video',
      icon: 'movie',
      group: AppGroup.media,
      accent: <int>[0xFF6366F1, 0xFF9F7AEA],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.tv, ClientEndpoint.web, ClientEndpoint.appleTv},
      available: true,
    ),
    AppDescriptor(
      id: 'discover',
      nameKey: 'app.discover',
      route: '/discover',
      icon: 'compass',
      group: AppGroup.media,
      accent: <int>[0xFFF59E0B, 0xFFF97316],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'music',
      nameKey: 'app.music',
      route: '/music',
      icon: 'music',
      group: AppGroup.media,
      accent: <int>[0xFF06B6D4, 0xFF3B82F6],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.tv, ClientEndpoint.web, ClientEndpoint.appleTv},
      available: true,
    ),
    AppDescriptor(
      id: 'book',
      nameKey: 'app.book',
      route: '/book',
      icon: 'book',
      group: AppGroup.media,
      accent: <int>[0xFF10B981, 0xFF059669],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'notes',
      nameKey: 'app.notes',
      route: '/notes',
      icon: 'note',
      group: AppGroup.data,
      accent: <int>[0xFFFBBF24, 0xFFF59E0B],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'netdisk',
      nameKey: 'app.netdisk',
      route: '/netdisk',
      icon: 'cloud',
      group: AppGroup.data,
      accent: <int>[0xFF0EA5E9, 0xFF22D3EE],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'share',
      nameKey: 'app.share',
      route: '/share',
      icon: 'share',
      group: AppGroup.data,
      accent: <int>[0xFFA855F7, 0xFFEC4899],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'backup',
      nameKey: 'app.backup',
      route: '/backup',
      icon: 'backup',
      group: AppGroup.data,
      accent: <int>[0xFF14B8A6, 0xFF10B981],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'ai',
      nameKey: 'app.ai',
      route: '/ai',
      icon: 'sparkles',
      group: AppGroup.system,
      accent: <int>[0xFFA855F7, 0xFF6366F1],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.web},
      available: false,
    ),
    AppDescriptor(
      id: 'monitor',
      nameKey: 'app.monitor',
      route: '/monitor',
      icon: 'pulse',
      group: AppGroup.system,
      accent: <int>[0xFFEF4444, 0xFFF97316],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'sync',
      nameKey: 'app.sync',
      route: '/sync',
      icon: 'sync',
      group: AppGroup.service,
      accent: <int>[0xFF8B5CF6, 0xFF6366F1],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop},
      available: true,
    ),
    AppDescriptor(
      id: 'transfer',
      nameKey: 'app.transfer',
      route: '/transfer',
      icon: 'transfer',
      group: AppGroup.service,
      accent: <int>[0xFF22C55E, 0xFF84CC16],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'messages',
      nameKey: 'app.messages',
      route: '/messages',
      icon: 'bell',
      group: AppGroup.service,
      accent: <int>[0xFFF43F5E, 0xFFFB7185],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'accounts',
      nameKey: 'app.accounts',
      route: '/accounts',
      icon: 'users',
      group: AppGroup.service,
      accent: <int>[0xFF64748B, 0xFF94A3B8],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'mediaTool',
      nameKey: 'app.mediaTool',
      route: '/media-tool',
      icon: 'wand',
      group: AppGroup.service,
      accent: <int>[0xFFD946EF, 0xFF8B5CF6],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.web},
      available: true,
    ),
    AppDescriptor(
      id: 'terminal',
      nameKey: 'app.terminal',
      route: '/terminal',
      icon: 'terminal',
      group: AppGroup.service,
      accent: <int>[0xFF475569, 0xFF1E293B],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop},
      available: true,
    ),
    AppDescriptor(
      id: 'settings',
      nameKey: 'app.settings',
      route: '/settings',
      icon: 'gear',
      group: AppGroup.system,
      accent: <int>[0xFF94A3B8, 0xFF64748B],
      endpoints: <ClientEndpoint>{ClientEndpoint.desktop, ClientEndpoint.tablet, ClientEndpoint.mobile, ClientEndpoint.tv, ClientEndpoint.web, ClientEndpoint.appleTv},
      available: true,
    ),
  ];

  /// 某端可见的入口（含未实现的占位，UI 自行按 available 灰显）。
  static List<AppDescriptor> forEndpoint(ClientEndpoint endpoint) =>
      apps.where((a) => a.supports(endpoint)).toList(growable: false);

  /// 某端已可用的入口。
  static List<AppDescriptor> availableFor(ClientEndpoint endpoint) =>
      apps.where((a) => a.available && a.supports(endpoint)).toList(growable: false);

  static AppDescriptor? byId(String id) {
    for (final app in apps) {
      if (app.id == id) return app;
    }
    return null;
  }
}
