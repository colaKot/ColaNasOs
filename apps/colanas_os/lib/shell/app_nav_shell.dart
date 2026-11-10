import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../core/settings_store.dart';
import 'app_visuals.dart';
import 'nav_spec_adapter.dart';
import 'shell_back.dart';

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

  /// 手机端「回工作台」的全局回调：由 [AppShell] 在 initState 注册。
  ///
  /// 为什么不走构造参数：四个模块页在 `AppShell._pageById` 里是 `const` 实例，
  /// 拿不到父级 State；而为了一个回调把四个 shell 的构造全改一遍并不划算。
  /// 桌面端不会用到（桌面没有房子按钮）。
  static VoidCallback? onExitToHome;

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

  /// 手机端当前底部 tab。空 = 该 App 没有配 `nav.mobile`（不显示底部 tab）
  String _mobileTab = '';

  /// 从「更多」里打开的菜单项。非空时 body 显示它，底部仍停在「更多」
  String? _fromMoreKey;

  late bool _collapsed =
      SettingsStore.instance.getBool(_collapsedKey) ?? false;

  /// 手机端「多选态」通道：内容页往上声明，底部 tab 让位给工具条
  final NasBulkController _bulk = NasBulkController();

  /// 用户最后一次**通过菜单**选中的项。
  ///
  /// 页面内快捷入口（如首页「那年今日」卡片、`PhotoAiCenterPage` 的跳转）改选中项时
  /// 不动它，外壳就能判断「现在不是菜单页」并在顶栏显示「返回上一层」。
  /// 这是 2026-11-06「三级界面全都加返回按钮」的统一入口，不用每个页面自己注册。
  String? _lastMenuKey;

  String get _collapsedKey => 'ui.nav.collapsed.${widget.appId}';

  String get _key => widget.selection?.key ?? _localKey;

  @override
  void initState() {
    super.initState();
    _localKey = widget.defaultKey;
    _lastMenuKey = widget.defaultKey;
    _mobileTab = _tabOf(widget.defaultKey);
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

  /// 手机端首屏校正只做一次
  bool _mobileInit = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mobileInit) return;
    _mobileInit = true;
    if (layoutFor(MediaQuery.sizeOf(context).width) != LayoutMode.compact) return;
    final tabs = _spec.mobileTabs;
    if (tabs.isEmpty) return;
    // 手机端首屏必须落在某个底部 tab 上。defaultKey（相册是 `home`）不在 tab 列表里时，
    // 会出现「底部高亮照片、内容却是首页」，而首页在手机上根本没有 tab 入口
    // ——2026-11-04 用户要求：相册打开默认在时间轴，移动端不显示首页。
    if (tabs.any((t) => t != kNavMoreTabId && _tabMatches(t, _key))) return;
    final first = tabs.firstWhere((t) => t != kNavMoreTabId, orElse: () => '');
    if (first.isEmpty) return;
    _mobileTab = first;
    _lastMenuKey = first;
    // 这里直接改字段而不 setState：didChangeDependencies 之后紧接着就会 build。
    final selection = widget.selection;
    if (selection != null) {
      selection.key = first;
    } else {
      _localKey = first;
    }
  }

  @override
  void dispose() {
    widget.selection?.removeListener(_onSelectionChanged);
    _bulk.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    // 页面内快捷入口（如相册首页卡片）改了选中项：底部 tab 跟着走，
    // 否则手机端会停在旧 tab 上、内容却换了一页。
    // 从「更多」进入的项不动 tab —— 那是 _selectFromMore 自己管的。
    if (_fromMoreKey != null) {
      setState(() {});
      return;
    }
    final tab = _tabOf(_key);
    setState(() {
      if (tab.isNotEmpty) _mobileTab = tab;
    });
  }

  void _select(String id) {
    final selection = widget.selection;
    final tab = _tabOf(id);
    // 换模块必须退出多选：否则工具条会挂在新页面上，点下去操作的是旧页面
    _bulk.hide();
    setState(() {
      _lastMenuKey = id;
      if (tab.isNotEmpty) _mobileTab = tab;
      _fromMoreKey = null;
      if (selection == null) _localKey = id;
    });
    if (selection != null) selection.select(id);
  }

  /// 从「更多」页进入某一项：内容换、底部仍高亮「更多」
  void _selectFromMore(String id) {
    final selection = widget.selection;
    _bulk.hide();
    setState(() {
      _lastMenuKey = id;
      _fromMoreKey = id;
      _mobileTab = kNavMoreTabId;
      if (selection == null) _localKey = id;
    });
    if (selection != null) selection.select(id);
  }

  /// 顶栏「返回上一层」：回到用户最后一次点菜单选中的那一项。
  /// 页面内下钻（人脸簇 / 文件夹 / 演员详情等）由 [SubPageScope] 自己压栈，
  /// 优先级更高，所以多级下钻会一层一层退。
  void _backToMenu() {
    final target = _lastMenuKey;
    if (target == null || target == _key) return;
    final selection = widget.selection;
    setState(() {
      _fromMoreKey = null;
      if (selection == null) _localKey = target;
    });
    if (selection != null) selection.select(target);
  }

  void _onMobileTabTap(String tabId) {
    if (tabId == kNavMoreTabId) {
      _bulk.hide();
      setState(() {
        _mobileTab = kNavMoreTabId;
        _fromMoreKey = null;
      });
      return;
    }
    _select(tabId);
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

  // ── 手机端：底部 tab ────────────────────────────────────────────────

  bool _tabMatches(String tabId, String itemId) {
    if (tabId == itemId) return true;
    if (itemId.startsWith('$tabId:')) return true;
    for (final alias in _spec.mobileTabAliases[tabId] ?? const <String>[]) {
      if (itemId == alias || itemId.startsWith('$alias:')) return true;
    }
    return false;
  }

  /// 某个菜单项归属哪个 tab（动态项 `lib:3` 归到声明了 alias 的 tab）。
  /// 找不到就退回当前 tab（不强行跳，避免页面内跳转把底部栏带跑偏）。
  String _tabOf(String itemId) {
    final tabs = _spec.mobileTabs;
    if (tabs.isEmpty) return '';
    for (final t in tabs) {
      if (t != kNavMoreTabId && _tabMatches(t, itemId)) return t;
    }
    return _mobileTab.isNotEmpty ? _mobileTab : tabs.first;
  }

  String _tabLabel(String id) {
    final override = _spec.mobileTabLabels[id];
    if (override != null) return tr(override);
    final item = _spec.itemById(id);
    if (item?.labelKey != null) return tr(item!.labelKey!);
    return navItemLabel(_spec, id, tr);
  }

  IconData _tabIcon(String id) =>
      AppVisuals.iconFor(_spec.itemById(id)?.icon ?? '');

  List<NasTabItem> get _mobileTabItems => [
    for (final t in _spec.mobileTabs)
      if (t == kNavMoreTabId)
        NasTabItem(id: kNavMoreTabId, label: tr('nav.more'), icon: Icons.more_horiz)
      else
        NasTabItem(id: t, label: _tabLabel(t), icon: _tabIcon(t)),
  ];

  /// 「更多」页：侧栏里没进底部 tab 的那些项，按原分组列出。
  List<NasNavGroup> _moreGroups() {
    final covered = <String>{};
    for (final t in _spec.mobileTabs) {
      if (t == kNavMoreTabId) continue;
      covered.add(t);
      covered.addAll(_spec.mobileTabAliases[t] ?? const <String>[]);
    }
    bool isCovered(String id) => covered.any((c) => id == c || id.startsWith('$c:'));

    final groups = buildNavGroups(
      spec: _spec,
      translate: tr,
      dynamic: widget.dynamic,
      conditions: widget.conditions,
    );
    return [
      for (final g in groups)
        if (g.entries.any((e) => !isCovered(e.id)))
          NasNavGroup(
            title: g.title,
            entries: [
              for (final e in g.entries)
                if (!isCovered(e.id)) e,
            ],
          ),
    ];
  }

  bool get _showingMorePage =>
      _mobileTab == kNavMoreTabId && _fromMoreKey == null;

  Widget _mobileBody() {
    if (_showingMorePage) {
      return NasMorePage(
        title: tr('nav.more'),
        groups: _moreGroups(),
        onSelect: _selectFromMore,
      );
    }
    return KeyedSubtree(
      key: ValueKey('${widget.appId}:$_key'),
      child: widget.content(_key),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 顶栏返回统一在这里注册：用户从菜单选的项记在 _lastMenuKey，
    // 页面内跳转 / 下钻导致的「当前项 ≠ 菜单项」就自动出现返回按钮。
    // 页面内部再下钻时用 SubPageScope 压第二层，返回会一层层退。
    return ShellBackScope(
      appId: widget.appId,
      child: SubPageScope(
        active: _lastMenuKey != null && _key != _lastMenuKey,
        onBack: _backToMenu,
        child: _buildShell(context),
      ),
    );
  }

  Widget _buildShell(BuildContext context) {
    // 手机端：顶栏（房子）+ 内容 + 底部二级菜单。桌面端不受影响。
    if (layoutFor(MediaQuery.sizeOf(context).width) == LayoutMode.compact) {
      // 桌面右上角由 AppShell 的 NasTopBar 渲染；手机左上角也读同一个 ShellBack，
      // 这样同一套下钻逻辑在两端都有返回入口。
      return ValueListenableBuilder<int>(
        valueListenable: ShellBack.revision,
        builder: (context, _, _) {
          final back = ShellBack.handlerFor(widget.appId) ??
              (_fromMoreKey != null
                  ? () => setState(() => _fromMoreKey = null)
                  : null);
          // 多选态由内容页往上声明（NasBulkScope），外壳只负责把底部 tab 换掉
          return AnimatedBuilder(
            animation: _bulk,
            builder: (context, _) {
              final bulk = _bulk.spec;
              return NasBulkScope(
                notifier: _bulk,
                child: NasAppScaffold(
                  title: _showingMorePage ? tr('nav.more') : _title,
                  onHome: AppNavShell.onExitToHome,
                  homeTooltip: tr('nav.home'),
                  onBack: back,
                  items: _mobileTabItems,
                  selectedId: _key,
                  activeTabId: _mobileTab,
                  aliases: _spec.mobileTabAliases,
                  onSelect: _onMobileTabTap,
                  bulkBar: bulk == null ? null : NasBulkBar(spec: bulk),
                  body: _mobileBody(),
                ),
              );
            },
          );
        },
      );
    }

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
          Expanded(
            // 换菜单项就换整棵内容子树：同类页面（PhotoSmartPage 的不同 section）
            // 不会因为 runtimeType 相同而复用 State，把上一页的下钻态带过来。
            child: KeyedSubtree(
              key: ValueKey('${widget.appId}:$_key'),
              child: widget.content(_key),
            ),
          ),
        ],
      ),
    );
  }
}
