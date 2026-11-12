// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/apps.json#capabilities
// regenerate: npm run gen:caps

/// 端能力矩阵的 6 端形态（docs/04 §64）。
enum CapabilityEndpoint {
  desktop,
  mobile,
  web,
  tvAndroid,
  tvApple,
  harmony,
}

/// 6 类功能能力（docs/04 §64 的行）。
enum Capability {
  files,
  photo,
  video,
  music,
  terminal,
  system,
}

/// 某端对某能力的支持档位：完整 / 受限或降级 / 不提供。
enum CapabilityLevel {
  full,
  limited,
  none,
}

/// 一项能力在 6 端的档位声明。
class CapabilityEntry {
  const CapabilityEntry({
    required this.id,
    required this.nameKey,
    required this.appIds,
    required this.levels,
  });

  /// 能力 id（`files` / `photo` / `video` / `music` / `terminal` / `system`）
  final String id;

  /// 能力名文案键（复用 App 名称，见 l10n/keys.dart）。
  final String nameKey;

  /// 归属该能力的 App id（外壳据此判断当前页是否需要提示）。
  final List<String> appIds;

  /// 端 → 档位；契约未声明的端一律视为 [CapabilityLevel.none]。
  final Map<CapabilityEndpoint, CapabilityLevel> levels;

  CapabilityLevel levelOn(CapabilityEndpoint endpoint) =>
      levels[endpoint] ?? CapabilityLevel.none;

  bool coversApp(String appId) => appIds.contains(appId);
}

/// 生成自 `contracts/apps.json#capabilities`；改矩阵只需改契约后重跑 `npm run gen:caps`。
class CapabilityMatrix {
  static const List<CapabilityEntry> entries = <CapabilityEntry>[
    CapabilityEntry(
      id: 'files',
      nameKey: 'app.files',
      appIds: <String>['files'],
      levels: <CapabilityEndpoint, CapabilityLevel>{
        CapabilityEndpoint.desktop: CapabilityLevel.full,
        CapabilityEndpoint.mobile: CapabilityLevel.full,
        CapabilityEndpoint.web: CapabilityLevel.limited,
        CapabilityEndpoint.tvAndroid: CapabilityLevel.limited,
        CapabilityEndpoint.tvApple: CapabilityLevel.none,
        CapabilityEndpoint.harmony: CapabilityLevel.full,
      },
    ),
    CapabilityEntry(
      id: 'photo',
      nameKey: 'app.photo',
      appIds: <String>['photo'],
      levels: <CapabilityEndpoint, CapabilityLevel>{
        CapabilityEndpoint.desktop: CapabilityLevel.full,
        CapabilityEndpoint.mobile: CapabilityLevel.full,
        CapabilityEndpoint.web: CapabilityLevel.full,
        CapabilityEndpoint.tvAndroid: CapabilityLevel.full,
        CapabilityEndpoint.tvApple: CapabilityLevel.full,
        CapabilityEndpoint.harmony: CapabilityLevel.full,
      },
    ),
    CapabilityEntry(
      id: 'video',
      nameKey: 'app.video',
      appIds: <String>['video'],
      levels: <CapabilityEndpoint, CapabilityLevel>{
        CapabilityEndpoint.desktop: CapabilityLevel.full,
        CapabilityEndpoint.mobile: CapabilityLevel.full,
        CapabilityEndpoint.web: CapabilityLevel.full,
        CapabilityEndpoint.tvAndroid: CapabilityLevel.full,
        CapabilityEndpoint.tvApple: CapabilityLevel.full,
        CapabilityEndpoint.harmony: CapabilityLevel.full,
      },
    ),
    CapabilityEntry(
      id: 'music',
      nameKey: 'app.music',
      appIds: <String>['music'],
      levels: <CapabilityEndpoint, CapabilityLevel>{
        CapabilityEndpoint.desktop: CapabilityLevel.full,
        CapabilityEndpoint.mobile: CapabilityLevel.full,
        CapabilityEndpoint.web: CapabilityLevel.full,
        CapabilityEndpoint.tvAndroid: CapabilityLevel.full,
        CapabilityEndpoint.tvApple: CapabilityLevel.full,
        CapabilityEndpoint.harmony: CapabilityLevel.full,
      },
    ),
    CapabilityEntry(
      id: 'terminal',
      nameKey: 'app.terminal',
      appIds: <String>['terminal'],
      levels: <CapabilityEndpoint, CapabilityLevel>{
        CapabilityEndpoint.desktop: CapabilityLevel.full,
        CapabilityEndpoint.mobile: CapabilityLevel.none,
        CapabilityEndpoint.web: CapabilityLevel.none,
        CapabilityEndpoint.tvAndroid: CapabilityLevel.none,
        CapabilityEndpoint.tvApple: CapabilityLevel.none,
        CapabilityEndpoint.harmony: CapabilityLevel.none,
      },
    ),
    CapabilityEntry(
      id: 'system',
      nameKey: 'app.settings',
      appIds: <String>['settings', 'accounts', 'monitor'],
      levels: <CapabilityEndpoint, CapabilityLevel>{
        CapabilityEndpoint.desktop: CapabilityLevel.full,
        CapabilityEndpoint.mobile: CapabilityLevel.none,
        CapabilityEndpoint.web: CapabilityLevel.limited,
        CapabilityEndpoint.tvAndroid: CapabilityLevel.none,
        CapabilityEndpoint.tvApple: CapabilityLevel.none,
        CapabilityEndpoint.harmony: CapabilityLevel.limited,
      },
    ),
  ];

  static CapabilityEntry? byId(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// 当前 App 对应的能力条目；未声明能力的 App（工作台 / 传输等）返回 null。
  static CapabilityEntry? forApp(String appId) {
    for (final entry in entries) {
      if (entry.coversApp(appId)) return entry;
    }
    return null;
  }

  static CapabilityLevel levelOf(String id, CapabilityEndpoint endpoint) =>
      byId(id)?.levelOn(endpoint) ?? CapabilityLevel.none;

  /// 契约里的端键（`desktop` / `mobile` / `web` / `tv_android` / `tv_apple` / `harmony`）。
  static String keyOf(CapabilityEndpoint endpoint) {
    switch (endpoint) {
      case CapabilityEndpoint.desktop:
        return 'desktop';
      case CapabilityEndpoint.mobile:
        return 'mobile';
      case CapabilityEndpoint.web:
        return 'web';
      case CapabilityEndpoint.tvAndroid:
        return 'tv_android';
      case CapabilityEndpoint.tvApple:
        return 'tv_apple';
      case CapabilityEndpoint.harmony:
        return 'harmony';
    }
  }
}
