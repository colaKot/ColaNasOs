import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_visibility.dart';
import '../photo/backup_page.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../../shell/app_visuals.dart';

/// 工作台（首页）：
///   ① 系统状态（CPU / GPU / 内存，紧凑卡，点进去看每核）
///   ② 硬盘（一行 5 列，列出所有本地盘）
///   ③ 我的应用（网格 / 列表切换，每项 100×100）
///   ④ 快捷操作
///
/// 数据全部来自真实接口（`systemMonitor` / `AppRegistry`），失败时降级为「—」。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onOpenApp});

  final ValueChanged<String> onOpenApp;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loading = true;
  Map<String, dynamic>? _mem;
  Map<String, dynamic>? _cpu;
  Map<String, dynamic>? _gpu;
  List<Map<String, dynamic>> _disks = const [];

  /// grid = 平铺所有应用；list = 按大类别分组
  String _appView = 'grid';

  /// 自定义应用顺序（appId 列表，存本机）。空 = 用注册表原顺序。
  /// 只在网格视图生效：列表视图按「数据/媒体/服务」分组的，跨组重排没有意义。
  static const String _orderKey = 'home.apps.order';
  List<String> _order = const [];

  /// GPU 采样是后台探针（约 3s 一拍），只加载一次的话首次必然拿到空值，
  /// 卡片就永远停在「未检测到」；和监控页一样 5s 刷一次。
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final saved = SettingsStore.instance.getString(_orderKey);
    if (saved != null && saved.isNotEmpty) {
      _order = saved.split(',').where((s) => s.trim().isNotEmpty).toList();
    }
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await ApiSession.instance.client.systemMonitor();
      if (!mounted) return;
      final rawDisks = (d['disks'] as List?) ?? const [];
      setState(() {
        _mem = (d['mem'] as Map?)?.cast<String, dynamic>();
        _cpu = (d['cpu'] as Map?)?.cast<String, dynamic>();
        _gpu = (d['gpu'] as Map?)?.cast<String, dynamic>();
        _disks = rawDisks
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  int _num(Map<String, dynamic>? m, String key) =>
      (m?[key] as num?)?.toInt() ?? 0;

  double? _ratio(Map<String, dynamic>? m, String usedKey, String totalKey) {
    final total = _num(m, totalKey);
    if (total <= 0) return null;
    return (_num(m, usedKey) / total).clamp(0, 1).toDouble();
  }

  String _pair(Map<String, dynamic>? m, String usedKey, String totalKey) {
    if (m == null) return '—';
    return '${formatBytes(_num(m, usedKey))} / ${formatBytes(_num(m, totalKey))}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 工作台的应用卡要和导航一致：契约 endpoints 不包含当前端的入口不显示
    final apps = _applyOrder(
      visibleAppsOnThisClient(AppRegistry.apps.where((a) => a.available)),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final padding = context.nasStyle.contentPadding;
        final inner = width - padding.horizontal;
        const gap = NasTokens.spaceMd;

        // 系统状态：原 1/3 宽、高约 150 → 现在 1/6 宽、高 78（宽高都约一半）
        final statCols = inner >= 980
            ? 6
            : inner >= 640
            ? 3
            : 2;
        final statWidth = math.max(
          118.0,
          (inner - gap * (statCols - 1)) / statCols,
        );

        // 硬盘：一行 5 列
        final diskCols = inner >= 980
            ? 5
            : inner >= 700
            ? 3
            : 2;
        final diskWidth = math.max(
          150.0,
          (inner - gap * (diskCols - 1)) / diskCols,
        );

        // 手机端（窄屏）把「我的应用」提到最前：底部导航就是应用入口，
        // 进来先看到应用网格；系统状态与硬盘往下放。桌面保持原顺序（2026-11-04 需求）。
        final compact = width < 600;
        // 手机端应用网格固定一行 4 个：宽度不够就收间距和图标，而不是掉成 3 个
        // （用户明确要求「一行尽量放 4 个，不够宽就把间距拉小」）。
        final appGap = compact ? 6.0 : gap;
        final appWidth = compact
            ? math.max(56.0, ((inner - appGap * 3) / 4) - 0.5)
            : 100.0;

        final appsBlock = <Widget>[
          Row(
            children: [
              Expanded(child: _sectionTitle(tr('home.apps'))),
              IconButton(
                tooltip: tr('home.viewGrid'),
                icon: Icon(
                  Icons.grid_view_rounded,
                  size: 18,
                  color: _appView == 'grid'
                      ? scheme.primary
                      : context.nasTextSecondary,
                ),
                onPressed: () => setState(() => _appView = 'grid'),
              ),
              IconButton(
                tooltip: tr('home.viewList'),
                icon: Icon(
                  Icons.view_list_rounded,
                  size: 18,
                  color: _appView == 'list'
                      ? scheme.primary
                      : context.nasTextSecondary,
                ),
                onPressed: () => setState(() => _appView = 'list'),
              ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceSm),
          if (_appView == 'grid')
            Wrap(
              spacing: appGap,
              runSpacing: appGap,
              children: [
                for (final app in apps)
                  _draggableAppTile(
                    app,
                    compact: compact,
                    width: appWidth,
                  ),
              ],
            )
          else
            _groupedApps(apps, compact: compact),
        ];

        final statsBlock = <Widget>[
          _sectionTitle(tr('home.systemStatus')),
          const SizedBox(height: NasTokens.spaceSm),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              SizedBox(
                width: statWidth,
                child: _statTile(
                  title: tr('home.cpu'),
                  value: _cpu == null
                      ? '—'
                      : '${_num(_cpu, 'usagePercent')}%',
                  caption: _cpu == null
                      ? null
                      : '${_num(_cpu, 'cores')} ${tr('home.cores')}',
                  ratio: _cpu == null
                      ? null
                      : _num(_cpu, 'usagePercent') / 100,
                  icon: Icons.speed_rounded,
                  color: const Color(0xFF06B6D4),
                  onTap: () => widget.onOpenApp('monitor'),
                ),
              ),
              SizedBox(
                width: statWidth,
                child: _statTile(
                  title: tr('home.gpu'),
                  value: _gpu == null
                      ? '—'
                      : '${_num(_gpu, 'usagePercent')}%',
                  caption: _gpu == null
                      ? tr('home.gpuUnavailable')
                      : '${_gpu!['name'] ?? 'GPU'} · '
                            '${formatBytes(_num(_gpu, 'memUsed'))}',
                  ratio: _gpu == null
                      ? null
                      : _num(_gpu, 'usagePercent') / 100,
                  icon: Icons.videogame_asset_outlined,
                  color: const Color(0xFFF59E0B),
                  onTap: () => widget.onOpenApp('monitor'),
                ),
              ),
              SizedBox(
                width: statWidth,
                child: _statTile(
                  title: tr('home.mem'),
                  value: _pair(_mem, 'used', 'total'),
                  caption: _mem == null
                      ? null
                      : '${tr('home.free')} ${formatBytes(_num(_mem, 'free'))}',
                  ratio: _ratio(_mem, 'used', 'total'),
                  icon: Icons.memory_rounded,
                  color: const Color(0xFFA855F7),
                  onTap: () => widget.onOpenApp('monitor'),
                ),
              ),
            ],
          ),
        ];

        final disksBlock = <Widget>[
          _sectionTitle(tr('home.disks')),
          const SizedBox(height: NasTokens.spaceSm),
          if (_disks.isEmpty)
            Text(
              tr('home.noDisks'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            )
          else
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final disk in _disks)
                  SizedBox(width: diskWidth, child: _diskTile(disk)),
              ],
            ),
        ];

        // 手机 App 独有的「相册备份」横条（web / 桌面不出现）
        final backupBanner = <Widget>[
          if (isMobileApp()) ...[
            _backupBanner(context),
            const SizedBox(height: NasTokens.spaceMd),
          ],
        ];

        return RefreshIndicator(
          onRefresh: _load,
          child: SingleChildScrollView(
            padding: padding,
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _greeting(scheme),
                ...backupBanner,
                const SizedBox(height: NasTokens.spaceLg),
                // 手机端顺序对齐移动端基线：问候 → 应用网格 → 系统状态 → 硬盘。
                // 应用网格是主要入口，必须在前两屏内；系统状态与硬盘留在下方（D4 保留）。
                // 「快捷操作」整块已删（2026-11-04 用户反馈：四个入口实际都没用，
                // 上传/任务/分享/索引在各自 App 里都有更直接的入口）。
                if (compact) ...[
                  ...appsBlock,
                  const SizedBox(height: NasTokens.spaceLg),
                  ...statsBlock,
                  const SizedBox(height: NasTokens.spaceLg),
                  ...disksBlock,
                ] else ...[
                  ...statsBlock,
                  const SizedBox(height: NasTokens.spaceLg),
                  ...disksBlock,
                  const SizedBox(height: NasTokens.spaceLg),
                  ...appsBlock,
                ],
                if (_loading) ...[
                  const SizedBox(height: NasTokens.spaceLg),
                  const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 手机 App 专属：相册备份入口（横条）。web / 桌面不出现。
  Widget _backupBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const PhotoBackupPage()),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: NasTokens.spaceMd,
          vertical: NasTokens.spaceMd,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primary, const Color(0xFF8B5CF6)],
          ),
          borderRadius: BorderRadius.circular(NasTokens.radiusMd),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cloud_upload_outlined,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: NasTokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('home.backup.title'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: NasTokens.fontBody,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('home.backup.hint'),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.86),
                      fontSize: NasTokens.fontMicro,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: NasTokens.fontTitle,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  /// 紧凑指标卡：宽约 1/6、高 78，点开看详情
  Widget _statTile({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    String? caption,
    double? ratio,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return NasCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      height: 78,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          if (ratio != null)
            LinearProgressIndicator(
              value: ratio,
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
              backgroundColor: scheme.primary.withValues(alpha: 0.12),
            )
          else
            Text(
              caption ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _diskTile(Map<String, dynamic> disk) {
    final scheme = Theme.of(context).colorScheme;
    final total = _num(disk, 'total');
    final free = _num(disk, 'free');
    final used = _num(disk, 'used');
    final ratio = total > 0 ? (used / total).clamp(0, 1).toDouble() : null;
    return NasCard(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      height: 84,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(Icons.storage_rounded, size: 13, color: scheme.primary),
              const SizedBox(width: 4),
              Text(
                '${disk['mount'] ?? ''}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '${total > 0 ? (used / total * 100).round() : 0}%',
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          Text(
            '${formatBytes(used)} / ${formatBytes(total)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurface),
          ),
          if (ratio != null)
            LinearProgressIndicator(
              value: ratio,
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
              backgroundColor: scheme.primary.withValues(alpha: 0.12),
            ),
          Text(
            '${tr('home.free')} ${formatBytes(free)}',
            style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _groupedApps(List<AppDescriptor> apps, {bool compact = false}) {
    final groups = <AppGroup, List<AppDescriptor>>{};
    for (final app in apps) {
      groups.putIfAbsent(AppVisuals.groupOf(app.id), () => []).add(app);
    }
    const gap = NasTokens.spaceMd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(
              top: NasTokens.spaceXs,
              bottom: NasTokens.spaceXs,
            ),
            child: Text(
              tr(entry.key.i18nKey),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final app in entry.value) _appTile(app, compact: compact),
            ],
          ),
        ],
      ],
    );
  }

  /// 工作台应用卡。
  ///
  /// 手机端（[compact]）缩小一档：360 宽能排 4 列、430 宽 5 列，
  /// 与移动端基线的「60 图标 + 4~5 列」同一密度；桌面仍用 100×112 大卡。
  /// 按用户自定义顺序排；没登记过的（版本升级新增的 App）保持原顺序追加到末尾 ——
  /// 直接按 _order 过滤会让新 App 凭空消失。
  List<AppDescriptor> _applyOrder(List<AppDescriptor> apps) {
    if (_order.isEmpty) return apps;
    final rest = {for (final a in apps) a.id: a};
    final out = <AppDescriptor>[];
    for (final id in _order) {
      final app = rest.remove(id);
      if (app != null) out.add(app);
    }
    out.addAll(rest.values);
    return out;
  }

  /// 把 [fromId] 拖到 [toId] 的位置上并落盘
  Future<void> _moveApp(String fromId, String toId) async {
    if (fromId == toId) return;
    final ids = _applyOrder(
      visibleAppsOnThisClient(AppRegistry.apps.where((a) => a.available)),
    ).map((a) => a.id).toList();
    final from = ids.indexOf(fromId);
    final to = ids.indexOf(toId);
    if (from < 0 || to < 0) return;
    ids.insert(to, ids.removeAt(from));
    setState(() => _order = ids);
    await SettingsStore.instance.setString(_orderKey, ids.join(','));
  }

  /// 可拖拽的应用卡：长按图标拖动，松手落在哪个图标上就换到那个位置。
  /// 网格用 [Wrap]，没法用 ReorderableListView（那是列表），所以手写 Draggable/DragTarget。
  Widget _draggableAppTile(
    AppDescriptor app, {
    required bool compact,
    required double width,
  }) {
    final tile = _appTile(app, compact: compact, width: width);
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != app.id,
      onAcceptWithDetails: (details) => _moveApp(details.data, app.id),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return LongPressDraggable<String>(
          data: app.id,
          // 拖起来的那一份要自带 Material：feedback 不在 Scaffold 下面，
          // 没有 Material 祖先时 InkWell/Text 会直接抛错
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(opacity: 0.9, child: tile),
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: tile),
          child: AnimatedScale(
            scale: hovering ? 1.08 : 1,
            duration: const Duration(milliseconds: 120),
            child: tile,
          ),
        );
      },
    );
  }

  Widget _appTile(
    AppDescriptor app, {
    bool compact = false,
    double width = 100,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final accent = AppVisuals.accentFor(app.id);
    final color = accent.isEmpty ? scheme.primary : accent.first;
    final height = compact ? 92.0 : 112.0;
    // 图标底盒跟着格子宽度走：一行 4 个时格子只有 80 出头，不能用固定的 58
    final box = compact ? (width - 18).clamp(40.0, 58.0) : 80.0;
    final iconSize = compact ? box * 0.52 : 40.0;
    return InkWell(
      onTap: () => widget.onOpenApp(app.id),
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: box,
              height: box,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(compact ? 16 : 20),
              ),
              child: Icon(
                AppVisuals.iconFor(app.icon),
                size: iconSize,
                color: color,
              ),
            ),
            SizedBox(height: compact ? 4 : 6),
            Text(
              tr(app.nameKey),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 11 : 12,
                color: scheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _greeting(ColorScheme scheme) {
    final user = ApiSession.instance.username ?? '';
    final greeting = ApiSession.instance.welcome.isNotEmpty
        ? ApiSession.instance.welcome
        : tr('home.greeting');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          user.isEmpty ? greeting : '$greeting，$user',
          style: TextStyle(
            fontSize: NasTokens.fontHeadline,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          tr('home.summary'),
          style: TextStyle(
            fontSize: NasTokens.fontBody,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
