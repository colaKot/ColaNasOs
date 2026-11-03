import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
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
    final apps = AppRegistry.apps
        .where((a) => a.available)
        .toList(growable: false);

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

        return RefreshIndicator(
          onRefresh: _load,
          child: SingleChildScrollView(
            padding: padding,
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _greeting(scheme),
                const SizedBox(height: NasTokens.spaceLg),
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
                const SizedBox(height: NasTokens.spaceLg),
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
                const SizedBox(height: NasTokens.spaceLg),
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
                    spacing: gap,
                    runSpacing: gap,
                    children: [for (final app in apps) _appTile(app)],
                  )
                else
                  _groupedApps(apps),
                const SizedBox(height: NasTokens.spaceLg),
                _sectionTitle(tr('home.quick')),
                const SizedBox(height: NasTokens.spaceSm),
                Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    _quick(
                      Icons.cloud_upload_outlined,
                      tr('home.quick.upload'),
                      'transfer',
                    ),
                    _quick(
                      Icons.pending_actions_outlined,
                      tr('home.quick.task'),
                      'transfer',
                    ),
                    _quick(Icons.link, tr('home.quick.share'), 'share'),
                    _quick(
                      Icons.manage_search,
                      tr('home.quick.index'),
                      'files',
                    ),
                  ],
                ),
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

  Widget _groupedApps(List<AppDescriptor> apps) {
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
            children: [for (final app in entry.value) _appTile(app)],
          ),
        ],
      ],
    );
  }

  Widget _appTile(AppDescriptor app) {
    final scheme = Theme.of(context).colorScheme;
    final accent = AppVisuals.accentFor(app.id);
    final color = accent.isEmpty ? scheme.primary : accent.first;
    return InkWell(
      onTap: () => widget.onOpenApp(app.id),
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 100,
        height: 112,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(AppVisuals.iconFor(app.icon), size: 40, color: color),
            ),
            const SizedBox(height: 6),
            Text(
              tr(app.nameKey),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
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

  Widget _quick(IconData icon, String label, String appId) {
    final scheme = Theme.of(context).colorScheme;
    return NasCard(
      onTap: () => widget.onOpenApp(appId),
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceMd,
        vertical: NasTokens.spaceSm + 2,
      ),
      width: 190,
      child: Row(
        children: [
          Icon(icon, size: NasTokens.iconMd, color: scheme.primary),
          const SizedBox(width: NasTokens.spaceSm),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: NasTokens.fontBody,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
