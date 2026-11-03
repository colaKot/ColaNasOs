import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../core/settings_store.dart';
import 'nav_spec_adapter.dart';

/// 二级侧栏的两种宽度：收起（只留图标）56 / 展开（图标 + 4 个汉字）128。
const double kAppNavCollapsedWidth = 56;
const double kAppNavExpandedWidth = 128;

/// 选中项的外部控制器：页面内快捷入口（如相册首页的「回忆」卡）要切换侧栏时用它。
///
/// 不传就由 [AppNavShell] 自己管（绝大多数模块不需要外部改选中项）。
class NavSelection extends ChangeNotifier {
  NavSelection(this.key);

  String key;

  void select(String id) {
    if (key == id) return;
    key = id;
    notifyListeners();
  }
}

/// **二级导航外壳**：左侧栏 + 内容区，一份实现，photo / video / music / discover 共用。
///
/// 为什么要有这个：以前四个模块各写一份「折叠状态 + NasSideNav + 标题 + 竖分隔 + 内容」，
/// 于是折叠态溢出、tooltip 文案、持久化 key 的 bug 都在四份复制里各犯一遍、修三处漏一处
/// （同类事故见 `test/nav_shell_test.dart` 的注释）。现在只需要在契约
/// （`contracts/apps.json#nav`）里写菜单，模块只提供「菜单项 id → 内容」。
///
/// 迁移/新增模块的做法：
///   1. 契约写 `nav.sections`，`npm run gen:apps`；
///   2. 这里传 [appId] + [defaultKey] + [content]（内部仍是 `Widget _content(String key)`
///      switch，`npm run app-nav.check` 靠它做「菜单有项、页面没接」的对账）；
///   3. 需要运行时菜单项（如影视的每个片源）时传 [dynamic]，需要条件项时传 [conditions]。
class AppNavShell extends StatefulWidget {
  const AppNavShell({
    super.key,
    required this.appId,
    required this.defaultKey,
    required this.content,
    this.dynamic = const {},
    this.conditions = const {},
    this.titleOf,
    this.selection,
  });

  /// 契约里的 App id，同时用作折叠状态的持久化 key（`ui.nav.collapsed.<appId>`）
  final String appId;

  /// 首次进入时的选中项
  final String defaultKey;

  /// 菜单项 id → 内容。**必须**保留 `Widget _content(` 这个名字，
  /// 否则 `tool/check/app-nav-check.js` 找不到分发方法、报"菜单没接页面"。
  final Widget Function(String key) content;

  /// 动态菜单项的数据（如影视库列表）
  final Map<String, List<NavDynamicEntry>> dynamic;

  /// 条件菜单项需要的条件集合（如 `hasJpLibrary`）
  final Set<String> conditions;

  /// 自定义标题（动态项用，比如影视库名）。不给就按菜单项 id 反查文案。
  final String Function(String key)? titleOf;

  /// 外部选中项控制器（页面内快捷入口要跳菜单时用）
  final NavSelection? selection;

  @override
  State<AppNavShell> createState() => _AppNavShellState();
}

class _AppNavShellState extends State<AppNavShell> {
  /// 内部选中项（没传 [AppNavShell.selection] 时用）
  String _localKey = '';

  late bool _collapsed =
      SettingsStore.instance.getBool(_collapsedKey) ?? false;

  String get _collapsedKey => 'ui.nav.collapsed.${widget.appId}';

  String get _key => widget.selection?.key ?? _localKey;

  @override
  void initState() {
    super.initState();
    _localKey = widget.defaultKey;
    widget.selection?.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(AppNavShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) {
      oldWidget.selection?.removeListener(_onSelectionChanged);
      widget.selection?.addListener(_onSelectionChanged);
    }
  }

  @override
  void dispose() {
    widget.selection?.removeListener(_onSelectionChanged);
    super.dispose();
  }

  void _onSelectionChanged() => setState(() {});

  void _select(String id) {
    final selection = widget.selection;
    if (selection == null) {
      setState(() => _localKey = id);
    } else {
      selection.select(id);
    }
  }

  AppNavSpec get _spec {
    final spec = kAppNavSpecs[widget.appId];
    assert(spec != null, '${widget.appId} 没有 nav 契约，先在 apps.json 里写 nav');
    return spec!;
  }

  String get _title =>
      widget.titleOf?.call(_key) ??
      navItemLabel(_spec, _key, tr, fallback: tr('app.${widget.appId}'));

  void _toggleCollapsed() {
    setState(() => _collapsed = !_collapsed);
    SettingsStore.instance.setBool(_collapsedKey, _collapsed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NasSideNav(
            groups: buildNavGroups(
              spec: _spec,
              translate: tr,
              dynamic: widget.dynamic,
              conditions: widget.conditions,
            ),
            selectedId: _key,
            onSelect: _select,
            width: _collapsed ? kAppNavCollapsedWidth : kAppNavExpandedWidth,
            iconOnly: _collapsed,
            title: _title,
            onToggleCollapsed: _toggleCollapsed,
            expandTooltip: tr('nav.expand'),
            collapseTooltip: tr('nav.collapse'),
            // 测试用：一级栏与二级栏的菜单项 id 会重名（`home`），key 前加 app 区分
            debugLabel: widget.appId,
          ),
          const VerticalDivider(width: 1),
          Expanded(child: widget.content(_key)),
        ],
      ),
    );
  }
}
