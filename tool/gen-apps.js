#!/usr/bin/env node
/**
 * AppRegistry 生成器（SP1-02）。
 * 输入：contracts/apps.json（App 清单 + 6 端能力矩阵）
 * 输出：packages/nas_core/lib/app_registry.dart
 *
 * 用法：
 *   node tool/gen-apps.js            生成
 *   node tool/gen-apps.js --check    校验磁盘与契约一致
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const src = path.join(root, 'contracts', 'apps.json');
const out = path.join(root, 'packages', 'nas_core', 'lib', 'app_registry.dart');
const checkOnly = process.argv.includes('--check');

const spec = JSON.parse(fs.readFileSync(src, 'utf-8'));

function dartString(s) {
  return `'${String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
}

const GROUPS = ['media', 'data', 'service', 'system'];

/** 契约校验：group 必须是四个枚举之一，accent 必须是两个 #RRGGBB。写错直接失败。 */
function validate() {
  const errors = [];
  const seen = new Set();
  for (const app of spec.apps) {
    if (seen.has(app.id)) errors.push(`${app.id}: id 重复`);
    seen.add(app.id);
    if (!GROUPS.includes(app.group)) {
      errors.push(`${app.id}: group=${JSON.stringify(app.group)} 不在 ${GROUPS.join(' / ')} 内`);
    }
    const a = app.accent;
    if (!Array.isArray(a) || a.length !== 2 || a.some((c) => !/^#[0-9A-Fa-f]{6}$/.test(String(c)))) {
      errors.push(`${app.id}: accent 需要两个 "#RRGGBB"，实际 ${JSON.stringify(a)}`);
    }
  }
  // nav：结构、id 唯一性、动态项必填字段
  for (const app of spec.apps) {
    const nav = app.nav;
    if (!nav) continue;
    const styles = ['side', 'hub', 'none'];
    if (nav.style && !styles.includes(nav.style)) {
      errors.push(`${app.id}.nav.style=${JSON.stringify(nav.style)} 不在 ${styles.join(' / ')} 内`);
    }
    const sectionIds = new Set();
    const itemIds = new Set();
    for (const sec of nav.sections || []) {
      if (!sec.id) errors.push(`${app.id}.nav: section 缺 id`);
      else if (sectionIds.has(sec.id)) errors.push(`${app.id}.nav: section id 重复 ${sec.id}`);
      sectionIds.add(sec.id);
      if (!sec.titleKey) errors.push(`${app.id}.nav.${sec.id}: 缺 titleKey`);
      if (!sec.icon) errors.push(`${app.id}.nav.${sec.id}: 缺 icon`);
      for (const item of sec.items || []) {
        const where = `${app.id}.nav.${sec.id}`;
        if (!item.id) errors.push(`${where}: item 缺 id`);
        else if (itemIds.has(item.id)) errors.push(`${where}: item id 重复 ${item.id}`);
        itemIds.add(item.id);
        // 动态项的图标由数据字段决定（iconFrom），不要求静态 icon
        if (!item.icon && !(item.dynamic && item.iconFrom)) {
          errors.push(`${where}.${item.id}: 缺 icon（动态项请给 iconFrom）`);
        }
        if (item.dynamic) {
          // 动态项：label 与 icon 由运行时数据给，必须有 idPrefix 才能区分
          if (!item.idPrefix) errors.push(`${where}.${item.id}: 动态项缺 idPrefix`);
          if (!item.labelFrom) errors.push(`${where}.${item.id}: 动态项缺 labelFrom`);
        } else if (!item.labelKey) {
          errors.push(`${where}.${item.id}: 缺 labelKey（静态项必填）`);
        }
      }
    }
  }
  return errors;
}

function gen() {
  const lines = [
    '// AUTO-GENERATED. DO NOT EDIT.',
    '// source: contracts/apps.json',
    '// regenerate: npm run gen:apps',
    '',
    '/// 客户端形态。AppleTV 为原生壳（ADR-006），其余为 Flutter 同一份代码。',
    'enum ClientEndpoint {',
    ...spec.endpoints.map((e) => `  ${e},`),
    '}',
    '',
    '/// 一级菜单的分组。契约里用字符串写，生成成枚举——写错一个字母就编译不过。',
    'enum AppGroup { media, data, service, system }',
    '',
    'extension AppGroupI18n on AppGroup {',
    "  /// 侧栏分组标题的 i18n 键（nav.group.media 等）。",
    "  String get i18nKey => 'nav.group.$" + "{name}';",
    '}',
    '',
    '/// 一个 App（功能域）在 6 端的分发声明。',
    'class AppDescriptor {',
    '  const AppDescriptor({',
    '    required this.id,',
    '    required this.nameKey,',
    '    required this.route,',
    '    required this.icon,',
    '    required this.group,',
    '    required this.accent,',
    '    required this.endpoints,',
    '    required this.available,',
    '  });',
    '',
    '  final String id;',
    '',
    '  /// i18n 键（见 l10n/keys.dart），名称不硬编码。',
    '  final String nameKey;',
    '  final String route;',
    '  final String icon;',
    '',
    '  /// 一级菜单分组（侧栏 / 工作台按它聚合）。',
    '  final AppGroup group;',
    '',
    '  /// 工作台卡片渐变的两端颜色（0xAARRGGBB）。',
    '  final List<int> accent;',
    '  final Set<ClientEndpoint> endpoints;',
    '',
    '  /// false = 尚未实现，UI 显示为「即将推出」，入口仍注册。',
    '  final bool available;',
    '',
    '  bool supports(ClientEndpoint endpoint) => endpoints.contains(endpoint);',
    '}',
    '',
    '/// 生成自 contracts/apps.json；新增 App 只需改契约后重跑 npm run gen:apps。',
    'class AppRegistry {',
    '  static const List<AppDescriptor> apps = <AppDescriptor>[',
  ];

  for (const app of spec.apps) {
    const eps = app.endpoints.map((e) => `ClientEndpoint.${e}`).join(', ');
    lines.push('    AppDescriptor(');
    lines.push(`      id: ${dartString(app.id)},`);
    lines.push(`      nameKey: ${dartString(app.nameKey)},`);
    lines.push(`      route: ${dartString(app.route)},`);
    lines.push(`      icon: ${dartString(app.icon)},`);
    lines.push(`      group: AppGroup.${app.group},`);
    const accent = app.accent.map((c) => `0xFF${String(c).replace('#', '').toUpperCase()}`);
    lines.push(`      accent: <int>[${accent.join(', ')}],`);
    lines.push(`      endpoints: <ClientEndpoint>{${eps}},`);
    lines.push(`      available: ${app.available === true},`);
    lines.push('    ),');
  }

  lines.push(
    '  ];',
    '',
    '  /// 某端可见的入口（含未实现的占位，UI 自行按 available 灰显）。',
    '  static List<AppDescriptor> forEndpoint(ClientEndpoint endpoint) =>',
    '      apps.where((a) => a.supports(endpoint)).toList(growable: false);',
    '',
    '  /// 某端已可用的入口。',
    '  static List<AppDescriptor> availableFor(ClientEndpoint endpoint) =>',
    '      apps.where((a) => a.available && a.supports(endpoint)).toList(growable: false);',
    '',
    '  static AppDescriptor? byId(String id) {',
    '    for (final app in apps) {',
    '      if (app.id == id) return app;',
    '    }',
    '    return null;',
    '  }',
    '}',
    '',
  );

  return lines.join('\n');
}

const problems = validate();
if (problems.length > 0) {
  console.error('[gen-apps] 契约校验失败：');
  for (const p of problems) console.error('  - ' + p);
  process.exit(1);
}

const NAV_OUT = path.join(root, 'packages', 'nas_core', 'lib', 'app_nav_spec.dart');

/** 生成二级菜单结构（纯 Dart 数据，不依赖 Flutter） */
function genNav() {
  const apps = spec.apps.filter((a) => a.nav);
  const navStyle = (v) => (v === 'hub' ? 'NavStyle.hub' : v === 'none' ? 'NavStyle.none' : 'NavStyle.side');
  const opt = (v) => (v ? `'${String(v).replace(/'/g, "\\'")}'` : 'null');

  const lines = [
    '// AUTO-GENERATED. DO NOT EDIT.',
    '// source: contracts/apps.json#nav',
    '// regenerate: npm run gen:apps',
    '',
    '/// 二级菜单的呈现形态。',
    '///   - [side]：左侧栏（绝大多数模块）',
    '///   - [hub]：模块自己画的入口页（如「发现」），不渲染侧栏',
    '///   - [none]：没有二级菜单',
    'enum NavStyle { side, hub, none }',
    '',
    '/// 一个菜单项。动态项（[dynamic] 非空）由运行时数据撑开成一串项。',
    'class NavItemSpec {',
    '  const NavItemSpec({',
    '    required this.id,',
    '    this.labelKey,',
    '    this.icon,',
    '    this.dynamic,',
    '    this.idPrefix,',
    '    this.labelFrom,',
    '    this.iconFrom,',
    '    this.when,',
    '  });',
    '',
    '  final String id;',
    '',
    '  /// 静态项的文案键；动态项为 null（文案来自运行时数据）',
    '  final String? labelKey;',
    '',
    '  /// 图标名（见客户端 `AppVisuals.iconFor`）；动态项为 null，用 [iconFrom] 从数据取',
    '  final String? icon;',
    '',
    '  /// 动态项的数据源键，如 `video.libraries`',
    '  final String? dynamic;',
    '',
    '  /// 动态项 id 前缀，如 `lib:`',
    '  final String? idPrefix;',
    '',
    '  /// 动态项从数据对象的哪个字段取文案',
    '  final String? labelFrom;',
    '',
    '  /// 动态项从数据对象的哪个字段取图标',
    '  final String? iconFrom;',
    '',
    '  /// 条件键：只有当该条件为真时才显示（由模块提供）',
    '  final String? when;',
    '',
    '  bool get isDynamic => dynamic != null;',
    '}',
    '',
    'class NavSectionSpec {',
    '  const NavSectionSpec({',
    '    required this.id,',
    '    required this.titleKey,',
    '    required this.icon,',
    '    required this.items,',
    '  });',
    '',
    '  final String id;',
    '  final String titleKey;',
    '  final String icon;',
    '  final List<NavItemSpec> items;',
    '}',
    '',
    'class AppNavSpec {',
    '  const AppNavSpec({required this.appId, required this.style, required this.sections});',
    '',
    '  final String appId;',
    '  final NavStyle style;',
    '  final List<NavSectionSpec> sections;',
    '',
    '  /// 全部静态项 id（不含动态项），用于「契约 ↔ 实现」对账与测试遍历',
    '  Iterable<String> get staticItemIds => sections',
    '      .expand((s) => s.items)',
    '      .where((i) => !i.isDynamic)',
    '      .map((i) => i.id);',
    '}',
    '',
    '/// 有二级菜单的 App（生成自契约，新增模块只要在 apps.json 写 nav）',
    'const Map<String, AppNavSpec> kAppNavSpecs = <String, AppNavSpec>{',
  ];

  for (const app of apps) {
    const nav = app.nav;
    lines.push(`  '${app.id}': AppNavSpec(`);
    lines.push(`    appId: '${app.id}',`);
    lines.push(`    style: ${navStyle(nav.style)},`);
    lines.push('    sections: <NavSectionSpec>[');
    for (const sec of nav.sections || []) {
      lines.push('      NavSectionSpec(');
      lines.push(`        id: '${sec.id}',`);
      lines.push(`        titleKey: '${sec.titleKey}',`);
      lines.push(`        icon: '${sec.icon}',`);
      lines.push('        items: <NavItemSpec>[');
      for (const item of sec.items || []) {
        const parts = [`id: '${item.id}'`];
        if (item.labelKey) parts.push(`labelKey: '${item.labelKey}'`);
        if (item.icon) parts.push(`icon: '${item.icon}'`);
        if (item.dynamic) parts.push(`dynamic: '${item.dynamic}'`);
        if (item.idPrefix) parts.push(`idPrefix: ${opt(item.idPrefix)}`);
        if (item.labelFrom) parts.push(`labelFrom: ${opt(item.labelFrom)}`);
        if (item.iconFrom) parts.push(`iconFrom: ${opt(item.iconFrom)}`);
        if (item.when) parts.push(`when: '${item.when}'`);
        lines.push(`          NavItemSpec(${parts.join(', ')}),`);
      }
      lines.push('        ],');
      lines.push('      ),');
    }
    lines.push('    ],');
    lines.push('  ),');
  }
  lines.push('};', '', '/// 取某个 App 的菜单结构（没有二级菜单时返回 null）', 'AppNavSpec? appNavSpecOf(String appId) => kAppNavSpecs[appId];', '');
  return lines.join('\n');
}

const content = gen();
const prev = fs.existsSync(out) ? fs.readFileSync(out, 'utf-8') : '';

const navContent = genNav();
const navPrev = fs.existsSync(NAV_OUT) ? fs.readFileSync(NAV_OUT, 'utf-8') : '';
const navApps = spec.apps.filter((a) => a.nav).length;

if (checkOnly) {
  let stale = false;
  if (prev !== content) {
    console.error('[gen-apps.check] app_registry.dart 已过期，请运行 npm run gen:apps');
    stale = true;
  }
  if (navPrev !== navContent) {
    console.error('[gen-apps.check] app_nav_spec.dart 已过期，请运行 npm run gen:apps');
    stale = true;
  }
  if (stale) process.exit(1);
  console.log(
    `[gen-apps.check] ok, apps=${spec.apps.length}, endpoints=${spec.endpoints.length}, navApps=${navApps}`,
  );
} else {
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, content, 'utf-8');
  fs.writeFileSync(NAV_OUT, navContent, 'utf-8');
  console.log(
    `[gen-apps] wrote ${path.relative(root, out)} + app_nav_spec.dart apps=${spec.apps.length} navApps=${navApps}`,
  );
}
