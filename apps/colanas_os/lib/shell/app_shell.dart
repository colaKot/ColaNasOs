import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../core/endpoint_host.dart';
import '../core/app_settings.dart';
import '../core/app_visibility.dart';
import '../core/session.dart';
import '../core/settings_store.dart';
import '../features/accounts/accounts_page.dart';
import '../features/book/book_shell.dart';
import '../features/discover/discover_shell.dart';
import '../features/files/files_page.dart';
import '../features/home/home_page.dart';
import '../features/media_tool/media_tool_page.dart';
import '../features/messages/messages_page.dart';
import '../features/monitor/monitor_page.dart';
import '../features/mount/mount_page.dart';
import '../features/music/music_shell.dart';
import '../features/notes/notes_page.dart';
import '../features/photo/photo_shell.dart';
import '../features/safety/safety_page.dart';
import '../features/settings/settings_page.dart';
import '../features/share/share_page.dart';
import '../features/sync/sync_page.dart';
import '../features/sync/sync_scheduler.dart';
import '../features/sync/sync_tray_bridge.dart';
import '../features/terminal/terminal_page.dart';
import '../features/transfer/transfer_page.dart';
import '../features/video/video_shell.dart';
import 'app_nav_shell.dart';
import 'app_visuals.dart';
import 'shell_back.dart';
import '../features/music/mini_player_bar.dart';

/// 响应式外壳：一套逻辑，两套布局。
///
/// - `medium` / `expanded`（桌面、平板横屏）：**三栏** = 分组侧栏 + 全局顶栏 + 内容区；
/// - `compact`（手机竖屏）：底部导航（工作台 + 前 4 个入口 + 「更多」）。
///
/// 入口清单**由 `contracts/apps.json` 驱动**（`AppRegistry`）：新增 App 只改契约 + 在
/// `_pageById` 补一行页面映射；`available: false` 的 App 不出现在导航里。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// 外部入口请求切到某个 App（目前只有 Electron 托盘的「同步任务」）。
  ///
  /// 用回调而不是 GlobalKey：托盘的调用方在 `sync_tray_bridge` 里，
  /// 拿不到 State，也不该 import 整个 shell 的私有类型。
  static void Function(String appId)? openAppRequest;

  /// 切到指定 App；没挂载（还在登录页）时静默忽略
  static void openApp(String appId) => openAppRequest?.call(appId);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// 当前选中项：`home`（工作台）或 App id
  String _selected = 'home';

  /// 非首页时侧栏收成图标条；鼠标移上去临时展开显示文字
  bool _navHovered = false;

  /// 收起（未悬停）只留图标：56；悬停展开到「图标 + 4 个汉字」：128
  static const _navCollapsedWidth = 56.0;
  static const _navExpandedWidth = 128.0;

  /// 手机底部曾经固定的四项（相册 / 影视 / 音乐 / 发现）。
  ///
  /// 2026-11-04 起手机端不再有一级底部导航：工作台是唯一入口，App 内全屏、
  /// 由 App 自己的底部二级菜单承担切换（对齐移动端基线的形态）。
  /// 这一段留空常量会被 `flutter analyze` 判成未使用，故连注释一起保留说明。

  /// 工作台缓存一份：`IndexedStack` 每次 build 新建 widget 会丢状态
  late final HomePage _home = HomePage(onOpenApp: _open);

  /// 已经进入过的页面 id。`IndexedStack` 会把**所有** children 都 inflate ——
  /// 18 个页面一启动就全部 initState、各自发首屏请求；终端页会在用户从没点过的
  /// 情况下常驻一个 PTY WebSocket，监控页的 5 秒轮询也从启动跑到关。
  /// 只实例化「进过的」，未进过的用零尺寸占位（children 数量必须不变，否则 index 错位）。
  final Set<String> _built = <String>{};

  @override
  void initState() {
    super.initState();
    // 外部入口（Electron 托盘的「同步任务」）请求切 App 时走这里
    AppShell.openAppRequest = _open;
    // 手机端二级页左上角的房子：点它回工作台（桌面端用不到）
    AppNavShell.onExitToHome = () => _open('home');
    // 用户开启过「自动同步」才启动调度；默认关，避免悄悄读写本地磁盘
    if (SyncScheduler.instance.enabled) SyncScheduler.instance.start();
    // 托盘桥在 `runColanasApp` 里已经装好；这里补报一次状态 —— 登录之后才拿得到
    // 任务数，「立即同步」该不该置灰取决于它。
    unawaited(syncTrayBridge.refresh());
    // 首启引导只出现一次（SettingsStore：桌面写 settings.json，Web 写 localStorage）
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowGuide());
  }

  Future<void> _maybeShowGuide() async {
    if (!mounted) return;
    if (SettingsStore.instance.getBool('guide.seen.v1') == true) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('guide.title')),
        content: Text(tr('guide.body')),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('guide.ok')),
          ),
        ],
      ),
    );
    // 用户看过就记下来；即使直接关掉也不再重复弹出（引导不是每次启动的阻塞项）
    await SettingsStore.instance.setBool('guide.seen.v1', true);
  }

  @override
  void dispose() {
    if (AppShell.openAppRequest == _open) AppShell.openAppRequest = null;
    AppNavShell.onExitToHome = null;
    super.dispose();
  }

  /// App id → 页面。契约里有、这里没有的 App 不会出现在导航（例如 `ai` 仍是占位）
  static final Map<String, Widget> _pageById = {
    'photo': const PhotoShellPage(),
    'files': const FilesPage(),
    'video': const VideoShellPage(),
    'discover': const DiscoverShellPage(),
    'music': const MusicShellPage(),
    'book': const BookShellPage(),
    'notes': const NotesPage(),
    'netdisk': const MountPage(),
    'share': const SharePage(),
    'backup': const SafetyPage(),
    'monitor': const MonitorPage(),
    'messages': const MessagesPage(),
    'terminal': const TerminalPage(),
    'sync': const SyncPage(),
    'transfer': const TransferPage(),
    'accounts': const AccountsPage(),
    'mediaTool': const MediaToolPage(),
    'settings': const SettingsPage(),
  };

  static List<AppDescriptor> get _apps => AppRegistry.apps
      .where(
        (a) =>
            a.available &&
            _pageById.containsKey(a.id) &&
            // 契约的 endpoints 之前没人用，等于所有端都看到全部入口；
            // 现在按当前客户端过滤（见 core/app_visibility.dart）
            appVisibleOnThisClient(a),
      )
      .toList(growable: false);

  /// 页面顺序：工作台在最前，其余按契约顺序
  static List<String> get _ids => ['home', for (final a in _apps) a.id];

  void _open(String id) => setState(() => _selected = id);

  String _labelOf(String id) {
    if (id == 'home') return tr('nav.home');
    final app = AppRegistry.byId(id);
    return app == null ? id : tr(app.nameKey);
  }

  /// 一级导航与工作台都从契约取图标（`AppVisuals.iconFor`），手机端不再有底部一级栏。
  Widget _pageOf(String id) =>
      id == 'home' ? _home : (_pageById[id] ?? const SizedBox.shrink());

  /// 端能力矩阵（docs/04 §64）：受限 / 不提供的能力必须在 UI 上明确告知，
  /// 不允许「看起来能用但点了没反应」。档位为 full 或该 App 未声明能力时不提示。
  /// 「× 在当前端为受限能力」横幅。
  ///
  /// **默认不显示**（`AppSettings.capabilityNotice` 默认 false）：横幅每次进页面都占一行，
  /// 却说不清具体哪个按钮不能用，对实际使用没有帮助；真需要排查端差异时在
  /// 「设置 → 外观」里打开。能力矩阵本身仍然有效（导航 / 文档 / 测试都在用）。
  Widget _withCapabilityNotice(String id, Widget body, double gap) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppSettings.instance.capabilityNotice,
      builder: (context, showNotice, _) {
        if (!showNotice) return body;
        final entry = CapabilityMatrix.forApp(id);
        if (entry == null) return body;
        final endpoint = EndpointHost.endpoint;
        final level = entry.levelOn(endpoint);
        if (level == CapabilityLevel.full) return body;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NasCapabilityNotice(
              capabilityName: tr(entry.nameKey),
              level: level,
              hint: endpoint == CapabilityEndpoint.web
                  ? tr(I18nKeys.capabilityWebHint)
                  : null,
            ),
            SizedBox(height: gap),
            Expanded(child: body),
          ],
        );
      },
    );
  }

  List<NasNavGroup> _navGroups() {
    final groups = <NasNavGroup>[
      NasNavGroup(
        entries: [
          NasNavEntry(
            id: 'home',
            label: tr('nav.home'),
            icon: Icons.dashboard_outlined,
          ),
        ],
      ),
    ];
    for (final group in AppGroup.values) {
      final entries = <NasNavEntry>[
        for (final app in _apps)
          if (AppVisuals.groupOf(app.id) == group)
            NasNavEntry(
              id: app.id,
              label: tr(app.nameKey),
              icon: AppVisuals.iconFor(app.icon),
            ),
      ];
      if (entries.isNotEmpty) {
        groups.add(NasNavGroup(title: tr(group.i18nKey), entries: entries));
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final ids = _ids;
    var index = ids.indexOf(_selected);
    if (index < 0) index = 0;
    final currentId = ids[index];
    _built.add(currentId);
    final pages = [
      for (final id in ids)
        _built.contains(id) ? _pageOf(id) : const SizedBox.shrink(),
    ];
    final body = IndexedStack(index: index, children: pages);

    return LayoutBuilder(
      builder: (context, constraints) {
        final mode = layoutFor(constraints.maxWidth);

        if (mode == LayoutMode.compact) {
          // 手机端：**工作台是唯一入口**，App 全屏（自带 56 顶栏 + 底部二级菜单）。
          // 因此这里不再有一级底部导航，也没有「更多」弹层 —— 两层底部栏没法共存。
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              // 工作台自己不带顶栏，交给这里避开状态栏；
              // App 页的顶栏要把底色铺到状态栏下面，所以 top: false。
              top: currentId == 'home',
              bottom: false,
              child: _withCapabilityNotice(currentId, body, NasTokens.spaceSm),
            ),
            // 常驻播放条：无曲目时高度为 0，不占位
            bottomNavigationBar: const MiniPlayerBar(),
          );
        }

        // TV 上常显完整侧栏（无鼠标悬停），间距也放大一档
        final tv = TvScope.of(context);
        final gap = tv ? NasTokens.spaceLg : NasTokens.spaceMd;
        final collapsedNav = !tv && _selected != 'home' && !_navHovered;
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(gap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MouseRegion(
                    onEnter: (_) {
                      if (_selected != 'home' && !_navHovered) {
                        setState(() => _navHovered = true);
                      }
                    },
                    onExit: (_) {
                      if (_navHovered) setState(() => _navHovered = false);
                    },
                    child: NasSideNav(
                      width: tv
                          ? kTvNavWidth
                          : collapsedNav
                          ? _navCollapsedWidth
                          : _navExpandedWidth,
                      iconOnly: collapsedNav,
                      groups: _navGroups(),
                      selectedId: currentId,
                      onSelect: _open,
                      header: _brand(compact: collapsedNav),
                      footer: _accountCard(compact: collapsedNav),
                      // 测试用：一级栏与二级栏的 id 会重名（`home`），key 前缀区分
                      debugLabel: 'app',
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: Column(
                      children: [
                        NasTopBar(
                          title: _labelOf(currentId),
                          subtitle: currentId == 'home'
                              ? tr('home.summary')
                              : tr(AppVisuals.groupOf(currentId).i18nKey),
                          // 顶部搜索暂时不显示（2026-11-04）：它只按 App 名字跳转，
                          // 但每个二级页面顶上都要占一条输入框，用户反馈「怪怪的」。
                          // 需要时把 `search: NasSearchBox(...)` 加回来即可，_jumpTo 还在。
                          actions: [
                            // 传输入口已移除（侧栏里有「传输」App，顶栏重复且占位）；
                            // 同一位置改为「返回上一层」：只在当前 App 处于三级 / 四级下钻时出现。
                            ValueListenableBuilder<int>(
                              valueListenable: ShellBack.revision,
                              builder: (context, _, _) {
                                final back = ShellBack.handlerFor(currentId);
                                if (back == null) return const SizedBox.shrink();
                                return NasIconAction(
                                  icon: Icons.arrow_back,
                                  tooltip: tr('common.back'),
                                  onPressed: back,
                                );
                              },
                            ),
                            // 「设置」按钮已移除：它是侧栏里的一个 App，顶栏再来一个入口
                            // 是重复的，而且点它直接崩（用户 2026-11-04 反馈）。
                          ],
                        ),
                        SizedBox(height: gap),
                        Expanded(
                          child: _withCapabilityNotice(currentId, body, gap),
                        ),
                        // 常驻播放条：宽屏放在内容区下方（不遮挡侧栏）
                        const MiniPlayerBar(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 顶栏搜索：输入应用名 / 中文名直接跳转（子串匹配，回车生效）
  // 顶部搜索框暂时隐藏，保留这个方法方便恢复（见 NasTopBar 处的注释）
  // ignore: unused_element
  void _jumpTo(String keyword) {
    final q = keyword.trim().toLowerCase();
    if (q.isEmpty) return;
    for (final id in _ids) {
      if (_labelOf(id).toLowerCase().contains(q) ||
          id.toLowerCase().contains(q)) {
        _open(id);
        return;
      }
    }
  }

  Widget _brand({required bool compact}) {
    final scheme = Theme.of(context).colorScheme;
    // 与应用图标同一张图（`tool/gen-icons.js` 从 resources/icon-source.png 派生），
    // 不再自绘渐变块，避免侧栏 logo 和任务栏图标不是同一个东西。
    final logo = Image.asset(
      'assets/branding/app_icon.png',
      width: 32,
      height: 32,
      cacheWidth: 96,
      filterQuality: FilterQuality.medium,
    );
    // 收起时不显示任何文字（含 ColaNasOs 与地址），悬停展开才出现
    if (compact) return Center(child: logo);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        logo,
        const SizedBox(height: 4),
        Text(
          'ColaNasOs',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: scheme.onSurface,
          ),
        ),
        Text(
          ApiSession.instance.baseUrl.replaceFirst(RegExp('^https?://'), ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: NasTokens.fontMicro,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _accountCard({required bool compact}) {
    final scheme = Theme.of(context).colorScheme;
    final user = ApiSession.instance.username ?? '';
    final initial = user.isEmpty ? 'C' : user.substring(0, 1).toUpperCase();
    final avatar = CircleAvatar(
      radius: 14,
      backgroundColor: scheme.primary.withValues(alpha: 0.18),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
    return InkWell(
      borderRadius: BorderRadius.circular(context.nasStyle.radius * 0.6),
      onTap: () => _showAccountDialog(user, initial),
      child: NasPanel(
        radius: context.nasStyle.radius * 0.6,
        padding: const EdgeInsets.symmetric(
          horizontal: NasTokens.spaceSm,
          vertical: NasTokens.spaceSm,
        ),
        child: compact
            ? Center(child: avatar)
            : Row(
                children: [
                  avatar,
                  const SizedBox(width: NasTokens.spaceSm),
                  Expanded(
                    child: Text(
                      user.isEmpty ? '—' : user,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _showAccountDialog(String user, String initial) async {
    final scheme = Theme.of(context).colorScheme;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: NasTokens.spaceSm),
            CircleAvatar(
              radius: 34,
              backgroundColor: scheme.primary.withValues(alpha: 0.18),
              child: Text(
                initial,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
            const SizedBox(height: NasTokens.spaceMd),
            Text(
              user.isEmpty ? '—' : user,
              style: TextStyle(
                fontSize: NasTokens.fontSubtitle,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.close')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'logout'),
            child: Text(tr('nav.logout')),
          ),
        ],
      ),
    );
    if (action == 'logout') {
      await ApiSession.instance.logout();
    }
  }
}
