import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 相册 · AI 中心（手机端相册的第 4 个底部 tab）。
///
/// 为什么需要这一页：相册的 AI 有 8 个入口（人物 / 关系 / 场景 / 活动 / 规则 /
/// 搜索 / GPS / 清理），手机上放不下 8 个 tab，全塞进「更多」又等于降级。
/// 所以做成一个聚合页：**回忆快捷入口 + 人物预览 + 其余功能入口**，
/// 与移动端基线的相册 AI 页同一形态（预览行 + 查看全部）。
///
/// 页面本身不持有导航状态：点任意入口都走 [onNavigate]，由 `PhotoShellPage`
/// 切到对应菜单项 —— 这样 AI 中心里的入口和侧栏/更多里的是同一份实现。
class PhotoAiCenterPage extends StatefulWidget {
  const PhotoAiCenterPage({super.key, required this.onNavigate});

  final ValueChanged<String> onNavigate;

  @override
  State<PhotoAiCenterPage> createState() => _PhotoAiCenterPageState();
}

class _PhotoAiCenterPageState extends State<PhotoAiCenterPage> {
  bool _loading = true;
  String? _error;
  PhotoHomeSummary? _summary;

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  Map<String, String> get _headers {
    final token = ApiSession.instance.token;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final summary = await ApiSession.instance.client.photoHomeSummary();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _load);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          NasTokens.spaceMd,
          NasTokens.spaceMd,
          NasTokens.spaceMd,
          NasTokens.spaceXl,
        ),
        children: [
          _recallRow(),
          const SizedBox(height: NasTokens.spaceLg),
          _peopleCard(),
          const SizedBox(height: NasTokens.spaceLg),
          _entryGrid(),
        ],
      ),
    );
  }

  /// 基线的「回忆三件套」：手机上侧栏没有分组，挂在 AI 页顶部当快捷入口。
  Widget _recallRow() {
    final items = <({String id, String label, IconData icon, Color color})>[
      (
        id: 'memory',
        label: tr('photo.nav.memory'),
        icon: Icons.auto_stories_outlined,
        color: const Color(0xFF8B5CF6),
      ),
      (
        id: 'tickets',
        label: tr('photo.nav.tickets'),
        icon: Icons.confirmation_number_outlined,
        color: const Color(0xFF06B6D4),
      ),
      (
        id: 'year',
        label: tr('photo.nav.year'),
        icon: Icons.bar_chart,
        color: const Color(0xFFF59E0B),
      ),
    ];
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: NasTokens.spaceSm),
          Expanded(
            child: _RecallTile(
              label: items[i].label,
              icon: items[i].icon,
              color: items[i].color,
              onTap: () => widget.onNavigate(items[i].id),
            ),
          ),
        ],
      ],
    );
  }

  Widget _peopleCard() {
    final scheme = Theme.of(context).colorScheme;
    final people = _summary?.people.items ?? const <PhotoHomePerson>[];
    final pending = _summary?.people.pending ?? 0;
    return NasPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('photo.home.people'),
                      style: TextStyle(
                        fontSize: NasTokens.fontBody,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('photo.home.peopleSub'),
                      style: TextStyle(
                        fontSize: NasTokens.fontMicro,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => widget.onNavigate('faces'),
                child: Text(tr('photo.home.allPeople')),
              ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceSm),
          if (people.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
              child: Text(
                tr('photo.home.noPeople'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final p in people.take(12))
                    Padding(
                      padding: const EdgeInsets.only(right: NasTokens.spaceMd),
                      child: _personTile(p),
                    ),
                ],
              ),
            ),
          if (pending > 0) ...[
            const SizedBox(height: NasTokens.spaceSm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('photo.home.pendingFaces', {'count': '$pending'}),
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => widget.onNavigate('faces'),
                  child: Text(tr('photo.home.confirmNow')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _personTile(PhotoHomePerson p) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 68,
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusMd),
        onTap: () => widget.onNavigate('faces'),
        child: Column(
          children: [
            ClipOval(
              child: SizedBox(
                width: 52,
                height: 52,
                child: p.coverPath == null
                    ? ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person_outline,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    : NasCoverImage(
                        url: _media.thumbnail(p.coverPath!, size: 160),
                        headers: _headers,
                        cacheWidth: 104,
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              p.name ?? tr('photo.home.unnamed'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: NasTokens.fontMicro,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            Text(
              tr('photo.home.photoCount', {'count': '${p.size}'}),
              maxLines: 1,
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryGrid() {
    const entries = <({String id, String labelKey, IconData icon})>[
      (id: 'relations', labelKey: 'photo.relations.title', icon: Icons.hub_outlined),
      (id: 'scenes', labelKey: 'ui.photo.036', icon: Icons.landscape_outlined),
      (
        id: 'activities',
        labelKey: 'photo.nav.activities',
        icon: Icons.sports_handball_outlined
      ),
      (id: 'smartRules', labelKey: 'photo.smartRule.title', icon: Icons.rule),
      (id: 'search', labelKey: 'common.search', icon: Icons.search),
      (
        id: 'cleanup',
        labelKey: 'photo.nav.similarCleanup',
        icon: Icons.cleaning_services_outlined
      ),
      (id: 'gps', labelKey: 'photo.nav.gps', icon: Icons.gps_fixed_outlined),
      (
        id: 'aiSettings',
        labelKey: 'photo.nav.aiSettings',
        icon: Icons.tag_faces_outlined
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // 手机 2 列，平板 3 列 —— 与工作台应用网格同一套节奏
        final columns = constraints.maxWidth >= 520 ? 3 : 2;
        const gap = NasTokens.spaceSm;
        final width =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final e in entries)
              SizedBox(
                width: width,
                child: _EntryTile(
                  label: tr(e.labelKey),
                  icon: e.icon,
                  onTap: () => widget.onNavigate(e.id),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RecallTile extends StatelessWidget {
  const _RecallTile({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusLg),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(NasTokens.radiusLg),
        ),
        child: Column(
          children: [
            Icon(icon, size: NasTokens.iconLg, color: color),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NasPanel(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(context.nasStyle.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NasTokens.spaceMd,
            vertical: NasTokens.spaceMd,
          ),
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
                    fontSize: NasTokens.fontCaption,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
