import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../core/endpoint_host.dart';
import '../core/app_settings.dart';
import '../core/session.dart';
import '../features/accounts/accounts_page.dart';
import '../features/book/book_page.dart';
import '../features/discover/discover_shell.dart';
import '../features/files/files_page.dart';
import '../features/home/home_page.dart';
import '../features/media_tool/media_tool_page.dart';
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
import '../features/transfer/transfer_page.dart';
import '../features/video/video_shell.dart';
import 'app_visuals.dart';
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

  /// compact 底部导航直接展示的入口数
  static const _primaryCount = 5;

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
    // 用户开启过「自动同步」才启动调度；默认关，避免悄悄读写本地磁盘
    if (SyncScheduler.instance.enabled) SyncScheduler.instance.start();
  }

  /// App id → 页面。契约里有、这里没有的 App 不会出现在导航（例如 `ai` 仍是占位）
  static final Map<String, Widget> _pageById = {
    'photo': const PhotoShellPage(),
    'files': const FilesPage(),
    'video': const VideoShellPage(),
    'discover': const DiscoverShellPage(),
    'music': const MusicShellPage(),
    'book': const BookPage(),
    'notes': const NotesPage(),
    'netdisk': const MountPage(),
    'share': const SharePage(),
    'backup': const SafetyPage(),
    'monitor': const MonitorPage(),
    'sync': const SyncPage(),
    'transfer': const TransferPage(),
    'accounts': const AccountsPage(),
    'mediaTool': const MediaToolPage(),
    'settings': const SettingsPage(),
  };

  static List<AppDescriptor> get _apps => AppRegistry.apps
      .where((a) => a.available && _pageById.containsKey(a.id))
      .toList(growable: false);

  /// 页面顺序：工作台在最前，其余按契约顺序
  static List<String> get _ids => ['home', for (final a in _apps) a.id];

  void _open(String id) => setState(() => _selected = id);

  String _labelOf(String id) {
    if (id == 'home') return tr('nav.home');
    final app = AppRegistry.byId(id);
    return app == null ? id : tr(app.nameKey);
  }

  IconData _iconOf(String id) {
    if (id == 'home') return Icons.dashboard_outlined;
    final app = AppRegistry.byId(id);
    return AppVisuals.iconFor(app?.icon ?? '');
  }

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

  void _showMore(BuildContext context, List<String> ids) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = _primaryCount; i < ids.length; i++)
                ListTile(
                  leading: Icon(_iconOf(ids[i])),
                  title: Text(_labelOf(ids[i])),
                  onTap: () {
                    Navigator.pop(ctx);
                    _open(ids[i]);
                  },
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(tr('nav.logout')),
                onTap: () {
                  Navigator.pop(ctx);
                  ApiSession.instance.logout();
                },
              ),
            ],
          ),
        ),
      ),
    );
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
          final selected = index < _primaryCount ? index : _primaryCount;
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              bottom: false,
              child: _withCapabilityNotice(currentId, body, NasTokens.spaceSm),
            ),
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 常驻播放条：窄屏贴在底部导航之上
                const MiniPlayerBar(),
                NavigationBar(
                  selectedIndex: selected,
                  onDestinationSelected: (i) {
                    if (i < _primaryCount) {
                      _open(ids[i]);
                    } else {
                      _showMore(context, ids);
                    }
                  },
                  destinations: [
                    for (final id in ids.take(_primaryCount))
                      NavigationDestination(
                        icon: Icon(_iconOf(id)),
                        label: _labelOf(id),
                      ),
                    NavigationDestination(
                      icon: const Icon(Icons.more_horiz),
                      label: tr('nav.more'),
                    ),
                  ],
                ),
              ],
            ),
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
                          // 遥控器没有软键盘，TV 模式收起顶栏搜索
                          search: tv
                              ? null
                              : NasSearchBox(
                                  hintText: tr('common.search'),
                                  onSubmitted: _jumpTo,
                                ),
                          actions: [
                            NasIconAction(
                              icon: Icons.swap_vert,
                              tooltip: tr('app.transfer'),
                              onPressed: () => _open('transfer'),
                            ),
                            NasIconAction(
                              icon: Icons.settings_outlined,
                              tooltip: tr('app.settings'),
                              onPressed: () => _open('settings'),
                            ),
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
    final logo = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, const Color(0xFF8B5CF6)],
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.album_rounded, size: 18, color: Colors.white),
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
