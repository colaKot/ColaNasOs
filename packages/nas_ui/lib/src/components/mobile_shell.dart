import 'package:flutter/material.dart';

import '../i18n.dart';
import '../tokens.dart';
import 'panel.dart';
import 'side_nav.dart';

/// 手机端外壳：**一套实现，所有模块共用**。
///
/// 形态与桌面完全不同（不是把侧栏压窄）：
/// ```
/// ┌──────────────────────────────┐
/// │ [🏠] 标题 ………………………… [动作] │  ← NasMobileAppBar（56 + 状态栏）
/// ├──────────────────────────────┤
/// │            内容               │
/// ├──────────────────────────────┤
/// │  tab1  tab2  tab3  tab4 更多  │  ← NasBottomTabBar
/// └──────────────────────────────┘
/// ```
///
/// 桌面三栏（分组侧栏 + 顶栏 + 内容）仍由 `AppShell` + `NasSideNav` 负责，
/// 两者互不影响；断点由调用方判断（`layoutFor(width) == LayoutMode.compact`）。

/// 底部 tab 的一项。
class NasTabItem {
  const NasTabItem({
    required this.id,
    required this.label,
    required this.icon,
  });

  /// 菜单项 id；「更多」用 [moreId]
  final String id;
  final String label;
  final IconData icon;

  /// 契约里表示「更多」的伪 tab id（与 `kNavMoreTabId` 同值）
  static const String moreId = '@more';

  bool get isMore => id == moreId;
}

/// 手机顶栏：高度 56（另加状态栏），左侧房子/返回，右侧动作。
///
/// [bottom] 用来挂模块自己的分类 TabBar（音乐那种"顶栏内嵌 5 个分类"的形态），
/// 挂了以后整体高度 = 56 + bottom 高度，仍然是一块连续的底色。
class NasMobileAppBar extends StatelessWidget implements PreferredSizeWidget {
  const NasMobileAppBar({
    super.key,
    required this.title,
    this.onHome,
    this.onBack,
    this.actions = const [],
    this.bottom,
    this.transparent = false,
    this.automaticallyImplyLeading = false,
    this.homeTooltip,
  });

  /// 标题；空串 = 不显示文字（只剩按钮，给沉浸页留位）
  final String title;

  /// 点房子：回工作台
  final VoidCallback? onHome;

  /// 点返回：回上一级（与 [onHome] 二选一，[onBack] 优先）
  final VoidCallback? onBack;

  final List<Widget> actions;
  final PreferredSizeWidget? bottom;

  /// 透明底（浮在图片/海报上）
  final bool transparent;

  final bool automaticallyImplyLeading;

  /// 房子按钮的 tooltip（默认用系统的「返回」，不合适，调用方应传「工作台」）
  final String? homeTooltip;

  static const double barHeight = 56;

  @override
  Size get preferredSize => Size.fromHeight(
    barHeight + (bottom?.preferredSize.height ?? 0),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = transparent ? Colors.transparent : scheme.surface;

    final leading = onBack != null
        ? _RoundIconButton(
            icon: Icons.arrow_back,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: onBack,
            background: transparent ? scheme.surface.withValues(alpha: 0.78) : null,
            border: transparent ? scheme.onSurface.withValues(alpha: 0.12) : null,
          )
        // 房子是手机端的固定锚点：**任何一级页都有**，即使调用方没给回调
        // （点击无效也比"这页没有房子"好排查）。
        : _RoundIconButton(
            icon: Icons.home_outlined,
            tooltip: homeTooltip ??
                MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: onHome ?? () {},
            background: transparent ? scheme.surface.withValues(alpha: 0.78) : null,
            border: transparent ? scheme.onSurface.withValues(alpha: 0.12) : null,
          );

    return ColoredBox(
      color: bg,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: barHeight,
              child: Row(
                children: [
                  const SizedBox(width: NasTokens.spaceXs),
                  // leading 恒非空：没给 onHome/onBack 时也要有房子（见上面的注释）
                  leading,
                  const SizedBox(width: NasTokens.spaceXs),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontSubtitle,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  ...actions,
                  const SizedBox(width: NasTokens.spaceXs),
                ],
              ),
            ),
            if (bottom != null) bottom!,
            if (!transparent)
              Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
          ],
        ),
      ),
    );
  }
}

/// 顶栏里的圆形/圆角图标按钮（手机端尺寸 36，比桌面 32 大一档，方便拇指点）。
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.background,
    this.border,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? background;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = Material(
      color: background ?? Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: border == null ? null : Border.all(color: border!),
          ),
          child: Icon(icon, size: NasTokens.iconMd, color: scheme.onSurface),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 顶栏动作按钮（给模块放"回收站 / 设置 / 新建"这类）。
class NasMobileAction extends StatelessWidget {
  const NasMobileAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _RoundIconButton(icon: icon, tooltip: tooltip, onPressed: onPressed);
  }
}

/// 底部 tab 栏：`BottomNavigationBar` + 顶部 1px 分隔，最多 5 项。
///
/// [selectedId] 是**菜单项 id**，不一定等于 tab id：影视的「库」tab 涵盖
/// `home` 与动态的 `lib:<id>`，靠 [aliases] 做匹配。
class NasBottomTabBar extends StatelessWidget {
  const NasBottomTabBar({
    super.key,
    required this.items,
    required this.selectedId,
    required this.onSelect,
    this.aliases = const <String, List<String>>{},
    this.activeTabId,
  });

  final List<NasTabItem> items;

  /// 当前选中的菜单项 id（如 `timeline` / `lib:3` / `@more`）
  final String selectedId;

  /// 点 tab 回调，参数是 tab id
  final ValueChanged<String> onSelect;

  /// tab id → 额外归入本 tab 的菜单项 id 前缀（契约 `nav.mobile.aliases`）
  final Map<String, List<String>> aliases;

  /// 强制指定高亮的 tab（选中项不在任何 tab 里时，调用方自己决定停在哪）
  final String? activeTabId;

  /// 某个菜单项是否属于该 tab
  bool matches(String tabId, String itemId) {
    if (tabId == itemId) return true;
    if (itemId.startsWith('$tabId:')) return true;
    for (final alias in aliases[tabId] ?? const <String>[]) {
      if (itemId == alias || itemId.startsWith('$alias:')) return true;
    }
    return false;
  }

  int get selectedIndex {
    final forced = activeTabId;
    if (forced != null) {
      final i = items.indexWhere((t) => t.id == forced);
      if (i >= 0) return i;
    }
    final i = items.indexWhere((t) => matches(t.id, selectedId));
    return i < 0 ? items.length - 1 : i;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: BottomNavigationBar(
          currentIndex: selectedIndex,
          onTap: (i) {
            if (i < 0 || i >= items.length) return;
            onSelect(items[i].id);
          },
          backgroundColor: scheme.surface,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: scheme.primary,
          unselectedItemColor: scheme.onSurfaceVariant,
          selectedFontSize: NasTokens.fontMicro,
          unselectedFontSize: NasTokens.fontMicro,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
          items: [
            for (final item in items)
              BottomNavigationBarItem(
                icon: Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Icon(item.icon, size: NasTokens.iconLg),
                ),
                label: item.label,
              ),
          ],
        ),
      ),
    );
  }
}

/// 「更多」整页：把侧栏剩下没进底部 tab 的菜单项按原分组列出来。
///
/// 为什么是整页而不是半屏 sheet：相册剩 12 项、影视剩 9 项，
/// sheet 里既滚不动也看不清分组。
class NasMorePage extends StatelessWidget {
  const NasMorePage({
    super.key,
    required this.title,
    required this.groups,
    required this.onSelect,
  });

  final String title;
  final List<NasNavGroup> groups;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceMd,
        NasTokens.spaceXl,
      ),
      children: [
        for (final group in groups) ...[
          if (group.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                top: NasTokens.spaceMd,
                bottom: NasTokens.spaceXs,
              ),
              child: Text(
                group.title,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          NasPanel(
            padding: EdgeInsets.zero,
            // ListTile 需要 Material 祖先（水波纹 + 文本样式）。NasPanel 是
            // Container，不提供 Material —— 少了这层，把「更多」放进非 Scaffold
            // 容器时直接抛 "No Material widget found"。
            child: Material(
              color: Colors.transparent,
              child: Column(
                children: [
                  for (var i = 0; i < group.entries.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        indent: 48,
                        color: scheme.outlineVariant,
                      ),
                    ListTile(
                      dense: false,
                      leading: Icon(
                        group.entries[i].icon,
                        size: NasTokens.iconMd,
                        color: scheme.onSurface,
                      ),
                      title: Text(
                        group.entries[i].label,
                        style: TextStyle(
                          fontSize: NasTokens.fontBody,
                          color: scheme.onSurface,
                        ),
                      ),
                      trailing: Icon(
                        Icons.chevron_right,
                        size: NasTokens.iconSm,
                        color: scheme.onSurfaceVariant,
                      ),
                      onTap: () => onSelect(group.entries[i].id),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 手机端整页骨架：顶栏 + 内容 + 底部 tab（可选悬浮条）。
///
/// 模块只需要给 `items / selectedId / onSelect / body`，不要再自己拼 Scaffold。
class NasAppScaffold extends StatelessWidget {
  const NasAppScaffold({
    super.key,
    required this.title,
    required this.body,
    required this.items,
    required this.selectedId,
    required this.onSelect,
    this.onHome,
    this.onBack,
    this.actions = const [],
    this.appBarBottom,
    this.floatingBar,
    this.bulkBar,
    this.aliases = const <String, List<String>>{},
    this.activeTabId,
    this.showTabs = true,
    this.backgroundColor,
    this.homeTooltip,
  });

  final String title;
  final Widget body;
  final List<NasTabItem> items;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback? onHome;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final PreferredSizeWidget? appBarBottom;

  /// 浮在内容底部的条（相册的"全部/年份/今天/收藏"、音乐的播放条）
  final Widget? floatingBar;

  /// 多选态工具条。非空时**顶掉**底部 tab（基线行为：多选时不让人切模块）
  final Widget? bulkBar;

  final Map<String, List<String>> aliases;
  final String? activeTabId;
  final bool showTabs;
  final Color? backgroundColor;
  final String? homeTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasTabs = showTabs && items.isNotEmpty;

    return Scaffold(
      backgroundColor: backgroundColor ?? scheme.surface,
      body: Column(
        children: [
          NasMobileAppBar(
            title: title,
            onHome: onHome,
            onBack: onBack,
            actions: actions,
            bottom: appBarBottom,
            homeTooltip: homeTooltip,
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: body),
                if (floatingBar != null)
                  Positioned(
                    left: NasTokens.spaceMd,
                    right: NasTokens.spaceMd,
                    bottom: 10,
                    child: floatingBar!,
                  ),
              ],
            ),
          ),
          if (bulkBar != null)
            bulkBar!
          else if (hasTabs)
            NasBottomTabBar(
              items: items,
              selectedId: selectedId,
              onSelect: onSelect,
              aliases: aliases,
              activeTabId: activeTabId,
            )
          else
            // 没有底部 tab 时也要吃掉底部安全区，避免内容被系统条压住
            ColoredBox(
              color: scheme.surface,
              child: SafeArea(
                top: false,
                child: const SizedBox(width: double.infinity),
              ),
            ),
        ],
      ),
    );
  }
}

/// 悬浮胶囊条（相册/影视的视图切换）。选中项用主色填充。
class NasFloatingChips extends StatelessWidget {
  const NasFloatingChips({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
    this.scrollable = false,
    this.leading,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// 项多时可横向滚动（影视的库列表）
  final bool scrollable;

  /// 固定在最前面的自定义 chip（如影视的「主页」）
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = <Widget>[
      if (leading != null) leading!,
      for (var i = 0; i < labels.length; i++)
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: _Chip(
            label: labels[i],
            selected: i == selectedIndex,
            onTap: () => onSelect(i),
          ),
        ),
    ];
    final content = scrollable
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: row),
          )
        : Row(
            children: [
              for (var i = 0; i < row.length; i++)
                if (i == 0 && leading != null) row[i] else Expanded(child: row[i]),
            ],
          );
    return Container(
      height: 45,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(22.5),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: content,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            fontWeight: FontWeight.w600,
            color: selected ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

// ── 多选态：内容页 ↔ 外壳 的唯一通道 ─────────────────────────────────────
//
// 多选是一个"模式"，不该让人一边选一边切模块。
//
// 为什么用 InheritedNotifier 而不是给每个页面传 callback：内容页是
// `Widget Function(String key)` 造出来的任意 Widget，外壳拿不到它的 State；
// 让内容页主动往外壳声明「我现在多选、动作有这些」是唯一不解耦的方向。

/// 多选工具条上的一项动作
class NasBulkAction {
  const NasBulkAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool enabled;
}

/// 内容页对「当前多选态」的完整声明
class NasBulkSpec {
  const NasBulkSpec({
    required this.title,
    required this.actions,
    this.onClose,
  });

  /// 左侧文字（如「已选 3 项」）
  final String title;
  final List<NasBulkAction> actions;

  /// 右侧关闭按钮；null = 不显示
  final VoidCallback? onClose;

  /// 幂等比较用：内容页每次 build 后都会重新声明一次，
  /// 内容没变就不该触发外壳重建（否则 publish → rebuild → publish 会自激）。
  String get signature =>
      '$title|${actions.map((a) => '${a.icon.codePoint}:${a.enabled}').join(',')}';
}

/// 多选态控制器：由外壳创建，内容页通过 [NasBulkScope] 拿到
class NasBulkController extends ChangeNotifier {
  NasBulkSpec? _spec;
  NasBulkSpec? get spec => _spec;

  void show(NasBulkSpec spec) {
    if (_spec?.signature == spec.signature) return;
    _spec = spec;
    notifyListeners();
  }

  void hide() {
    if (_spec == null) return;
    _spec = null;
    notifyListeners();
  }
}

/// 把 [NasBulkController] 放进 widget 树
class NasBulkScope extends InheritedNotifier<NasBulkController> {
  const NasBulkScope({
    super.key,
    required NasBulkController super.notifier,
    required super.child,
  });

  /// 取控制器但**不注册依赖**（内容页只是往上报，不需要因为外壳重建而重建）
  static NasBulkController? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<NasBulkScope>()
      ?.notifier;
}

/// 多选工具条（替换底部 tab 的那一条）
class NasBulkBar extends StatelessWidget {
  const NasBulkBar({super.key, required this.spec});

  final NasBulkSpec spec;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              const SizedBox(width: NasTokens.spaceMd),
              Expanded(
                child: Text(
                  spec.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final action in spec.actions)
                _BulkButton(
                  icon: action.icon,
                  tooltip: action.tooltip,
                  onPressed: action.enabled ? action.onPressed : null,
                ),
              if (spec.onClose != null)
                _BulkButton(
                  icon: Icons.close,
                  tooltip: tr('common.cancel'),
                  onPressed: spec.onClose,
                ),
              const SizedBox(width: NasTokens.spaceXs),
            ],
          ),
        ),
      ),
    );
  }
}

class _BulkButton extends StatelessWidget {
  const _BulkButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = onPressed == null
        ? scheme.onSurface.withValues(alpha: 0.38)
        : scheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 24,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: NasTokens.iconMd, color: color),
        ),
      ),
    );
  }
}
