import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';

import '../../core/display_labels.dart';
import '../../core/session.dart';
import '../../shell/app_nav_shell.dart';
import 'discover_page.dart';

/// 发现页：与其它模块同一套左侧二级导航（`contracts/apps.json#nav`）。
///
/// 栏目：发现（TMDB 榜单 / 搜索 + 豆瓣）/ PT / RSS / 任务 / 设置。
/// 以前这里是内容区顶部一排胶囊页签，与全站 IA 相反，已统一成左栏。
class DiscoverShellPage extends StatefulWidget {
  const DiscoverShellPage({super.key});

  @override
  State<DiscoverShellPage> createState() => _DiscoverShellPageState();
}

class _DiscoverShellPageState extends State<DiscoverShellPage> {
  /// 全局刷新：换 key 让当前栏目的内容页重建（含重新请求）
  int _reloadTick = 0;

  static const _doubanTags = <(String, String)>[
    ('热门', 'discover.doubanHot'), // i18n-ignore 豆瓣接口 tag（协议值）
    ('选电影', 'discover.doubanMovie'), // i18n-ignore 豆瓣接口 tag（协议值）
    ('电视剧', 'discover.doubanTv'), // i18n-ignore 豆瓣接口 tag（协议值）
    ('综艺', 'discover.doubanShow'), // i18n-ignore 豆瓣接口 tag（协议值）
    ('动画', 'discover.doubanAnime'), // i18n-ignore 豆瓣接口 tag（协议值）
  ];

  Widget _content(String key) {
    switch (key) {
      case 'pt':
        return const _PtTab();
      case 'rss':
        return const _RssTab();
      case 'tasks':
        return const _TasksTab();
      case 'settings':
        return const _SettingsTab();
      // 未列出的菜单项落到发现首页
      // nav-default: discover
      default:
        return const _DiscoverHub();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppNavShell(
      appId: 'discover',
      defaultKey: 'discover',
      content: (key) => Column(
        children: [
          // 内容区右上角的刷新：以前在顶部胶囊页签那一行，页签改成左侧栏后单独留一条
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: NasTokens.spaceXs),
              child: NasRefreshButton(onPressed: () => setState(() => _reloadTick += 1)),
            ),
          ),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey('$key-$_reloadTick'),
              child: _content(key),
            ),
          ),
        ],
      ),
    );
  }
}


/// 「发现」页签：TMDB / 豆瓣两个来源；豆瓣分类胶囊留在页内（不再做成左侧二级菜单）。
class _DiscoverHub extends StatefulWidget {
  const _DiscoverHub();

  @override
  State<_DiscoverHub> createState() => _DiscoverHubState();
}

class _DiscoverHubState extends State<_DiscoverHub> {
  bool _douban = false;
  String _tag = '热门';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceXs,
            NasTokens.spaceMd,
            0,
          ),
          child: Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.movie_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.local_movies_outlined, size: 16),
                  ),
                ],
                selected: {_douban},
                onSelectionChanged: (v) =>
                    setState(() => _douban = v.first),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(
                child: Text(
                  _douban ? tr('discover.douban') : tr('discover.settings.tmdb'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_douban)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NasTokens.spaceMd,
              vertical: NasTokens.spaceXs,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final tag in _DiscoverShellPageState._doubanTags)
                      Padding(
                        padding: const EdgeInsets.only(
                          right: NasTokens.spaceXs,
                        ),
                        child: NasChip(
                          label: Text(tr(tag.$2)),
                          selected: _tag == tag.$1,
                          onSelected: (_) => setState(() => _tag = tag.$1),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: _douban
              ? _DoubanTab(tag: _tag)
              : const DiscoverPage(embedded: true),
        ),
      ],
    );
  }
}
/// 豆瓣榜单
class _DoubanTab extends StatefulWidget {
  const _DoubanTab({required this.tag});

  /// 豆瓣接口的 tag 协议值（热门 / 选电影 / …）
  final String tag;

  @override
  State<_DoubanTab> createState() => _DoubanTabState();
}

class _DoubanTabState extends State<_DoubanTab> {

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.discoverDouban(
        tag: widget.tag,
        limit: '30',
      );
      if (!mounted) return;
      final raw = (res['items'] as List?) ?? const [];
      setState(() {
        _items = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _DoubanTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tag != widget.tag) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _loading
              ? const NasLoading()
              : _error != null
                  ? NasErrorState(message: _error!, onRetry: _load)
                  : _items.isEmpty
                      ? ListView(
                          children: [
                            NasEmptyState(
                              title: tr('ui.discover.013'),
                              icon: Icons.movie_outlined,
                            ),
                          ],
                        )
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final item = _items[i];
                            final year = item['year']?.toString() ?? '';
                            final rating = item['rating'];
                            final cover = item['coverUrl']?.toString();
                            return ListTile(
                              leading: SizedBox(
                                width: 40,
                                height: 56,
                                child: NasCoverImage(
                                  url: cover,
                                  cacheWidth: 120,
                                  icon: Icons.movie_outlined,
                                ),
                              ),
                              title: Text('${item['title'] ?? ''}'),
                              subtitle: Text(
                                [
                                  if (year.isNotEmpty) year,
                                  if (rating != null) '★ $rating',
                                  '${item['source'] ?? ''}',
                                ].where((e) => e.isNotEmpty).join(' · '),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

/// PT：站点 + 搜索
class _PtTab extends StatefulWidget {
  const _PtTab();

  @override
  State<_PtTab> createState() => _PtTabState();
}

class _PtTabState extends State<_PtTab> {
  final _q = TextEditingController();
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _sites = const [];
  List<Map<String, dynamic>> _results = const [];

  @override
  void initState() {
    super.initState();
    _loadSites();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _loadSites() async {
    try {
      final res = await ApiSession.instance.client.ptSiteList();
      if (!mounted) return;
      final raw = (res['items'] as List?) ?? const [];
      setState(() {
        _sites = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _results = const [];
    });
    try {
      final res = await ApiSession.instance.client.ptSearch(body: {'title': q});
      if (!mounted) return;
      final raw = (res['items'] as List?) ?? const [];
      setState(() {
        _results = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openSites() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _SiteManagerDialog(),
    );
    if (mounted) await _loadSites();
  }

  Future<void> _openSubs() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _SubscriptionManagerDialog(),
    );
  }

  String _size(int? bytes) {
    if (bytes == null) return '-';
    return formatBytes(bytes);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_sites.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NasTokens.spaceMd,
              NasTokens.spaceXs,
              NasTokens.spaceMd,
              0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: NasTokens.spaceXs,
                runSpacing: NasTokens.spaceXs,
                children: [
                  for (final s in _sites)
                    Chip(
                      label: Text('${s['name'] ?? s['host'] ?? ''}'),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceXs,
            NasTokens.spaceMd,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _q,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr('discover.ptSearch'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              FilledButton(
                onPressed: _loading ? null : _search,
                child: Text(tr('discover.ptGo')),
              ),
              const SizedBox(width: NasTokens.spaceXs),
              IconButton(
                tooltip: tr('discover.pt.sites'),
                icon: const Icon(Icons.dns_outlined),
                onPressed: _openSites,
              ),
              IconButton(
                tooltip: tr('discover.pt.subscriptions'),
                icon: const Icon(Icons.playlist_add_check),
                onPressed: _openSubs,
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const NasLoading()
              : _error != null
                  ? NasErrorState(message: _error!, onRetry: _search)
                  : _results.isEmpty
                      ? ListView(
                          children: [
                            NasEmptyState(
                              title: tr('discover.ptEmpty'),
                              icon: Icons.cloud_download_outlined,
                            ),
                          ],
                        )
                      : ListView.builder(
                          itemCount: _results.length,
                          itemBuilder: (context, i) {
                            final r = _results[i];
                            return ListTile(
                              leading: const Icon(Icons.arrow_downward),
                              title: Text(
                                '${r['title'] ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${_size((r['sizeBytes'] as num?)?.toInt())} · '
                                'S${r['seeders'] ?? 0} · ${r['siteName'] ?? ''}',
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

/// PT 站点管理（弹窗）：列表 + 新建/编辑/删除；不显示 cookie 明文。
class _SiteManagerDialog extends StatefulWidget {
  const _SiteManagerDialog();

  @override
  State<_SiteManagerDialog> createState() => _SiteManagerDialogState();
}

class _SiteManagerDialogState extends State<_SiteManagerDialog> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.ptSiteList();
      if (!mounted) return;
      setState(() {
        _items = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
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

  Future<void> _edit(Map<String, dynamic>? site) async {
    final nameCtrl = TextEditingController(text: '${site?['name'] ?? ''}');
    final urlCtrl = TextEditingController(text: '${site?['baseUrl'] ?? ''}');
    final cookieCtrl = TextEditingController();
    final apiKeyCtrl = TextEditingController();
    final priorityCtrl = TextEditingController(text: '${site?['priority'] ?? 100}');
    final uaCtrl = TextEditingController();
    var enabled = site?['enabled'] != false;
    var kind = '${site?['kind'] ?? 'nexusphp'}';
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: Color.alphaBlend(
              ctx.nasStyle.panelColor,
              ctx.nasStyle.baseColor,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ctx.nasStyle.radius),
              side: BorderSide(color: ctx.nasStyle.panelBorderColor),
            ),
            title: Text(site == null ? tr('discover.pt.newSite') : tr('discover.pt.editSite')),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: InputDecoration(labelText: tr('discover.pt.siteName')),
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    TextField(
                      controller: urlCtrl,
                      decoration: InputDecoration(
                        labelText: tr('discover.pt.siteUrl'),
                        hintText: 'https://example.org/',
                      ),
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    TextField(
                      controller: cookieCtrl,
                      decoration: InputDecoration(labelText: tr('discover.pt.cookie')),
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    TextField(
                      controller: apiKeyCtrl,
                      decoration: InputDecoration(labelText: tr('discover.pt.apiKey')),
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    Row(
                      children: [
                        SizedBox(
                          width: 150,
                          child: TextField(
                            controller: priorityCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: tr('discover.pt.priority'),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: NasTokens.spaceSm),
                        Expanded(
                          child: NasDropdown<String>(
                            initialValue: kind,
                            isDense: true,
                            decoration: InputDecoration(
                              labelText: tr('discover.pt.kind'),
                              isDense: true,
                            ),
                            items: const [
                              DropdownMenuItem(value: 'nexusphp', child: Text('NexusPHP')),
                              DropdownMenuItem(value: 'mteam', child: Text('M-Team')),
                            ],
                            onChanged: (v) => setDialogState(() => kind = v ?? 'nexusphp'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    TextField(
                      controller: uaCtrl,
                      decoration: InputDecoration(labelText: tr('discover.pt.userAgent')),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(tr('discover.pt.enabled')),
                      value: enabled,
                      onChanged: (v) => setDialogState(() => enabled = v),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('common.save')),
              ),
            ],
          ),
        ),
      );
      if (ok != true) return;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ApiSession.instance.client.ptSiteUpsert(
          body: <String, dynamic>{
            if (site != null) 'id': site['id'],
            'name': nameCtrl.text.trim(),
            'baseUrl': urlCtrl.text.trim(),
            'enabled': enabled,
            'priority': int.tryParse(priorityCtrl.text.trim()) ?? 100,
            'kind': kind,
            if (cookieCtrl.text.trim().isNotEmpty) 'cookie': cookieCtrl.text.trim(),
            if (apiKeyCtrl.text.trim().isNotEmpty) 'apiKey': apiKeyCtrl.text.trim(),
            if (uaCtrl.text.trim().isNotEmpty) 'userAgent': uaCtrl.text.trim(),
          },
        );
        await _load();
      } catch (e) {
        NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '$e'}));
      }
    } finally {
      nameCtrl.dispose();
      urlCtrl.dispose();
      cookieCtrl.dispose();
      apiKeyCtrl.dispose();
      priorityCtrl.dispose();
      uaCtrl.dispose();
    }
  }

  Future<void> _delete(Map<String, dynamic> site) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color.alphaBlend(
          ctx.nasStyle.panelColor,
          ctx.nasStyle.baseColor,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ctx.nasStyle.radius),
          side: BorderSide(color: ctx.nasStyle.panelBorderColor),
        ),
        title: Text(tr('common.delete')),
        content: Text(tr('discover.pt.deleteConfirm', {'name': '${site['name'] ?? ''}'})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.ptSiteDelete(
        body: <String, dynamic>{'id': '${site['id']}'},
      );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Color.alphaBlend(
        context.nasStyle.panelColor,
        context.nasStyle.baseColor,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.nasStyle.radius),
        side: BorderSide(color: context.nasStyle.panelBorderColor),
      ),
      title: Row(
        children: [
          Expanded(child: Text(tr('discover.pt.sites'))),
          TextButton.icon(
            onPressed: () => _edit(null),
            icon: const Icon(Icons.add, size: 16),
            label: Text(tr('discover.pt.newSite')),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 460,
        child: _loading
            ? const NasLoading()
            : _error != null
                ? NasErrorState(message: _error!, onRetry: _load)
                : _items.isEmpty
                    ? NasEmptyState(
                        title: tr('discover.pt.emptySites'),
                        icon: Icons.dns_outlined,
                      )
                    : ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final s = _items[i];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              s['enabled'] == true
                                  ? Icons.dns_outlined
                                  : Icons.dns_outlined,
                              color: s['enabled'] == true
                                  ? Theme.of(context).colorScheme.primary
                                  : context.nasTextSecondary,
                            ),
                            title: Text(
                              '${s['name'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                '${s['baseUrl'] ?? ''}',
                                '${s['kind'] ?? ''}',
                                '${tr('discover.pt.priority')} ${s['priority'] ?? ''}',
                                if (s['hasCookie'] == true) 'Cookie',
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: NasTokens.fontCaption),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  tooltip: tr('discover.pt.editSite'),
                                  onPressed: () => _edit(s),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                  tooltip: tr('common.delete'),
                                  onPressed: () => _delete(s),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.close')),
        ),
      ],
    );
  }
}

/// PT 订阅管理（弹窗）：列表 + 新建/编辑/删除/立即运行。
class _SubscriptionManagerDialog extends StatefulWidget {
  const _SubscriptionManagerDialog();

  @override
  State<_SubscriptionManagerDialog> createState() => _SubscriptionManagerDialogState();
}

class _SubscriptionManagerDialogState extends State<_SubscriptionManagerDialog> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.ptSubscriptionList();
      if (!mounted) return;
      setState(() {
        _items = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
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

  Future<void> _edit(Map<String, dynamic>? sub) async {
    final titleCtrl = TextEditingController(text: '${sub?['mediaTitle'] ?? ''}');
    final yearCtrl = TextEditingController(text: '${sub?['mediaYear'] ?? ''}');
    final seasonCtrl = TextEditingController(text: '${sub?['season'] ?? 0}');
    final seedersCtrl = TextEditingController(text: '${sub?['minSeeders'] ?? 3}');
    final maxSizeCtrl = TextEditingController(
      text: sub?['maxSizeBytes'] == null
          ? '0'
          : (((sub!['maxSizeBytes'] as num?)?.toInt() ?? 0) / (1024 * 1024 * 1024))
              .toStringAsFixed(0),
    );
    final excludedCtrl = TextEditingController(
      text: ((sub?['excludedKeywords'] as List?) ?? const [])
          .map((e) => '$e')
          .join(', '),
    );
    var quality = '${sub?['quality'] ?? 'all'}';
    var hdr = '${sub?['hdr'] ?? 'all'}';
    var enabled = sub?['enabled'] != false;
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: Color.alphaBlend(
              ctx.nasStyle.panelColor,
              ctx.nasStyle.baseColor,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ctx.nasStyle.radius),
              side: BorderSide(color: ctx.nasStyle.panelBorderColor),
            ),
            title: Text(sub == null ? tr('discover.pt.newSub') : tr('discover.pt.editSub')),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: InputDecoration(labelText: tr('discover.pt.title')),
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: yearCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: tr('discover.pt.year'),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: NasTokens.spaceSm),
                        Expanded(
                          child: TextField(
                            controller: seasonCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: tr('discover.pt.season'),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    Row(
                      children: [
                        Expanded(
                          child: NasDropdown<String>(
                            initialValue: quality,
                            isDense: true,
                            decoration: InputDecoration(
                              labelText: tr('discover.pt.quality'),
                              isDense: true,
                            ),
                            items: [
                              for (final q in const ['all', '1080p', '1440p', '4k'])
                                DropdownMenuItem(value: q, child: Text(q)),
                            ],
                            onChanged: (v) => setDialogState(() => quality = v ?? 'all'),
                          ),
                        ),
                        const SizedBox(width: NasTokens.spaceSm),
                        Expanded(
                          child: NasDropdown<String>(
                            initialValue: hdr,
                            isDense: true,
                            decoration: InputDecoration(
                              labelText: tr('discover.pt.hdr'),
                              isDense: true,
                            ),
                            items: [
                              for (final h in const ['all', 'hdr', 'hdr10', 'hdr10plus', 'dolby'])
                                DropdownMenuItem(value: h, child: Text(h)),
                            ],
                            onChanged: (v) => setDialogState(() => hdr = v ?? 'all'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: seedersCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: tr('discover.pt.minSeeders'),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: NasTokens.spaceSm),
                        Expanded(
                          child: TextField(
                            controller: maxSizeCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: tr('discover.pt.maxSize'),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    TextField(
                      controller: excludedCtrl,
                      decoration: InputDecoration(
                        labelText: tr('discover.pt.excluded'),
                        isDense: true,
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(tr('discover.pt.enabled')),
                      value: enabled,
                      onChanged: (v) => setDialogState(() => enabled = v),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('common.save')),
              ),
            ],
          ),
        ),
      );
      if (ok != true) return;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        final gb = (double.tryParse(maxSizeCtrl.text.trim()) ?? 0).clamp(0, 100000);
        await ApiSession.instance.client.ptSubscriptionUpsert(
          body: <String, dynamic>{
            if (sub != null) 'id': sub['id'],
            'mediaTitle': titleCtrl.text.trim(),
            if (yearCtrl.text.trim().isNotEmpty) 'mediaYear': yearCtrl.text.trim(),
            'season': int.tryParse(seasonCtrl.text.trim()) ?? 0,
            'quality': quality,
            'hdr': hdr,
            'minSeeders': int.tryParse(seedersCtrl.text.trim()) ?? 0,
            'maxSizeBytes': (gb * 1024 * 1024 * 1024).round(),
            'excludedKeywords': excludedCtrl.text
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList(),
            'enabled': enabled,
          },
        );
        await _load();
      } catch (e) {
        NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '$e'}));
      }
    } finally {
      titleCtrl.dispose();
      yearCtrl.dispose();
      seasonCtrl.dispose();
      seedersCtrl.dispose();
      maxSizeCtrl.dispose();
      excludedCtrl.dispose();
    }
  }

  Future<void> _run(Map<String, dynamic> sub) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.ptSubscriptionRun(
        body: <String, dynamic>{'id': '${sub['id']}'},
      );
      await _load();
      NasSnack.showOn(messenger, errorMessageOf(res['message']));
    } catch (e) {
      NasSnack.showOn(messenger, errorMessageOf(e));
    }
  }

  Future<void> _delete(Map<String, dynamic> sub) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color.alphaBlend(
          ctx.nasStyle.panelColor,
          ctx.nasStyle.baseColor,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ctx.nasStyle.radius),
          side: BorderSide(color: ctx.nasStyle.panelBorderColor),
        ),
        title: Text(tr('common.delete')),
        content: Text(tr('discover.pt.deleteConfirm', {'name': '${sub['mediaTitle'] ?? ''}'})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.ptSubscriptionDelete(
        body: <String, dynamic>{'id': '${sub['id']}'},
      );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Color.alphaBlend(
        context.nasStyle.panelColor,
        context.nasStyle.baseColor,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.nasStyle.radius),
        side: BorderSide(color: context.nasStyle.panelBorderColor),
      ),
      title: Row(
        children: [
          Expanded(child: Text(tr('discover.pt.subscriptions'))),
          TextButton.icon(
            onPressed: () => _edit(null),
            icon: const Icon(Icons.add, size: 16),
            label: Text(tr('discover.pt.newSub')),
          ),
        ],
      ),
      content: SizedBox(
        width: 680,
        height: 460,
        child: _loading
            ? const NasLoading()
            : _error != null
                ? NasErrorState(message: _error!, onRetry: _load)
                : _items.isEmpty
                    ? NasEmptyState(
                        title: tr('discover.pt.emptySubs'),
                        icon: Icons.playlist_add_check,
                      )
                    : ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final s = _items[i];
                          final last = s['lastResult'];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              s['enabled'] == true
                                  ? Icons.playlist_add_check
                                  : Icons.playlist_remove,
                              color: s['enabled'] == true
                                  ? Theme.of(context).colorScheme.primary
                                  : context.nasTextSecondary,
                            ),
                            title: Text(
                              [
                                '${s['mediaTitle'] ?? ''}',
                                if (s['mediaYear'] != null) '(${s['mediaYear']})',
                                if (((s['season'] as num?)?.toInt() ?? 0) > 0) 'S${s['season']}',
                              ].join(' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                '${s['quality'] ?? ''}/${s['hdr'] ?? ''}',
                                '${tr('discover.pt.minSeeders')} ${s['minSeeders'] ?? ''}',
                                last == null || '$last'.isEmpty
                                    ? tr('discover.pt.neverRun')
                                    : tr('discover.pt.lastResult', {'result': '$last'}),
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: NasTokens.fontCaption),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.play_arrow, size: 20),
                                  tooltip: tr('discover.pt.runNow'),
                                  onPressed: () => _run(s),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  tooltip: tr('discover.pt.editSub'),
                                  onPressed: () => _edit(s),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                  tooltip: tr('common.delete'),
                                  onPressed: () => _delete(s),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.close')),
        ),
      ],
    );
  }
}

/// RSS 自动下载规则（弹窗）：命中新条目 → 自动建 PT 订阅（后续由 PT 调度搜索/加种）。
class _RssRuleDialog extends StatefulWidget {
  const _RssRuleDialog();

  @override
  State<_RssRuleDialog> createState() => _RssRuleDialogState();
}

class _RssRuleDialogState extends State<_RssRuleDialog> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rules = const [];
  List<Map<String, dynamic>> _feeds = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = ApiSession.instance.client;
      final rules = await c.rssRuleList();
      final feeds = await c.rssListFeeds();
      if (!mounted) return;
      setState(() {
        _rules = ((rules['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _feeds = ((feeds['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
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

  String _time(Object? value) {
    final seconds = (value as num?)?.toInt() ?? 0;
    if (seconds <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _edit(Map<String, dynamic>? rule) async {
    if (_feeds.isEmpty) {
      NasSnack.show(context, tr('discover.rss.emptyRules'));
      return;
    }
    final regexCtrl = TextEditingController(text: '${rule?['titleRegex'] ?? ''}');
    var feedId = '${rule?['feedId'] ?? _feeds.first['id']}';
    var enabled = rule?['enabled'] != false;
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: Color.alphaBlend(
              ctx.nasStyle.panelColor,
              ctx.nasStyle.baseColor,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ctx.nasStyle.radius),
              side: BorderSide(color: ctx.nasStyle.panelBorderColor),
            ),
            title: Text(
              rule == null ? tr('discover.rss.newRule') : tr('discover.rss.editRule'),
            ),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NasDropdown<String>(
                    initialValue: feedId,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: tr('discover.rss.feed'),
                      isDense: true,
                    ),
                    items: [
                      for (final f in _feeds)
                        DropdownMenuItem(
                          value: '${f['id']}',
                          child: Text(
                            '${f['title'] ?? f['url'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setDialogState(() => feedId = v ?? feedId),
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  TextField(
                    controller: regexCtrl,
                    decoration: InputDecoration(
                      labelText: tr('discover.rss.regex'),
                      helperText: tr('discover.rss.regexHint'),
                    ),
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  Text(
                    tr('discover.rss.ruleHint'),
                    style: TextStyle(fontSize: NasTokens.fontCaption),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(tr('discover.rss.enabled')),
                    value: enabled,
                    onChanged: (v) => setDialogState(() => enabled = v),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('common.save')),
              ),
            ],
          ),
        ),
      );
      if (ok != true) return;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ApiSession.instance.client.rssRuleUpsert(
          body: <String, dynamic>{
            if (rule != null) 'id': rule['id'],
            'feedId': feedId,
            'titleRegex': regexCtrl.text.trim(),
            'enabled': enabled,
          },
        );
        await _load();
      } catch (e) {
        NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '$e'}));
      }
    } finally {
      regexCtrl.dispose();
    }
  }

  Future<void> _run(Map<String, dynamic> rule) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.rssRuleRun(
        body: <String, dynamic>{'id': '${rule['id']}'},
      );
      await _load();
      NasSnack.showOn(messenger, tr('discover.rss.ruleResult', {
            'matched': '${res['matched'] ?? 0}',
            'created': '${res['created'] ?? 0}',
          }));
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  Future<void> _delete(Map<String, dynamic> rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color.alphaBlend(
          ctx.nasStyle.panelColor,
          ctx.nasStyle.baseColor,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ctx.nasStyle.radius),
          side: BorderSide(color: ctx.nasStyle.panelBorderColor),
        ),
        title: Text(tr('common.delete')),
        content: Text(tr('discover.pt.deleteConfirm', {'name': '${rule['titleRegex'] ?? ''}'})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.rssRuleDelete(
        body: <String, dynamic>{'id': '${rule['id']}'},
      );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Color.alphaBlend(
        context.nasStyle.panelColor,
        context.nasStyle.baseColor,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.nasStyle.radius),
        side: BorderSide(color: context.nasStyle.panelBorderColor),
      ),
      title: Row(
        children: [
          Expanded(child: Text(tr('discover.rss.rules'))),
          TextButton.icon(
            onPressed: () => _edit(null),
            icon: const Icon(Icons.add, size: 16),
            label: Text(tr('discover.rss.newRule')),
          ),
        ],
      ),
      content: SizedBox(
        width: 680,
        height: 440,
        child: _loading
            ? const NasLoading()
            : _error != null
                ? NasErrorState(message: _error!, onRetry: _load)
                : _rules.isEmpty
                    ? NasEmptyState(
                        title: tr('discover.rss.emptyRules'),
                        icon: Icons.rule,
                      )
                    : ListView.separated(
                        itemCount: _rules.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final rule = _rules[i];
                          final last = rule['lastRunAt'];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              rule['enabled'] == true
                                  ? Icons.rule
                                  : Icons.rule_folder_outlined,
                              color: rule['enabled'] == true
                                  ? Theme.of(context).colorScheme.primary
                                  : context.nasTextSecondary,
                            ),
                            title: Text(
                              '${rule['titleRegex'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                '${rule['feedTitle'] ?? rule['feedId'] ?? ''}',
                                last == null
                                    ? tr('discover.rss.ruleNeverRun')
                                    : tr('discover.rss.lastRun', {'time': _time(last)}),
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: NasTokens.fontCaption),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.play_arrow, size: 20),
                                  tooltip: tr('discover.rss.ruleRun'),
                                  onPressed: () => _run(rule),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  tooltip: tr('discover.rss.editRule'),
                                  onPressed: () => _edit(rule),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                  tooltip: tr('common.delete'),
                                  onPressed: () => _delete(rule),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.close')),
        ),
      ],
    );
  }
}

/// RSS 订阅：feeds + 最新条目
class _RssTab extends StatefulWidget {
  const _RssTab();

  @override
  State<_RssTab> createState() => _RssTabState();
}

class _RssTabState extends State<_RssTab> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _feeds = const [];
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feedRes = await ApiSession.instance.client.rssListFeeds();
      final itemRes = await ApiSession.instance.client.rssItems(limit: 80);
      if (!mounted) return;
      setState(() {
        _feeds = ((feedRes['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _items = ((itemRes['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
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

  Future<void> _add() async {
    final url = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('discover.rss.addFeed')),
        content: TextField(
          controller: url,
          decoration: InputDecoration(
            labelText: tr('discover.rss.url'),
            hintText: 'https://…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.save')),
          ),
        ],
      ),
    );
    if (ok != true || url.text.trim().isEmpty) return;
    try {
      await ApiSession.instance.client.rssAddFeed(
        body: {'url': url.text.trim()},
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _openRules() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _RssRuleDialog(),
    );
  }

  Future<void> _refresh(Map<String, dynamic> feed) async {
    try {
      await ApiSession.instance.client.rssRefresh(body: {'id': feed['id']});
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _remove(Map<String, dynamic> feed) async {
    try {
      await ApiSession.instance.client.rssRemoveFeed(body: {'id': feed['id']});
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NasTokens.spaceMd,
            vertical: NasTokens.spaceXs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('discover.rss.feeds'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _openRules,
                icon: const Icon(Icons.rule, size: 16),
                label: Text(tr('discover.rss.rules')),
              ),
              const SizedBox(width: NasTokens.spaceXs),
              FilledButton.tonalIcon(
                onPressed: _add,
                icon: const Icon(Icons.add, size: 16),
                label: Text(tr('discover.rss.addFeed')),
              ),
            ],
          ),
        ),
        if (_feeds.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
              itemCount: _feeds.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: NasTokens.spaceXs),
              itemBuilder: (context, i) {
                final feed = _feeds[i];
                return InputChip(
                  label: Text(
                    '${feed['title'] ?? feed['url'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => _refresh(feed),
                  onDeleted: () => _remove(feed),
                  deleteIcon: const Icon(Icons.close, size: 14),
                );
              },
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _items.isEmpty
              ? NasEmptyState(
                  title: tr('discover.rss.empty'),
                  icon: Icons.rss_feed,
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NasTokens.spaceMd,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final item = _items[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        '${item['title'] ?? ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${item['feedTitle'] ?? ''} · ${_time((item['published'] as num?)?.toInt() ?? 0)}',
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static String _time(int seconds) {
    if (seconds <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// 任务：PT 下载留痕
class _TasksTab extends StatefulWidget {
  const _TasksTab();

  @override
  State<_TasksTab> createState() => _TasksTabState();
}

class _TasksTabState extends State<_TasksTab> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.ptDownloads();
      if (!mounted) return;
      setState(() {
        _items = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
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

  Future<void> _action(Map<String, dynamic> item, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.ptDownloadAction(
        body: <String, dynamic>{'id': '${item['id']}', 'action': action},
      );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'added':
        return tr('discover.tasks.status.added');
      case 'paused':
        return tr('discover.tasks.status.paused');
      case 'removed':
        return tr('discover.tasks.status.removed');
      case 'failed':
        return tr('discover.tasks.status.failed');
      case 'proposed':
        return tr('discover.tasks.status.proposed');
      default:
        return unknownStatusLabel();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('discover.tasks.empty'),
            icon: Icons.download_outlined,
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final r = _items[i];
        final status = '${r['status'] ?? ''}';
        return NasContextMenuRegion(
          entries: _taskMenuEntries(r),
          child: ListTile(
            dense: true,
            leading: Icon(
              status == 'failed'
                  ? Icons.error_outline
                  : status == 'removed'
                      ? Icons.delete_outline
                      : status == 'paused'
                          ? Icons.pause_circle_outline
                          : status == 'done'
                              ? Icons.check_circle_outline
                              : Icons.downloading,
              size: 18,
            ),
            title: Text('${r['title'] ?? ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${_statusLabel(status)}'
              '${(r['message'] as String? ?? '').isNotEmpty ? ' · ${r['message']}' : ''}'
              ' · ${_time((r['createdAt'] as num?)?.toInt() ?? 0)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: r['canControl'] == true
                ? Wrap(
                    spacing: NasTokens.spaceXs,
                    children: [
                      if (status == 'added')
                        IconButton(
                          tooltip: tr('discover.tasks.pause'),
                          icon: const Icon(Icons.pause_circle_outline, size: 20),
                          onPressed: () => _action(r, 'pause'),
                        ),
                      if (status == 'paused')
                        IconButton(
                          tooltip: tr('discover.tasks.resume'),
                          icon: const Icon(Icons.play_circle_outline, size: 20),
                          onPressed: () => _action(r, 'resume'),
                        ),
                      IconButton(
                        tooltip: tr('discover.tasks.remove'),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => _action(r, 'remove'),
                      ),
                    ],
                  )
                : null,
          ),
        );
      },
    );
  }

  /// 右键菜单：与行尾按钮同一批动作，按状态给出可用项。
  ///
  /// 只有 `canControl`（有 infoHash 且已在 transmission 里）才有可操作项，
  /// 否则服务端会 400，菜单里就不摆死项。
  List<NasMenuEntry> _taskMenuEntries(Map<String, dynamic> r) {
    if (r['canControl'] != true) return const [];
    final status = '${r['status'] ?? ''}';
    final out = <NasMenuEntry>[];
    if (status == 'added') {
      out.add(
        NasMenuEntry(
          label: tr('discover.tasks.pause'),
          icon: Icons.pause_circle_outline,
          onSelected: () => _action(r, 'pause'),
        ),
      );
    }
    if (status == 'paused') {
      out.add(
        NasMenuEntry(
          label: tr('discover.tasks.resume'),
          icon: Icons.play_circle_outline,
          onSelected: () => _action(r, 'resume'),
        ),
      );
    }
    if (out.isNotEmpty) out.add(const NasMenuEntry.divider());
    out.add(
      NasMenuEntry(
        label: tr('discover.tasks.remove'),
        icon: Icons.delete_outline,
        danger: true,
        onSelected: () => _action(r, 'remove'),
      ),
    );
    return out;
  }

  static String _time(int seconds) {
    if (seconds <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// 设置：TMDB 凭据 + 评分体系（豆瓣 Cookie）。
///
/// TMDB Key 是「填一次、全局用」的配置项，不再藏在 AppBar 齿轮里；
/// 服务端只回 `apiKeyConfigured`，不回明文，输入框留空表示不修改。
class _SettingsTab extends StatefulWidget {
  const _SettingsTab();

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  final _key = TextEditingController();
  final _lang = TextEditingController(text: 'zh-CN');
  final _apiUrl = TextEditingController();
  final _imageBase = TextEditingController();
  final _cookie = TextEditingController();

  DiscoverSettings? _settings;
  bool _loading = true;
  bool _savingTmdb = false;
  bool _savingDouban = false;
  String? _error;

  // D5：下载目录 / 下载筛选（存 pt.download；与订阅选种、transmission 联动）

  List<VideoLibraryItem> _videoLibs = const [];
  List<Map<String, dynamic>> _ptSites = const [];
  bool _loadingDownload = true;
  bool _savingDownload = false;
  String? _downloadError;
  String _movieLibId = '';
  String _tvLibId = '';
  final Set<String> _siteIds = {};
  String _quality = 'all';
  String _hdr = 'all';
  final Set<String> _audioLangs = {};
  final _maxSize = TextEditingController(text: '0');
  final _minSeeders = TextEditingController(text: '3');
  final _excluded = TextEditingController();
  double _scanInterval = 360;
  bool _autoDownload = true;

  @override
  void initState() {
    super.initState();
    _load();
    _loadDownload();
  }

  @override
  void dispose() {
    _key.dispose();
    _lang.dispose();
    _apiUrl.dispose();
    _imageBase.dispose();
    _cookie.dispose();
    _maxSize.dispose();
    _minSeeders.dispose();
    _excluded.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await ApiSession.instance.client.discoverSettingsGet();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _lang.text = settings.language.isEmpty ? 'zh-CN' : settings.language;
        _apiUrl.text = settings.baseUrl;
        _imageBase.text = settings.imageBase;
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

  Future<void> _saveTmdb() async {
    setState(() => _savingTmdb = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.discoverSettingsSet(
        body: DiscoverSettingsBody(
          apiKey: _key.text.trim().isEmpty ? null : _key.text.trim(),
          language: _lang.text.trim().isEmpty ? null : _lang.text.trim(),
          baseUrl: _apiUrl.text.trim().isEmpty ? null : _apiUrl.text.trim(),
          imageBase: _imageBase.text.trim().isEmpty
              ? null
              : _imageBase.text.trim(),
        ),
      );
      if (!mounted) return;
      setState(() {
        _settings = res;
        _key.clear();
      });
      NasSnack.showOn(messenger, tr('discover.settings.saved'));
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    } finally {
      if (mounted) setState(() => _savingTmdb = false);
    }
  }

  Future<void> _saveDouban() async {
    setState(() => _savingDouban = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.discoverDoubanSettings(
        body: {'cookie': _cookie.text.trim()},
      );
      NasSnack.showOn(messenger, tr('discover.settings.saved'));
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    } finally {
      if (mounted) setState(() => _savingDouban = false);
    }
  }

  Future<void> _loadDownload() async {
    setState(() {
      _loadingDownload = true;
      _downloadError = null;
    });
    try {
      final c = ApiSession.instance.client;
      final dl = await c.ptDownloadSettingsGet();
      final libs = await c.videoLibraryList();
      final sites = await c.ptSiteList();
      if (!mounted) return;
      final s = dl.settings;
      setState(() {

        _videoLibs = libs.items;
        _ptSites = ((sites['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _movieLibId = s.movieLibraryId;
        _tvLibId = s.tvLibraryId;
        _siteIds
          ..clear()
          ..addAll(s.siteIds);
        _quality = s.quality;
        _hdr = s.hdr;
        _audioLangs
          ..clear()
          ..addAll(s.audioLangs);
        _maxSize.text = s.maxSizeBytes > 0
            ? (s.maxSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(0)
            : '0';
        _minSeeders.text = '${s.minSeeders}';
        _excluded.text = s.excludedKeywords.join(', ');
        _scanInterval = s.scanIntervalMin.toDouble();
        _autoDownload = s.autoDownload;
        _loadingDownload = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadError = '$e';
        _loadingDownload = false;
      });
    }
  }

  Future<void> _saveDownload() async {
    setState(() => _savingDownload = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final gb = (double.tryParse(_maxSize.text.trim()) ?? 0).clamp(0, 100000);
      await ApiSession.instance.client.ptDownloadSettingsSet(
        body: PtDownloadSettingsBody(
          movieLibraryId: _movieLibId,
          tvLibraryId: _tvLibId,
          siteIds: _siteIds.toList(),
          quality: _quality,
          hdr: _hdr,
          audioLangs: _audioLangs.toList(),
          maxSizeBytes: (gb * 1024 * 1024 * 1024).round(),
          minSeeders: int.tryParse(_minSeeders.text.trim()) ?? 0,
          excludedKeywords: _excluded.text
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
          scanIntervalMin: _scanInterval.round(),
          autoDownload: _autoDownload,
        ),
      );
      if (!mounted) return;
      setState(() {});
      NasSnack.showOn(messenger, tr('discover.settings.saved'));
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    } finally {
      if (mounted) setState(() => _savingDownload = false);
    }
  }

  Future<void> _scanFavorites() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final list = await ApiSession.instance.client.ptSubscriptionList();
      final subs = ((list['items'] as List?) ?? const [])
          .whereType<Map>()
          .toList();
      final enabled = subs.where((e) => e['enabled'] != false).toList();
      var ok = 0;
      for (final s in enabled.take(20)) {
        final r = await ApiSession.instance.client.ptSubscriptionRun(
          body: <String, dynamic>{'id': '${s['id']}'},
        );
        if (r['ok'] == true) ok++;
      }
      NasSnack.showOn(messenger, tr('discover.settings.scanDone', {
            'ok': '$ok',
            'total': '${enabled.length}',
          }));
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  Widget _libraryDropdown({
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    final ids = _videoLibs.map((l) => l.id).toSet();
    final current = ids.contains(value) ? value : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: NasDropdown<String>(
        initialValue: current,
        isDense: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(tr('discover.settings.noLibrary')),
          ),
          for (final lib in _videoLibs)
            DropdownMenuItem(
              value: lib.id,
              child: Text(
                '${lib.name} · ${lib.path}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) => onChanged(v ?? ''),
      ),
    );
  }

  Widget _downloadCard() {
    if (_loadingDownload) {
      return _card(
        title: tr('discover.settings.downloadDirs'),
        children: const [LinearProgressIndicator()],
      );
    }
    if (_downloadError != null) {
      return _card(
        title: tr('discover.settings.downloadDirs'),
        children: [
          Text(_downloadError!, style: TextStyle(color: context.nasDanger)),
          const SizedBox(height: NasTokens.spaceSm),
          OutlinedButton(onPressed: _loadDownload, child: Text(tr('common.retry'))),
        ],
      );
    }
    const audioOptions = <(String, String)>[
      ('zh', 'discover.settings.audio.zh'),
      ('zhTW', 'discover.settings.audio.zhTW'),
      ('yue', 'discover.settings.audio.yue'),
      ('ja', 'discover.settings.audio.ja'),
      ('ko', 'discover.settings.audio.ko'),
      ('en', 'discover.settings.audio.en'),
    ];
    String anyOr(String v) =>
        v == 'all' ? tr('discover.settings.any') : v;
    return Column(
      children: [
        _card(
          title: tr('discover.settings.downloadDirs'),
          children: [
            _libraryDropdown(
              label: tr('discover.settings.movieDir'),
              value: _movieLibId,
              onChanged: (v) => setState(() => _movieLibId = v),
            ),
            _libraryDropdown(
              label: tr('discover.settings.tvDir'),
              value: _tvLibId,
              onChanged: (v) => setState(() => _tvLibId = v),
            ),
            Text(
              tr('discover.settings.downloadHint'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ],
        ),
        _card(
          title: tr('discover.settings.downloadFilter'),
          children: [
            Text(
              tr('discover.settings.sites'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: NasTokens.spaceXs),
            if (_ptSites.isEmpty)
              Text(
                tr('discover.settings.any'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              )
            else
              Wrap(
                spacing: NasTokens.spaceXs,
                runSpacing: NasTokens.spaceXs,
                children: [
                  for (final site in _ptSites)
                    NasChip(
                      label: Text('${site['name'] ?? site['id'] ?? ''}'),
                      selected: _siteIds.contains('${site['id'] ?? ''}'),
                      onSelected: (on) => setState(() {
                        final id = '${site['id'] ?? ''}';
                        if (on) {
                          _siteIds.add(id);
                        } else {
                          _siteIds.remove(id);
                        }
                      }),
                    ),
                ],
              ),
            const SizedBox(height: NasTokens.spaceSm),
            Row(
              children: [
                Expanded(
                  child: NasDropdown<String>(
                    initialValue: _quality,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: tr('discover.settings.quality'),
                      isDense: true,
                    ),
                    items: [
                      for (final q in const ['all', '1080p', '1440p', '4k'])
                        DropdownMenuItem(value: q, child: Text(anyOr(q))),
                    ],
                    onChanged: (v) => setState(() => _quality = v ?? 'all'),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                Expanded(
                  child: NasDropdown<String>(
                    initialValue: _hdr,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: tr('discover.settings.hdr'),
                      isDense: true,
                    ),
                    items: [
                      for (final h in const [
                        'all',
                        'hdr',
                        'hdr10',
                        'hdr10plus',
                        'dolby',
                      ])
                        DropdownMenuItem(value: h, child: Text(anyOr(h))),
                    ],
                    onChanged: (v) => setState(() => _hdr = v ?? 'all'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceSm),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tr('discover.settings.audioLangs'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: NasTokens.spaceXs),
            Wrap(
              spacing: NasTokens.spaceXs,
              runSpacing: NasTokens.spaceXs,
              children: [
                for (final a in audioOptions)
                  NasChip(
                    label: Text(tr(a.$2)),
                    selected: _audioLangs.contains(a.$1),
                    onSelected: (on) => setState(() {
                      if (on) {
                        _audioLangs.add(a.$1);
                      } else {
                        _audioLangs.remove(a.$1);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceSm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _maxSize,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('discover.settings.maxSize'),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                Expanded(
                  child: TextField(
                    controller: _minSeeders,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('discover.settings.minSeeders'),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceSm),
            TextField(
              controller: _excluded,
              decoration: InputDecoration(
                labelText: tr('discover.settings.excluded'),
                isDense: true,
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${tr('discover.settings.scanInterval')}：${_scanInterval.round()}',
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _scanInterval,
                    min: 5,
                    max: 360,
                    divisions: 71,
                    label: '${_scanInterval.round()}',
                    onChanged: (v) => setState(() => _scanInterval = v),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(tr('discover.settings.autoDownload')),
              value: _autoDownload,
              onChanged: (v) => setState(() => _autoDownload = v),
            ),
            const SizedBox(height: NasTokens.spaceXs),
            Wrap(
              spacing: NasTokens.spaceSm,
              runSpacing: NasTokens.spaceXs,
              children: [
                FilledButton(
                  onPressed: _savingDownload ? null : _saveDownload,
                  child: Text(tr('common.save')),
                ),
                OutlinedButton.icon(
                  onPressed: _scanFavorites,
                  icon: const Icon(Icons.play_circle_outline, size: 18),
                  label: Text(tr('discover.settings.scanFavorites')),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceMd),
      child: NasCard(
        padding: const EdgeInsets.all(NasTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: NasTokens.spaceSm),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _load);
    }
    final configured = _settings?.apiKeyConfigured == true;
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        _card(
          title: tr('discover.settings.tmdb'),
          children: [
            Text(
              configured
                  ? tr('discover.settings.tmdbConfigured')
                  : tr('discover.settings.tmdbNotConfigured'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: configured
                    ? context.nasSuccess
                    : context.nasTextSecondary,
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: InputDecoration(
                labelText: tr('discover.settings.tmdbKey'),
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            Row(
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _lang,
                    decoration: InputDecoration(
                      labelText: tr('discover.settings.language'),
                      hintText: 'zh-CN',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                Expanded(
                  child: TextField(
                    controller: _apiUrl,
                    decoration: InputDecoration(
                      labelText: tr('discover.settings.apiUrl'),
                      hintText: 'https://api.themoviedb.org/3',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceSm),
            TextField(
              controller: _imageBase,
              decoration: InputDecoration(
                labelText: tr('discover.settings.imageBase'),
                hintText: 'https://image.tmdb.org/t/p',
                isDense: true,
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _savingTmdb ? null : _saveTmdb,
                child: Text(tr('common.save')),
              ),
            ),
          ],
        ),
        _card(
          title: tr('discover.settings.scoreSystem'),
          children: [
            Text(
              tr('discover.settings.doubanCookie'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: NasTokens.spaceXs),
            Text(
              tr('discover.settings.hint'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            TextField(
              controller: _cookie,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Cookie',
                hintText: 'dbcl2=…',
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _savingDouban ? null : _saveDouban,
                child: Text(tr('common.save')),
              ),
            ),
          ],
        ),
        _downloadCard(),
      ],
    );
  }
}
