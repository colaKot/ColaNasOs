import 'dart:async';

// 从既有实现按接口约定实现：以下 lint 属于参考源码风格，保持 1:1 不改写。
// ignore_for_file: use_null_aware_elements, unnecessary_underscores, use_build_context_synchronously, unused_element, dead_code, dead_null_aware_expression
import '../../photo/folder_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../../shell/app_nav_shell.dart';
import 'compat/getx.dart';
import 'compat/i18n.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/display_labels.dart';
import 'compat/cola_api_controller.dart';
import 'compat/cola_context_menu_util.dart';
import 'compat/cola_device_utils.dart';
import 'compat/cola_custom_context_menu_item.dart';
import 'discover_controller.dart';

/// 影视发现应用壳。
/// 四个页签：发现 / PT / RSS / 任务。
class DiscoverView extends StatelessWidget {
  const DiscoverView({super.key, this.appMode = false});

  final bool appMode;

  @override
  Widget build(BuildContext context) {
    final controller = Get.isRegistered<DiscoverController>()
        ? Get.find<DiscoverController>()
        : Get.put(DiscoverController());
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DiscoverTopBar(controller),
            const Divider(height: 1),
            Expanded(
              child: Obx(() => IndexedStack(
                    index: controller.tabIndex.value,
                    children: [
                      _DiscoverTab(controller),
                      _PtTab(controller),
                      _RssTab(controller),
                      _TasksTab(controller),
                      _SettingsTab(controller),
                    ],
                  )),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtSize(dynamic bytes) {
  final n = bytes is num ? bytes.toDouble() : double.tryParse('$bytes') ?? 0;
  if (n <= 0) return '-';
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (n >= gb) return '${(n / gb).toStringAsFixed(2)} GB';
  return '${(n / mb).toStringAsFixed(1)} MB';
}

/// 把 TMDB 图片统一改写成**服务端代理地址**。
/// 服务端会带上用户配置的代理去抓 image.tmdb.org 并落盘缓存；
/// 浏览器直连 TMDB CDN 在国内经常几十秒不出图，这是「慢」的主要观感来源之一。
String _proxiedImage(String raw, {String size = 'w342'}) {
  final s = (raw ?? '').toString().trim();
  if (s.isEmpty) return '';
  var path = s;
  final idx = s.indexOf('/t/p/');
  if (idx >= 0) {
    // https://image.tmdb.org/t/p/w500/abc.jpg → /abc.jpg
    final rest = s.substring(idx + 5);
    final slash = rest.indexOf('/');
    path = slash >= 0 ? rest.substring(slash) : '';
  }
  if (!path.startsWith('/')) return s; // 非 TMDB 相对路径：原样返回
  final base = ApiController.instance.baseUrl.replaceAll(RegExp(r'/+$'), '');
  return '$base/api/v1/discover/image?path=${Uri.encodeComponent(path)}&size=$size';
}

/// 取条目海报（优先用相对路径，回退到后端给的绝对地址）
String _posterOf(Map<String, dynamic> item, {String size = 'w342'}) {
  final p = (item['poster_path'] ?? '').toString();
  return _proxiedImage(p.isNotEmpty ? p : (item['poster_url'] ?? '').toString(), size: size);
}

/// 与「日本片榜单」一致的胶囊按钮样式
Widget _pill(
  ThemeData theme, {
  required String label,
  required bool selected,
  VoidCallback? onTap,
  bool dense = false,
  IconData? icon,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      height: dense ? 26 : 30,
      padding: EdgeInsets.symmetric(horizontal: dense ? 12 : 14),
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.primary
            : theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon,
                size: dense ? 13 : 15,
                color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: (dense ? theme.textTheme.labelMedium : theme.textTheme.labelLarge)?.copyWith(
              color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 顶部：标题（左上）+ 胶囊页签（不用 AppBar 的 TabBar，避免默认样式难看/占高）
class _DiscoverTopBar extends StatelessWidget {
  const _DiscoverTopBar(this.c);

  final DiscoverController c;

  static const List<Map<String, String>> _tabs = [
    {'index': '0', 'label': 'discover_tab_discover'},
    {'index': '1', 'label': 'discover_tab_pt'},
    {'index': '2', 'label': 'discover_tab_rss'},
    {'index': '3', 'label': 'discover_tab_tasks'},
    {'index': '4', 'label': 'discover_tab_settings'},
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 应用名由窗口标题栏统一绘制（pc_app_window），这里只放页签 + 刷新，避免出现两个「影视发现」
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Obx(() => Row(
                    children: [
                      for (final t in _tabs) ...[
                        _pill(
                          theme,
                          label: t['label']!.tr,
                          selected: c.tabIndex.value == int.parse(t['index']!),
                          onTap: () => c.setTab(int.parse(t['index']!)),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  )),
            ),
          ),
          const SizedBox(width: 8),
          Obx(() => IconButton(
                tooltip: 'discover_refresh'.tr,
                visualDensity: VisualDensity.compact,
                onPressed: c.browsing.value ? null : () => c.loadBrowse(reset: true),
                icon: c.browsing.value
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, size: 20),
              )),
        ],
      ),
    );
  }
}

// ==================== 发现（筛选 + 排序） ====================
/// 影视关键词搜索栏（TMDB 全库搜索：回车或点「搜索」触发）
class _MediaSearchBar extends StatefulWidget {
  const _MediaSearchBar(this.c);

  final DiscoverController c;

  @override
  State<_MediaSearchBar> createState() => _MediaSearchBarState();
}

class _MediaSearchBarState extends State<_MediaSearchBar> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  /// 方形圆角的小图标按钮：手机端「回工作台」和「搜索」都用它。
  ///
  /// 以前搜索按钮是带文字的 `FilledButton`，在窄屏上把输入框挤得只剩两个汉字宽。
  Widget _squareIcon(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool filled = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.nasStyle;
    final radius = BorderRadius.circular(10);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled ? scheme.primary : style.panelColor,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: filled
                ? scheme.primary.withValues(alpha: 0.55)
                : style.panelBorderColor,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              icon,
              size: 18,
              color: filled ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    // 手机端：进了 App 之后就没有一级导航了，顶部胶囊被底部标签接管，
    // 这里必须补一个「回工作台」的入口，否则只能靠系统手势退出。
    final compact =
        layoutFor(MediaQuery.sizeOf(context).width) == LayoutMode.compact;
    return Obx(() {
      final active = c.mediaSearchKeyword.value.isNotEmpty;
      return Row(
        children: [
          if (compact && AppNavShell.onExitToHome != null) ...[
            _squareIcon(
              context,
              icon: Icons.home_outlined,
              tooltip: 'nav.home'.tr,
              onTap: AppNavShell.onExitToHome,
            ),
            const SizedBox(width: 8),
          ],
          // 不再整行铺满：搜索框有上限宽度，右侧按钮才有地方站
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: TextField(
                controller: _ctl,
                textInputAction: TextInputAction.search,
                onSubmitted: (v) => c.searchMediaKeyword(v),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'discover_media_search_hint'.tr,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Obx(
            () => _squareIcon(
              context,
              icon: Icons.search,
              tooltip: 'discover_search'.tr,
              filled: true,
              onTap: c.searching.value
                  ? null
                  : () => c.searchMediaKeyword(_ctl.text),
            ),
          ),
          if (active) ...[
            const SizedBox(width: 6),
            TextButton(
              onPressed: () {
                _ctl.clear();
                c.clearMediaSearch();
              },
              child: Text('discover_catalog_back'.tr),
            ),
          ],
          // 顶栏（原 `_DiscoverTopBar`）里的刷新按钮随胶囊一起撤掉了，
          // 这里补一个，否则手机端就没有「重新拉一遍发现页」的入口。
          const SizedBox(width: 6),
          _squareIcon(
            context,
            icon: Icons.refresh,
            tooltip: 'discover_refresh'.tr,
            onTap: c.browsing.value ? null : () => c.loadBrowse(reset: true),
          ),
        ],
      );
    });
  }
}

/// 榜单模式下的信息条：当前榜单名 + 刷新
class _CatalogInfoBar extends StatelessWidget {
  const _CatalogInfoBar(this.c);

  final DiscoverController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final def = DiscoverController.kCatalogDefs.firstWhere(
      (d) => d['code'] == c.catalogCode.value,
      orElse: () => DiscoverController.kCatalogDefs.first,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Row(
        children: [
          Icon(Icons.local_fire_department, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text('${def['label']!.tr} · ${'discover_catalog_official'.tr}',
              style: theme.textTheme.bodySmall),
          const Spacer(),
          TextButton.icon(
            onPressed: () => c.loadCatalog(),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text('discover_refresh'.tr),
          ),
        ],
      ),
    );
  }
}

class _DiscoverTab extends StatelessWidget {
  const _DiscoverTab(this.c);

  final DiscoverController c;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final searchMode = c.mediaSearchKeyword.value.isNotEmpty;
      final bool catalog = c.catalogMode;
      final List<Map<String, dynamic>> items =
          catalog ? c.catalogItems : (searchMode ? c.mediaSearchResults : c.browseItems);
      final bool loading = catalog
          ? c.catalogLoading.value
          : (searchMode
              ? c.mediaSearching.value
              : (c.browsing.value && c.browseItems.isEmpty));
      // 滚到底部自动加载下一页（不再用「加载更多」按钮）
      return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (c.hasMore &&
              !c.browsing.value &&
              n.metrics.axis == Axis.vertical &&
              n.metrics.pixels >= n.metrics.maxScrollExtent - 300) {
            c.loadMore();
          }
          return false;
        },
        child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _DiscoverHeader(c)),
          if (loading && items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    searchMode
                        ? 'discover_media_search_empty'.tr
                        : (catalog ? 'discover_catalog_empty'.tr : 'discover_no_more'.tr),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 170,
                  childAspectRatio: 0.58,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    final item = items[i];
                    final rawId = item['id'];
                    final mediaId = rawId is int ? rawId : null;
                    return _BrowseCard(
                      item: item,
                      rating: c.ratingOf(item),
                      onTap: () => _showMediaDetail(ctx, c, item),
                      onToggleFav: () {
                        if (catalog || searchMode) {
                          if (mediaId != null) c.toggleFavoriteByMediaId(mediaId);
                        } else {
                          c.toggleFavorite(i);
                        }
                      },
                      // 右键菜单：订阅（可切换）/ 搜索 PT 资源
                      subscribed: mediaId != null && c.isSubscribed(mediaId),
                      onSubscribe: mediaId == null
                          ? null
                          : () {
                              final subId = c.subscriptionIdOf(mediaId);
                              if (subId != null) {
                                c.unsubscribe(subId);
                              } else {
                                c.subscribe(mediaId);
                              }
                            },
                      onSearch:
                          mediaId == null ? null : () => _showPtResults(ctx, c, mediaId: mediaId),
                    );
                  },
                  childCount: items.length,
                ),
              ),
            ),
          if (!catalog && !searchMode && items.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 64),
                child: Center(
                  child: c.hasMore
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text('discover_no_more'.tr,
                          style: Theme.of(context).textTheme.bodySmall),
                ),
              ),
            ),
        ],
      ),
      );
    });
  }
}

class _DiscoverHeader extends StatelessWidget {
  const _DiscoverHeader(this.c);

  final DiscoverController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 影视关键词搜索（TMDB 全库）
          _MediaSearchBar(c),
          const SizedBox(height: 8),
          // 榜单入口（今日热门 / 本周热门 / 最受欢迎 / 即将上映 / 正在播出）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final d in c.availableCatalogs) ...[
                  _pill(theme,
                      dense: true,
                      label: d['label']!.tr,
                      selected: c.catalogCode.value == d['code'],
                      icon: Icons.local_fire_department,
                      onTap: () => c.openCatalog(d['code']!)),
                  const SizedBox(width: 6),
                ],
                if (c.catalogMode)
                  _pill(theme,
                      dense: true,
                      label: 'discover_catalog_back'.tr,
                      selected: false,
                      icon: Icons.grid_view,
                      onTap: c.closeCatalog),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // 类型 + 排序（排序紧跟类型，不再贴到行尾）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _pill(theme,
                    label: 'discover_movie'.tr,
                    selected: c.mediaType.value == 'movie',
                    onTap: () => c.setMediaType('movie')),
                const SizedBox(width: 6),
                _pill(theme,
                    label: 'discover_tv'.tr,
                    selected: c.mediaType.value == 'tv',
                    onTap: () => c.setMediaType('tv')),
                Container(
                    width: 1,
                    height: 16,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color: theme.dividerColor),
                // 排序：用触发控件的 context 定位，菜单才会贴着它弹出
                Builder(
                  builder: (ctx) => _pill(
                    theme,
                    dense: true,
                    label: c.sortLabel,
                    selected: false,
                    icon: Icons.swap_vert,
                    onTap: () => _showSortMenu(ctx, c),
                  ),
                ),
              ],
            ),
          ),
          // 榜单模式下隐藏筛选（榜单是 TMDB 官方排序，筛选项不适用）
          if (!c.catalogMode) ...[
          const SizedBox(height: 10),
          // 风格（多选）
          _titleRow(theme, 'discover_genre'),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: c.genres.map((g) {
                final id = (g['id'] as num?)?.toInt() ?? 0;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _pill(theme,
                      dense: true,
                      label: (g['name'] ?? '').toString(),
                      selected: c.genreIds.contains(id),
                      onTap: () => c.toggleGenre(id)),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 10),
          // 年代（原语言栏改为年代）
          _titleRow(theme, 'discover_year'),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: kDiscoverYears.map((y) {
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _pill(theme,
                      dense: true,
                      label: y['label']!.tr,
                      selected: c.yearCode.value == y['code'],
                      onTap: () => c.setYear(y['code']!)),
                );
              }).toList(),
            ),
          ),
          // 国家/地区（跟在年代后面，四个档 + 不限）
          _titleRow(theme, 'discover_country'),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: kDiscoverCountries.map((y) {
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _pill(theme,
                      dense: true,
                      label: y['label']!.tr,
                      selected: c.countryCode.value == y['code'],
                      onTap: () => c.setCountry(y['code']!)),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 6),
          // 评分下限
          Row(
            children: [
              Text(
                '${'discover_min_score'.tr}：${c.minVote.value.toStringAsFixed(1)} ${'discover_score_unit'.tr}',
                style: theme.textTheme.bodyMedium,
              ),
              Expanded(
                child: Slider(
                  value: c.minVote.value,
                  min: 0,
                  max: 10,
                  divisions: 20,
                  label: c.minVote.value.toStringAsFixed(1),
                  onChanged: c.setMinVote,
                  onChangeEnd: (v) => c.loadBrowse(reset: true),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text('${'discover_total'.tr} ${c.totalResults.value}',
                  style: theme.textTheme.bodySmall),
              const Spacer(),
              TextButton.icon(
                onPressed: c.resetFilters,
                icon: const Icon(Icons.restart_alt, size: 16),
                label: Text('discover_reset'.tr),
              ),
            ],
          ),
          ],
          if (c.catalogMode) _CatalogInfoBar(c),
        ],
      ),
    );
  }
}

/// 评分按分值配色：<6 灰 / 6–7 蓝 / 7–8 绿 / ≥8 橙
Color _ratingColor(num v) {
  final x = v.toDouble();
  if (x >= 8) return Colors.deepOrange.shade600;
  if (x >= 7) return Colors.green.shade600;
  if (x >= 6) return Colors.blue.shade600;
  return Colors.blueGrey.shade400;
}

/// 小标题
Widget _titleRow(ThemeData theme, String labelKey) => Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6),
      child: Text('${labelKey.tr}：', style: theme.textTheme.bodySmall),
    );

/// 排序弹出菜单（胶囊样式触发）
Future<void> _showSortMenu(BuildContext context, DiscoverController c) async {
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  RelativeRect position = const RelativeRect.fromLTRB(80, 160, 0, 0);
  if (box != null && overlay != null && box.hasSize) {
    position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
  }
  final selected = await showMenu<String>(
    context: context,
    position: position,
    items: c.sortOptions
        .map((o) => PopupMenuItem<String>(value: o['value'], child: Text(o['label']!.tr)))
        .toList(),
  );
  if (selected != null) c.setSort(selected);
}

class _BrowseCard extends StatelessWidget {
  const _BrowseCard({
    required this.item,
    required this.onTap,
    required this.onToggleFav,
    this.onSubscribe,
    this.onSearch,
    this.subscribed = false,
    this.rating,
    this.compact = false,
  });

  final Map<String, dynamic> item;
  final VoidCallback onTap;
  final VoidCallback onToggleFav;
  // 右键菜单：订阅 / 搜索（仅桌面 / Web 端可用）
  final VoidCallback? onSubscribe;
  final VoidCallback? onSearch;
  final bool subscribed;
  /// 当前评分体系下的展示分（TMDB 或豆瓣，由 DiscoverController.ratingOf 决定）
  final double? rating;
  /// 紧凑版（待下载列表用）：更小的字号、只留海报角上的收藏星，去掉类型/评分角标
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final poster = _posterOf(item);
    final isTv = (item['media_type'] ?? 'movie') == 'tv';
    final card = InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 海报高度改成弹性：网格给的是固定高度（childAspectRatio 0.58），
          // 若海报按 2/3 死比例吃满宽度，标题两行 + 年份就会把 Column 撑爆
          // （162.6 宽时溢出 4.6px）。这里让海报吃掉剩余空间，比例差在 1% 内。
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: poster.isEmpty
                        ? Container(
                            color: Colors.black12,
                            child: const Icon(Icons.movie_outlined),
                          )
                        : Image.network(
                            poster,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.black12,
                              child: const Icon(Icons.broken_image_outlined),
                            ), headers: compatAuthHeaders,),
                  ),
                ),
                // 左上：状态角标 —— 已在影视库打勾 / 下载中 / 已下载（删了文件也保留），
                // 都没有时才显示类型角标（紧凑版省掉，卡片小的时候角标会盖住海报）
                if (!compact)
                  Positioned(left: 4, top: 4, child: _stateBadge(isTv)),
                // 右上：评分
                if (!compact && rating != null && rating! > 0)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: _pill(
                      '★ ${rating!.toStringAsFixed(1)}',
                      _ratingColor(rating!),
                    ),
                  ),
                // 右下：收藏五角星（点击切换）
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: compact ? 17 : 20,
                    padding: compact ? EdgeInsets.zero : null,
                    constraints: compact
                        ? const BoxConstraints.tightFor(width: 26, height: 26)
                        : null,
                    icon: Icon(
                      item['favorited'] == true ? Icons.star : Icons.star_border,
                      color: item['favorited'] == true ? Colors.amber : Colors.white,
                    ),
                    onPressed: onToggleFav,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: compact ? 3 : 5),
          Text(
            (item['title'] ?? '') as String,
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 12.5 : 15,
              fontWeight: FontWeight.w600,
              height: 1.18,
            ),
          ),
          if ((item['release_date'] ?? '').toString().isNotEmpty)
            Text(
              (item['release_date'] as String).split('-').first,
              style: TextStyle(
                fontSize: compact ? 10.5 : 12.5,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.92),
              ),
            ),
        ],
      ),
    );
    // 仅桌面 / Web 端提供右键菜单（手机端没有「右键」）
    if (!DeviceUtils.isDesktopOrWeb) return card;
    final entries = <ContextMenuEntry>[
      ColaContextMenuItem.create(
        label: Text(subscribed ? 'discover_sub_added'.tr : 'discover_sub_add'.tr),
        icon: Icon(subscribed ? Icons.star : Icons.star_border, size: 18),
        value: 'subscribe',
        onSelected: (_) => onSubscribe?.call(),
      ),
      ColaContextMenuItem.create(
        label: Text('discover_search'.tr),
        icon: const Icon(Icons.search, size: 18),
        value: 'search',
        onSelected: (_) => onSearch?.call(),
      ),
    ];
    return ContextMenuUtil.region(child: card, entries: entries);
  }

  /// 左上角状态角标：在影视库 → 绿底勾（优先）；下载中 / 已下载 → 文字角标；
  /// 都没有才显示「电影 / 剧集」类型角标。
  Widget _stateBadge(bool isTv) {
    final state = (item['download_state'] ?? '').toString();
    if (item['owned'] == true) {
      return Tooltip(
        message: 'discover_in_library'.tr,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.green.shade600,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white70, width: 1),
          ),
          child: const Icon(Icons.check, size: 13, color: Colors.white),
        ),
      );
    }
    if (state == 'downloading') {
      return _pill('discover_downloading'.tr, Colors.blue.shade700);
    }
    if (state == 'downloaded') {
      return _pill('discover_downloaded'.tr, Colors.blueGrey.shade700);
    }
    return _pill(isTv ? 'discover_tv'.tr : 'discover_movie'.tr, Colors.black54);
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 10)),
    );
  }
}

Future<void> _showMediaDetail(
    BuildContext context, DiscoverController c, Map<String, dynamic> item) async {
  final mediaType = (item['media_type'] ?? 'movie') as String;
  final id = item['id'];
  if (id == null) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _MediaDetailPage(c: c, mediaType: mediaType, mediaId: id, preview: item),
    ),
  );
}

Future<void> _showPtResults(BuildContext context, DiscoverController c,
    {int? mediaId, String? keyword}) async {
  await c.runSearch(mediaId: mediaId, keyword: keyword);
  if (!context.mounted) return;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Obx(() {
      if (c.searching.value) {
        return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
      }
      return SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('discover_pt_results'.tr,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            ...c.searchResults.map((r) => ListTile(
                  title: Text((r['title'] ?? '') as String, maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${r['site_name'] ?? ''} · ${r['resolution'] ?? '-'} · ${_fmtSize(r['size_bytes'])} · ↑${r['seeders'] ?? '-'}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.download),
                    onPressed: () async {
                      final id = r['candidate_id'];
                      if (id is int) await c.submitCandidate(id);
                    },
                  ),
                )),
            if (c.searchResults.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('discover_pt_empty'.tr),
              ),
          ],
        ),
      );
    }),
  );
}

// ==================== PT ====================
/// 订阅区块上方的「下载归档目录」：电影 / 剧集各选一个影视库。
/// 下载完成时服务端按这个库把文件扫进影视库（不选就跟随设置页里的默认目录）。
class _ArchiveTargetRow extends StatelessWidget {
  const _ArchiveTargetRow(this.c);

  final DiscoverController c;

  Future<void> _save({String? movieId, String? tvId}) async {
    final f = c.downloadFilter;
    // 服务端是全量覆盖，所以把当前筛选条件一起回传，避免只改库把站点/画质清空。
    await c.saveFilter(<String, dynamic>{
      'movie_library_id': movieId ?? (f['movie_library_id'] ?? '').toString(),
      'tv_library_id': tvId ?? (f['tv_library_id'] ?? '').toString(),
      'site_ids': (f['site_ids'] as List?) ?? const <dynamic>[],
      'quality': f['quality'] ?? 'all',
      'hdr': f['hdr'] ?? 'all',
      'audio_langs': (f['audio_langs'] as List?) ?? const <dynamic>[],
      'max_size_bytes': f['max_size_bytes'] ?? 0,
      'min_seeders': f['min_seeders'] ?? 0,
      'excluded_keywords': (f['excluded_keywords'] as List?) ?? const <dynamic>[],
      'scan_interval_minutes': f['scan_interval_minutes'] ?? 60,
      'auto_download': f['auto_download'] ?? true,
    });
  }

  /// 同一库有多个源目录时会重复出现，按 libraryId 去重后只列一次。
  List<Map<String, dynamic>> _libsOf(String type) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final s in c.videoSources) {
      final mt = (s['media_type'] ?? '').toString();
      final ok = type == 'movie'
          ? (mt == 'movie' || mt == 'mixed')
          : (mt == 'tv' || mt == 'mixed');
      final id = (s['libraryId'] ?? '').toString();
      if (!ok || id.isEmpty || !seen.add(id)) continue;
      out.add(s);
    }
    return out;
  }

  Widget _dropdown(BuildContext context, String label, String value, String type,
      ValueChanged<String> onChanged) {
    final libs = _libsOf(type);
    final has = libs.any((l) => (l['libraryId'] ?? '').toString() == value);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          isDense: true,
          value: has ? value : '',
          items: [
            DropdownMenuItem<String>(
              value: '',
              child: Text('discover_download_dir_default'.tr,
                  overflow: TextOverflow.ellipsis),
            ),
            for (final l in libs)
              DropdownMenuItem<String>(
                value: (l['libraryId'] ?? '').toString(),
                child: Text(
                  (l['libraryName'] ?? '').toString().isNotEmpty
                      ? (l['libraryName'] ?? '').toString()
                      : (l['path'] ?? '').toString(),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final f = c.downloadFilter;
      if (f.isEmpty) return const SizedBox.shrink();
      final movieId = (f['movie_library_id'] ?? '').toString();
      final tvId = (f['tv_library_id'] ?? '').toString();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('discover_archive_title'.tr,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('discover_archive_hint'.tr,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _dropdown(context, 'discover_archive_movie'.tr, movieId, 'movie',
                    (v) => _save(movieId: v)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _dropdown(context, 'discover_archive_tv'.tr, tvId, 'tv',
                    (v) => _save(tvId: v)),
              ),
            ],
          ),
        ],
      );
    });
  }
}

class _PtTab extends StatefulWidget {
  const _PtTab(this.c);

  final DiscoverController c;

  @override
  State<_PtTab> createState() => _PtTabState();
}

class _PtTabState extends State<_PtTab> {
  DiscoverController get c => widget.c;

  @override
  void initState() {
    super.initState();
    // 侧栏渲染不经过 `DiscoverController.setTab()`，这里自己把本页要的数据拉起来，
    // 否则站点 / 订阅 / 归档目录下拉全是空的。
    unawaited(c.loadSites());
    unawaited(c.loadSubscriptions());
    unawaited(c.loadFilter());
    unawaited(c.loadVideoSources());
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(child: Text('discover_pt_sites'.tr,
                style: Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(
              onPressed: () async {
                await c.loadSites();
                await showDialog<void>(context: context, builder: (_) => _AddSiteDialog(c));
              },
              icon: const Icon(Icons.add),
              label: Text('discover_add'.tr),
            ),
          ],
        ),
        Obx(() => Column(
              children: c.sites
                  .map((s) => Card(
                        child: ListTile(
                          title: Text((s['name'] ?? '') as String),
                          subtitle: Text(
                              '${s['adapter_type']} · ${s['last_test_status'] ?? '-'} · '
                              '${(s['credential_configured'] == true) ? 'token ✓' : 'token ✗'}'),
                          trailing: Wrap(children: [
                            IconButton(
                              tooltip: 'token',
                              icon: const Icon(Icons.key),
                              onPressed: () => showDialog<void>(
                                  context: context,
                                  builder: (_) => _SetTokenDialog(c, s)),
                            ),
                            IconButton(
                              tooltip: 'test',
                              icon: const Icon(Icons.wifi_tethering),
                              onPressed: () async {
                                final id = s['id'];
                                if (id is! int) return;
                                // 测试要真打一次站点（最长 30s），给个进度提示，
                                // 结果也说出来 —— 以前点完什么都不显示。
                                final messenger = ScaffoldMessenger.of(context);
                                messenger.showSnackBar(SnackBar(
                                  duration: const Duration(seconds: 40),
                                  content: Text('discover_pt_testing'.tr),
                                ));
                                final r = await c.testSite(id);
                                messenger.hideCurrentSnackBar();
                                final status = '${r?['status'] ?? 'fail'}';
                                final msg = '${r?['message'] ?? ''}';
                                messenger.showSnackBar(SnackBar(
                                  content: Text(
                                    '${'discover_pt_test_done'.tr}：$status'
                                    '${msg.isEmpty ? '' : ' · $msg'}',
                                  ),
                                ));
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                final id = s['id'];
                                if (id is int) await c.deleteSite(id);
                              },
                            ),
                          ]),
                        ),
                      ))
                  .toList(),
            )),
        const SizedBox(height: 12),
        // ===== 归档目录（下载完成后自动同步进哪个影视库）=====
        _ArchiveTargetRow(c),
        const SizedBox(height: 12),
        // ===== 订阅（针对具体影视，命中好种后自动下载）=====
        Row(
          children: [
            Expanded(
                child: Text('discover_sub_title'.tr,
                    style: Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(
              onPressed: () => c.loadSubscriptions(),
              icon: const Icon(Icons.refresh),
              label: Text('discover_refresh'.tr),
            ),
          ],
        ),
        Obx(() {
          if (c.subscriptions.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('discover_sub_empty'.tr,
                  style: Theme.of(context).textTheme.bodySmall),
            );
          }
          return Column(
            children: c.subscriptions.map((s) {
              final id = s['id'];
              final enabled = s['enabled'] == 1 || s['enabled'] == true;
              return Card(
                child: ListTile(
                  dense: true,
                  leading: _CoverThumb(f: s),
                  title: Text('${s['title'] ?? s['media_id'] ?? ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${mediaTypeLabel((s['media_type'] ?? '').toString())} · ${subscriptionStatusLabel((s['status'] ?? '').toString())} · ${'discover_sub_rule'.tr} ${s['rule_id'] ?? '-'}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Switch(
                      value: enabled,
                      onChanged: (v) async {
                        if (id is int) await c.setSubscriptionEnabled(id, v);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (id is int) await c.unsubscribe(id);
                      },
                    ),
                  ]),
                ),
              );
            }).toList(),
          );
        }),
        const SizedBox(height: 12),
        Text('discover_pt_search'.tr, style: Theme.of(context).textTheme.titleMedium),
        _SearchBox(c: c),
        const SizedBox(height: 8),
        Obx(() {
          if (c.searching.value) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (c.searchResults.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('discover_pt_empty'.tr,
                  style: Theme.of(context).textTheme.bodySmall),
            );
          }
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            // 参考图那样的一行多列：窗口越宽列数越多（约 380px 一列）
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 380,
              mainAxisExtent: 142,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: c.searchResults.length,
            itemBuilder: (_, i) => _PtResultCard(c: c, r: c.searchResults[i]),
          );
        }),
        // 站点异常：明确告诉用户「哪个站点没搜通、为什么」
        Obx(() {
          final errs = c.siteStatus
              .where((s) => ((s['error'] ?? '') as String).isNotEmpty)
              .toList();
          if (errs.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('discover_pt_site_error'.tr,
                    style: Theme.of(context).textTheme.titleSmall),
                for (final s in errs)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('· ${s['site_name'] ?? ''}: ${s['error'] ?? ''}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          );
        }),
        // 被规则排除的结果：不显示的话，「有结果但全被筛掉」看起来就像「搜不到」
        Obx(() {
          if (c.excludedResults.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${'discover_pt_excluded'.tr}（${c.excludedResults.length}）',
                    style: Theme.of(context).textTheme.titleSmall),
                for (final r in c.excludedResults.take(30))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '· ${(r['title'] ?? '').toString()} · ${r['site_name'] ?? ''} · ${_fmtSize(r['size_bytes'])} · ${ptExcludedReasonText((r['excluded_reason'] ?? '').toString())}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

/// PT 搜索结果卡片：站点/分辨率标签 + 大小 + 做种/下载 + 下载与详情入口
class _PtResultCard extends StatelessWidget {
  const _PtResultCard({required this.c, required this.r});

  final DiscoverController c;
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final site = (r['site_name'] ?? '').toString();
    final res = (r['resolution'] ?? '').toString();
    final detailUrl = (r['detail_url'] ?? '').toString();
    final seeders = (r['seeders'] as num?)?.toInt() ?? 0;
    final leechers = (r['leechers'] as num?)?.toInt() ?? 0;
    final seedColor = seeders > 0 ? Colors.green.shade600 : theme.disabledColor;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (site.isNotEmpty) _pill(theme, dense: true, label: site, selected: false),
                if (res.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _pill(theme, dense: true, label: res, selected: true),
                ],
                const Spacer(),
                Text(_fmtSize(r['size_bytes']),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 6),
            Text((r['title'] ?? '').toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, height: 1.3)),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.arrow_upward, size: 13, color: seedColor),
                const SizedBox(width: 2),
                Text('$seeders',
                    style: TextStyle(
                        fontSize: 12, color: seedColor, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                Icon(Icons.arrow_downward, size: 13, color: theme.disabledColor),
                const SizedBox(width: 2),
                Text('$leechers',
                    style: TextStyle(fontSize: 12, color: theme.disabledColor)),
                const Spacer(),
                if (detailUrl.isNotEmpty)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.open_in_new, size: 17),
                    onPressed: () => _openUrl(detailUrl),
                  ),
                FilledButton.icon(
                  onPressed: () async {
                    final id = r['candidate_id'];
                    if (id is int) await c.submitCandidate(id);
                  },
                  icon: const Icon(Icons.download, size: 15),
                  label: Text('download'.tr),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 收藏列表条目卡片（下载中 / 已下载共用；一行两列布局）
///
/// 待下载不用这张卡了 —— 那里和发现页一样走海报卡（见 `_BrowseCard` 的 compact 模式）。
class _FavItemCard extends StatelessWidget {
  const _FavItemCard({
    required this.f,
    this.showDownloadInfo = false,
    this.action,
    this.statusText,
  });

  final Map<String, dynamic> f;
  final bool showDownloadInfo;
  /// 右侧自定义操作（任务卡用 ⋮ 菜单，避免一行两列里挤三个按钮）
  final Widget? action;
  /// 追加状态文本（任务卡显示 Downloading / Paused 等）
  final String? statusText;

  @override
  Widget build(BuildContext context) {
    final year = (f['release_date'] ?? '').toString().split('-').first;
    final mt = (f['media_type'] ?? '').toString();
    // 没有影片信息时不留下孤零零的「 · 」（关键词搜索产生的任务就属于这种）
    final base = showDownloadInfo
        ? '${'discover_file_name'.tr}: ${f['torrent_name'] ?? '-'}\n'
            '${'discover_download_time'.tr}: ${(f['task_updated_at'] ?? '-').toString().replaceFirst('T', ' ').split('.').first}'
        : [if (year.isNotEmpty) year, if (mt.isNotEmpty) mt].join(' · ');
    final st = (statusText ?? '').trim();
    final sub = [if (base.isNotEmpty) base, if (st.isNotEmpty) st].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Row(
          children: [
            _CoverThumb(f: f),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text((f['title'] ?? '') as String,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(sub,
                      maxLines: showDownloadInfo ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            if (action != null) action!,
          ],
        ),
      ),
    );
  }
}

/// 收藏 / 已下载列表里的小封面（与发现页共用同一套服务端代理地址）
class _CoverThumb extends StatelessWidget {
  const _CoverThumb({required this.f});

  final Map<String, dynamic> f;

  @override
  Widget build(BuildContext context) {
    final url = _posterOf(f, size: 'w154');
    final bg = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 54,
        height: 80,
        child: url.isEmpty
            ? Container(color: bg, child: const Icon(Icons.movie_outlined, size: 20))
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Container(color: bg, child: const Icon(Icons.broken_image_outlined, size: 20)), headers: compatAuthHeaders,),
      ),
    );
  }
}

class _SearchBox extends StatefulWidget {
  const _SearchBox({required this.c});

  final DiscoverController c;

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            decoration: InputDecoration(hintText: 'discover_keyword_hint'.tr),
            onSubmitted: (v) => widget.c.runSearch(keyword: v),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () => widget.c.runSearch(keyword: _ctrl.text),
          child: Text('discover_search'.tr),
        ),
      ],
    );
  }
}

class _AddSiteDialog extends StatefulWidget {
  const _AddSiteDialog(this.c);

  final DiscoverController c;

  @override
  State<_AddSiteDialog> createState() => _AddSiteDialogState();
}

class _AddSiteDialogState extends State<_AddSiteDialog> {
  /// API 地址有默认值：用 M-Team 的人最多，其他站点直接改这一格就行，
  /// 不再单独要一个「网页地址」（2026-11-10 用户要求去掉）。
  final _name = TextEditingController();
  final _api = TextEditingController(text: 'https://api.m-team.cc');
  final _priority = TextEditingController(text: '0');
  final _timeout = TextEditingController(text: '20000');
  final _ua = TextEditingController();
  final _token = TextEditingController();
  final _cookie = TextEditingController();
  String _authMode = 'api';
  bool _rateLimit = true;
  bool _proxy = false;
  bool _browser = false;

  @override
  void dispose() {
    _name.dispose();
    _api.dispose();
    _priority.dispose();
    _timeout.dispose();
    _ua.dispose();
    _token.dispose();
    _cookie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('discover_pt_add_site'.tr),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: _name,
                decoration: InputDecoration(labelText: 'discover_site_name'.tr)),
            TextField(
                controller: _api,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(labelText: 'discover_site_api'.tr)),
            TextField(
                controller: _priority,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'discover_site_priority'.tr)),
            TextField(
                controller: _timeout,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'discover_site_timeout'.tr)),
            // 认证方式：API / COOKIE
            Row(
              children: [
                Text('${'discover_site_auth_mode'.tr}：'),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text('discover_site_auth_api'.tr),
                  selected: _authMode == 'api',
                  onSelected: (_) => setState(() => _authMode = 'api'),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: Text('discover_site_auth_cookie'.tr),
                  selected: _authMode == 'cookie',
                  onSelected: (_) => setState(() => _authMode = 'cookie'),
                ),
              ],
            ),
            if (_authMode == 'api')
              TextField(
                  controller: _token,
                  decoration: InputDecoration(labelText: 'discover_site_token'.tr))
            else
              TextField(
                  controller: _cookie,
                  maxLines: 3,
                  decoration: InputDecoration(
                      labelText: 'discover_site_cookie'.tr,
                      hintText: 'discover_site_cookie_hint'.tr)),
            TextField(
                controller: _ua,
                decoration: InputDecoration(labelText: 'discover_site_ua'.tr)),
            SwitchListTile(
              dense: true,
              title: Text('discover_site_rate_limit'.tr, style: const TextStyle(fontSize: 13)),
              value: _rateLimit,
              onChanged: (v) => setState(() => _rateLimit = v),
            ),
            SwitchListTile(
              dense: true,
              title: Text('discover_site_proxy'.tr, style: const TextStyle(fontSize: 13)),
              value: _proxy,
              onChanged: (v) => setState(() => _proxy = v),
            ),
            SwitchListTile(
              dense: true,
              title: Text('discover_site_browser'.tr, style: const TextStyle(fontSize: 13)),
              value: _browser,
              onChanged: (v) => setState(() => _browser = v),
            ),
          ],
        ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
        FilledButton(
          onPressed: () async {
            final name = _name.text.trim();
            final api = _api.text.trim();
            if (name.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('discover_site_name_required'.tr)),
              );
              return;
            }
            if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(api)) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('discover_site_api_invalid'.tr)),
              );
              return;
            }
            final err = await widget.c.addSite({
              'name': name,
              // 站点根地址就用 API 地址；kind 由 compat 层按域名判断（m-team → mteam）
              'api_base_url': api,
              'priority': int.tryParse(_priority.text.trim()) ?? 0,
              'timeout_ms': int.tryParse(_timeout.text.trim()) ?? 20000,
              'auth_mode': _authMode,
              'token': _authMode == 'api' ? _token.text.trim() : '',
              'cookie': _authMode == 'cookie' ? _cookie.text.trim() : '',
              'user_agent': _ua.text.trim(),
              'option_rate_limit': _rateLimit,
              'option_proxy': _proxy,
              'option_browser_emulation': _browser,
            });
            if (!context.mounted) return;
            if (err == null) {
              Navigator.pop(context);
            } else {
              // 失败必须说话：以前服务端 400 时只有控制台一行红字
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(err)),
              );
            }
          },
          child: Text('discover_save'.tr),
        ),
      ],
    );
  }
}

class _SetTokenDialog extends StatelessWidget {
  const _SetTokenDialog(this.c, this.site);

  final DiscoverController c;
  final Map<String, dynamic> site;

  @override
  Widget build(BuildContext context) {
    final token = TextEditingController();
    return AlertDialog(
      title: Text('discover_site_token'.tr),
      content: TextField(
        controller: token,
        obscureText: true,
        decoration: InputDecoration(hintText: 'discover_site_token_hint'.tr),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
        FilledButton(
          onPressed: () async {
            final id = site['id'];
            if (id is int) await c.saveSiteToken(id: id, token: token.text.trim());
            if (context.mounted) Navigator.pop(context);
          },
          child: Text('discover_save'.tr),
        ),
      ],
    );
  }
}

// ==================== RSS ====================
class _RssTab extends StatefulWidget {
  const _RssTab(this.c);

  final DiscoverController c;

  @override
  State<_RssTab> createState() => _RssTabState();
}

class _RssTabState extends State<_RssTab> {
  DiscoverController get c => widget.c;

  @override
  void initState() {
    super.initState();
    // 同上：侧栏直接渲染组件，不经过 setTab()，这里自己拉数据。
    unawaited(c.loadFeeds());
    unawaited(c.loadLedger());
    // 下载设置：RSS 源不填目录时用它，界面上也要把「默认下载目录」显示出来
    unawaited(c.loadFilter());
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(child: Text('discover_rss_feeds'.tr,
                style: Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(
              onPressed: () async {
                await c.loadFeeds();
                if (context.mounted) {
                  await showDialog<void>(context: context, builder: (_) => _AddFeedDialog(c));
                }
              },
              icon: const Icon(Icons.add),
              label: Text('discover_add'.tr),
            ),
            TextButton.icon(
              onPressed: () async {
                await c.loadFeeds();
              },
              icon: const Icon(Icons.refresh),
              label: Text('discover_refresh'.tr),
            ),
          ],
        ),
        Obx(() => Column(
              children: c.feeds
                  .map((f) {
                        final own = (f['save_path'] ?? '').toString();
                        final fallback =
                            (c.downloadFilter['movie_save_path'] ?? '').toString();
                        final dir = own.isNotEmpty ? own : fallback;
                        final auto = f['auto_download'] == 1 || f['auto_download'] == true;
                        final immediate = f['immediate'] == 1 || f['immediate'] == true;
                        final fid = f['id'] is int ? f['id'] as int : null;
                        return Card(
                          child: Column(
                            children: [
                              ListTile(
                                title: Text((f['name'] ?? '') as String),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '${f['url_masked'] ?? ''} · ${f['last_fetch_status'] ?? '-'}'),
                                    Text(
                                      dir.isEmpty
                                          ? 'discover_rss_no_dir'.tr
                                          : '${'discover_rss_dir'.tr}：$dir',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ],
                                ),
                                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                  IconButton(
                                    icon: const Icon(Icons.refresh),
                                    tooltip: 'discover_rss_refresh_one'.tr,
                                    onPressed: () async {
                                      if (fid != null) await c.refreshFeed(fid);
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () async {
                                      if (fid != null) await c.deleteFeed(fid);
                                    },
                                  ),
                                ]),
                              ),
                              // 两个开关都是「改完立刻生效」：立刻开始还会把该源
                              // 已在下载器里、还没下完的种子一起 start / stop。
                              Row(
                                children: [
                                  Expanded(
                                    child: SwitchListTile(
                                      dense: true,
                                      visualDensity: VisualDensity.compact,
                                      contentPadding: const EdgeInsets.only(left: 12),
                                      title: Text('discover_rss_auto_download'.tr,
                                          style: const TextStyle(fontSize: 13)),
                                      subtitle: Text('discover_rss_auto_hint'.tr,
                                          style: const TextStyle(fontSize: 11)),
                                      value: auto,
                                      onChanged: fid == null
                                          ? null
                                          : (v) async {
                                              final n = await c.setFeedSettings(fid,
                                                  autoDownload: v);
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                    content: Text(n > 0
                                                        ? 'discover_feed_submitted'.tr
                                                            .replaceAll('{n}', '$n')
                                                        : 'discover_saved'.tr)),
                                              );
                                            },
                                    ),
                                  ),
                                  Expanded(
                                    child: SwitchListTile(
                                      dense: true,
                                      visualDensity: VisualDensity.compact,
                                      contentPadding: const EdgeInsets.only(right: 8),
                                      title: Text('discover_rss_immediate_short'.tr,
                                          style: const TextStyle(fontSize: 13)),
                                      subtitle: Text('discover_rss_immediate_short_hint'.tr,
                                          style: const TextStyle(fontSize: 11)),
                                      value: immediate,
                                      onChanged: fid == null
                                          ? null
                                          : (v) async {
                                              final n = await c.setFeedSettings(fid,
                                                  immediate: v);
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                    content: Text(n > 0
                                                        ? 'discover_feed_applied'.tr
                                                            .replaceAll('{n}', '$n')
                                                        : 'discover_saved'.tr)),
                                              );
                                            },
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      })
                  .toList(),
            )),
        const SizedBox(height: 16),
        // ===== 下载台账（永久记录：只要下过一次就不再重复下载）=====
        Row(
          children: [
            Expanded(
                child: Text('discover_ledger_title'.tr,
                    style: Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(
              onPressed: () => c.loadLedger(),
              icon: const Icon(Icons.refresh),
              label: Text('discover_refresh'.tr),
            ),
            TextButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    title: Text('discover_ledger_clear'.tr),
                    content: Text('discover_ledger_clear_confirm'.tr),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dctx, false),
                          child: Text('cancel'.tr)),
                      FilledButton(
                          onPressed: () => Navigator.pop(dctx, true),
                          child: Text('discover_ledger_clear_ok'.tr)),
                    ],
                  ),
                );
                if (ok == true) await c.clearLedger();
              },
              icon: const Icon(Icons.delete_sweep_outlined),
              label: Text('discover_ledger_clear'.tr),
            ),
          ],
        ),
        Obx(() {
          if (c.ledger.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('discover_ledger_empty'.tr,
                  style: Theme.of(context).textTheme.bodySmall),
            );
          }
          return Column(
            children: c.ledger.map((l) {
              final id = l['id'];
              final t = (l['create_time'] ?? '').toString().replaceAll('T', ' ');
              final hash = (l['info_hash'] ?? '').toString();
              return Card(
                child: ListTile(
                  dense: true,
                  title: Text((l['title'] ?? '') as String,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${_fmtSize(l['size_bytes'])} · #${l['download_task_id'] ?? '-'} · ${t.length > 16 ? t.substring(0, 16) : t}',
                          style: const TextStyle(fontSize: 11)),
                      if (hash.isNotEmpty)
                        Text(hash,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10)),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'discover_ledger_delete'.tr,
                    onPressed: () async {
                      if (id is int) await c.deleteLedgerItem(id);
                    },
                  ),
                ),
              );
            }).toList(),
          );
        }),
      ],
    );
  }
}

class _AddFeedDialog extends StatefulWidget {
  const _AddFeedDialog(this.c);

  final DiscoverController c;

  @override
  State<_AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends State<_AddFeedDialog> {
  final _url = TextEditingController();
  final _name = TextEditingController();

  /// 该源专属下载目录；空 = 用「下载设置」里的默认目录
  String _savePath = '';

  /// 立即下载：关掉时只把种子挂到下载器上，任务保持暂停
  bool _immediate = true;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('discover_rss_add_feed'.tr),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
              controller: _url,
              decoration: InputDecoration(labelText: 'discover_rss_url'.tr)),
          TextField(
              controller: _name,
              decoration: InputDecoration(labelText: 'discover_site_name'.tr)),
          const SizedBox(height: 10),
          // 下载目录：选而不是填（服务端绝对路径，正好也是 transmission 的 download-dir）
          InputDecorator(
            decoration: InputDecoration(
              labelText: 'discover_rss_save_path'.tr,
              helperText: widget.c.downloadFilter['movie_save_path'] == null ||
                      (widget.c.downloadFilter['movie_save_path'] ?? '').toString().isEmpty
                  ? 'discover_rss_save_path_hint'.tr
                  : '${'discover_rss_default_dir'.tr}：'
                      '${widget.c.downloadFilter['movie_save_path']}',
              isDense: true,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _savePath.isEmpty ? 'discover_rss_default_dir'.tr : _savePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: _savePath.isEmpty
                          ? Theme.of(context).textTheme.bodySmall?.color
                          : null,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final picked = await showFolderPicker(context);
                    if (picked == null || !context.mounted) return;
                    setState(() => _savePath = picked);
                  },
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: Text('discover_rss_pick_dir'.tr),
                ),
              ],
            ),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('discover_rss_immediate'.tr),
            subtitle: Text('discover_rss_immediate_hint'.tr,
                style: const TextStyle(fontSize: 11)),
            value: _immediate,
            onChanged: (v) => setState(() => _immediate = v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
        FilledButton(
          onPressed: () async {
            final ok = await widget.c.addFeed(
              url: _url.text.trim(),
              name: _name.text.trim(),
              savePath: _savePath,
              immediate: _immediate,
            );
            if (ok && context.mounted) Navigator.pop(context);
          },
          child: Text('discover_save'.tr),
        ),
      ],
    );
  }
}

// ==================== 任务 ====================
class _TasksTab extends StatefulWidget {
  const _TasksTab(this.c);

  final DiscoverController c;

  @override
  State<_TasksTab> createState() => _TasksTabState();
}

class _TasksTabState extends State<_TasksTab> {
  DiscoverController get c => widget.c;

  @override
  void initState() {
    super.initState();
    // 收藏可能是在别的页点的，切到「任务」时重新拉一次，
    // 否则待下载列表一直停在进入应用那一刻的快照。
    unawaited(c.loadFavorites());
    // 下载任务同理：改走二级侧栏后 `setTab()` 不再被调用（侧栏是直接
    // `discoverTabContent(key)` 渲染组件的），不在这里拉一次就永远是
    // 「暂无下载任务」—— 明明下载器里正在下。（2026-11-10 反馈）
    unawaited(c.loadTasks());
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            // 这里只留「下载中」（待下载 / 已下载在下面两段）；
            // 完整任务（速度/分享率/做种）在左侧「下载器」栏里看
            Expanded(child: Text('transmission.downloading'.tr,
                style: Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(
              onPressed: () async {
                await c.loadTasks();
                await c.syncTasks();
              },
              icon: const Icon(Icons.sync),
              label: Text('discover_refresh'.tr),
            ),
          ],
        ),
        Obx(() {
          // 只显示「还在下载链路里」的任务：下完归位到「已下载」，
          // 删掉的（removed）/ 取消的（proposed 未提交）不再占位。
          // 以前按 `!= 'Completed'` 排除，一是大小写对不上（服务端是小写 completed），
          // 二是反了：删掉的记录（removed）反而一直留着，看起来像删不掉。
          const alive = {'added', 'downloading', 'paused', 'failed', 'proposed'};
          final active = c.tasks
              .where((t) => alive.contains((t['status'] ?? '').toString().toLowerCase()))
              .toList();
          if (active.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('discover_tasks_empty'.tr,
                  style: Theme.of(context).textTheme.bodySmall),
            );
          }
          // 与「待下载」一致的一行两列；显示影片图片 / 名字 / 年份 · 类型
          // （后端已按 candidate_id 补 title / media_type / poster_path / release_date）
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 120,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: active.length,
            itemBuilder: (_, i) {
              final t = active[i];
              final id = t['id'];
              final f = <String, dynamic>{
                ...t,
                if ((t['title'] ?? '').toString().isEmpty)
                  'title': (t['candidate_title'] ?? t['torrent_name'] ?? '').toString(),
              };
              return _FavItemCard(
                f: f,
                statusText: _taskStatusText(t['status']),
                action: PopupMenuButton<String>(
                  tooltip: 'discover_task_action'.tr,
                  padding: EdgeInsets.zero,
                  onSelected: (v) async {
                    if (id is! int) return;
                    if (v == 'delete') {
                      await _confirmDeleteTask(context, c, id);
                    } else {
                      await c.taskAction(id, v);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'pause', child: Text('discover_task_pause'.tr)),
                    PopupMenuItem(value: 'resume', child: Text('discover_task_resume'.tr)),
                    PopupMenuItem(value: 'retry', child: Text('discover_task_retry'.tr)),
                    PopupMenuItem(value: 'delete', child: Text('discover_task_delete'.tr)),
                  ],
                ),
              );
            },
          );
        }),
        const SizedBox(height: 16),
        Text('discover_fav_waiting'.tr, style: Theme.of(context).textTheme.titleMedium),
        Obx(() => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.favWatching.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('discover_fav_empty'.tr,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                // 和发现页同一套海报卡（紧凑版）：一行多列、点开影片详情就能搜种下载
                if (c.favWatching.isNotEmpty)
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      // 比发现页的 170 小一档：一行能多放几张，列表更紧凑
                      maxCrossAxisExtent: 124,
                      childAspectRatio: 0.66,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: c.favWatching.length,
                    itemBuilder: (_, i) {
                      final f = c.favWatching[i];
                      final mediaId = f['id'] is int ? f['id'] as int : null;
                      final item = <String, dynamic>{...f, 'favorited': true};
                      return _BrowseCard(
                        compact: true,
                        item: item,
                        onTap: () => _showMediaDetail(context, c, item),
                        onToggleFav: () async {
                          if (mediaId != null) await c.unFavorite(mediaId);
                        },
                        // 右键：订阅 / 搜 PT（待下载里最常用的两个动作）
                        subscribed: mediaId != null && c.isSubscribed(mediaId),
                        onSubscribe: mediaId == null
                            ? null
                            : () {
                                final subId = c.subscriptionIdOf(mediaId);
                                if (subId != null) {
                                  c.unsubscribe(subId);
                                } else {
                                  c.subscribe(mediaId);
                                }
                              },
                        onSearch: mediaId == null
                            ? null
                            : () => _showPtResults(context, c, mediaId: mediaId),
                      );
                    },
                  ),
              ],
            )),
        const SizedBox(height: 16),
        Text('discover_fav_downloaded'.tr, style: Theme.of(context).textTheme.titleMedium),
        Obx(() => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.favDownloaded.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('discover_fav_empty'.tr,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                // 一行两列（按需求）
                if (c.favDownloaded.isNotEmpty)
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisExtent: 104,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: c.favDownloaded.length,
                    itemBuilder: (_, i) => _FavItemCard(
                      f: c.favDownloaded[i],
                      showDownloadInfo: true,
                    ),
                  ),
              ],
            )),
      ],
    );
  }
}

// ==================== 设置（TMDB 凭据 + 下载筛选） ====================

/// 动画音频可选语言（含「台配 / 粤语」这类同义写法对应的代码）
const List<Map<String, String>> kDiscoverAudioOptions = [
  {'code': 'zh', 'label': 'discover_lang_zh'},
  {'code': 'zh_tw', 'label': 'discover_audio_zh_tw'},
  {'code': 'yue', 'label': 'discover_audio_yue'},
  {'code': 'ja', 'label': 'discover_lang_ja'},
  {'code': 'ko', 'label': 'discover_lang_ko'},
  {'code': 'en', 'label': 'discover_lang_en'},
];

class _SettingsTab extends StatefulWidget {
  const _SettingsTab(this.c);

  final DiscoverController c;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  DiscoverController get c => widget.c;

  final _token = TextEditingController();
  final _apiUrl = TextEditingController();
  final _language = TextEditingController();
  /// 豆瓣 Cookie（可选，降低限流）
  final _doubanCookie = TextEditingController();
  // 原「择种规则」并入「下载筛选」后的三项
  final _maxSizeGb = TextEditingController();
  final _minSeeders = TextEditingController();
  final _excludedKw = TextEditingController();

  /// TMDB 连通性测试结果（空 = 未测试）
  String _testResult = '';
  bool _testing = false;
  // 豆瓣测试结果分两行：网站连通（首行）/ Cookie 登录态（次行）
  String _doubanSiteText = '';
  String _doubanCookieText = '';
  bool _doubanSiteOk = false;
  bool _doubanCookieOk = false;
  bool _doubanCookieNone = false;
  bool _doubanTesting = false;
  /// 缓存占用文案（图片 MB + 评分条数）
  String _cacheText = '';
  bool _autoDownload = false;
  double _interval = 60;
  String _quality = 'all';
  String _hdr = 'all';
  /// 评分体系：tmdb（默认）/ douban
  String _ratingProvider = 'tmdb';
  /// 下载保存目录（取自影视库源目录）
  String _moviePath = '';
  String _tvPath = '';
  final Set<String> _audio = <String>{};
  final Set<int> _siteIds = <int>{};
  bool _loaded = false;
  /// 「立即扫描」进行中：按钮置灰 + 转圈，扫完弹出「扫了几条 / 新增几条」
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _token.dispose();
    _apiUrl.dispose();
    _language.dispose();
    _doubanCookie.dispose();
    _maxSizeGb.dispose();
    _minSeeders.dispose();
    _excludedKw.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await c.loadDiscoverSettings();
    await c.loadFilter();
    await c.loadSites();
    final s = c.discoverSettings;
    _token.text = (s['token'] ?? '') as String; // 明文回显（按需求）
    _apiUrl.text = (s['api_url'] ?? '') as String;
    _language.text = (s['language'] ?? '') as String;
    _ratingProvider = (s['rating_provider'] ?? 'tmdb').toString();
    _doubanCookie.text = (s['douban_cookie'] ?? '').toString();
    // 下载目录下拉的数据源（影视库源目录，来自 /api/video/source/list）
    await c.loadVideoSources();
    final f = c.downloadFilter;
    _moviePath = (f['movie_save_path'] ?? '').toString();
    _tvPath = (f['tv_save_path'] ?? '').toString();
    // 没配过就用该类型（含 mixed）的第一个源目录做默认
    if (_moviePath.isEmpty) _moviePath = _defaultPathFor(true);
    if (_tvPath.isEmpty) _tvPath = _defaultPathFor(false);
    _autoDownload = f['auto_download'] == true;
    _interval = ((f['scan_interval_minutes'] as num?)?.toDouble()) ?? 60;
    _quality = (f['quality'] ?? 'all').toString();
    _hdr = (f['hdr'] ?? 'all').toString();
    // 原择种规则并入的三项
    final maxBytes = (f['max_size_bytes'] as num?)?.toDouble() ?? 0;
    _maxSizeGb.text = maxBytes > 0 ? (maxBytes / 1024 / 1024 / 1024).toStringAsFixed(1) : '';
    _minSeeders.text = '${(f['min_seeders'] as num?)?.toInt() ?? 0}';
    _excludedKw.text = ((f['excluded_keywords'] as List?) ?? []).join(', ');
    _audio
      ..clear()
      ..addAll(((f['audio_langs'] as List?) ?? []).map((e) => e.toString()));
    // compat 层已把服务端的文本站点 id 映射成与 c.sites 一致的 int id；
    // 这里直接吃 int，纯数字字符串也兼容（旧数据/直连接口时不会把勾选丢掉）。
    _siteIds
      ..clear()
      ..addAll(((f['site_ids'] as List?) ?? [])
          .map((e) => e is int ? e : (int.tryParse(e.toString()) ?? 0))
          .where((e) => e > 0));
    _loadCacheStats();
    if (mounted) setState(() => _loaded = true);
  }

  /// TMDB 连通性测试：直接把耗时和实际使用的代理显示出来，省得再猜「走没走代理」
  Future<void> _runTest() async {
    setState(() {
      _testing = true;
      _testResult = '';
    });
    final r = await c.testDiscoverSettings();
    if (!mounted) return;
    final ok = r != null && r['ok'] == true;
    final ms = r == null ? '' : '${r['elapsed_ms'] ?? ''} ms';
    final proxy = r == null ? '' : (r['proxy_url'] ?? '').toString();
    setState(() {
      _testing = false;
      _testResult = ok
          ? '${'discover_settings_token_test_ok'.tr} · $ms${proxy.isEmpty ? '' : ' · $proxy'}'
          : '${'discover_settings_token_test_fail'.tr} · ${r == null ? '-' : (r['code'] ?? '')}';
    });
  }

  /// 缓存占用：图片落盘 MB/张数 + 评分缓存条数（豆瓣 / TMDB）
  Future<void> _loadCacheStats() async {
    final r = await c.getDiscoverCacheStats();
    if (r == null) return;
    final images = (r['images'] as Map?) ?? <String, dynamic>{};
    final tmdbImg = (images['tmdb'] as Map?) ?? <String, dynamic>{};
    final doubanImg = (images['douban'] as Map?) ?? <String, dynamic>{};
    final ratings = (r['ratings'] as Map?) ?? <String, dynamic>{};
    final bytes = ((tmdbImg['bytes'] as num?) ?? 0) + ((doubanImg['bytes'] as num?) ?? 0);
    final files = ((tmdbImg['files'] as num?) ?? 0) + ((doubanImg['files'] as num?) ?? 0);
    final txt = '${'discover_cache_usage'.tr}: ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB ($files) · '
        '${'discover_rating_douban'.tr} ${(ratings['douban'] as num?)?.toInt() ?? 0} / TMDB ${(ratings['tmdb'] as num?)?.toInt() ?? 0}';
    if (mounted) setState(() => _cacheText = txt);
  }

  /// 豆瓣体检：一次点击出**两行结果** —— ①网站连通 ②Cookie 登录态
  /// 传输入框里**现填的** cookie，未保存也能直接测。
  Future<void> _runDoubanTest() async {
    setState(() {
      _doubanTesting = true;
      _doubanSiteText = '';
      _doubanCookieText = '';
    });
    final r = await c.testDouban(cookie: _doubanCookie.text.trim());
    if (!mounted) return;

    final site = (r == null ? null : r['site']) as Map?;
    final ck = (r == null ? null : r['cookie']) as Map?;
    final tmdb = (r == null ? null : r['tmdb_match']) as Map?;
    final sample = (r == null ? null : r['sample']) as Map?;

    // ① 网站
    final siteOk = site != null && site['ok'] == true;
    final siteMs = site == null ? '-' : '${site['elapsed_ms'] ?? '-'} ms';
    final siteCode = site == null ? '-' : (site['code'] ?? '').toString();
    var siteTxt =
        '${'discover_douban_site_test'.tr}：${siteOk ? 'discover_douban_test_ok'.tr : 'discover_douban_test_fail'.tr} · $siteMs';
    if (siteOk && sample != null) {
      siteTxt += ' · ${sample['title'] ?? ''}★${sample['rating'] ?? '-'}';
    }
    if (tmdb != null && tmdb['total'] != null) {
      siteTxt += ' · ${'discover_douban_match'.tr} ${tmdb['match_rate'] ?? '-'}%';
    }
    if (!siteOk) siteTxt += ' · $siteCode';

    // ② Cookie
    final provided = ck != null && ck['provided'] == true;
    final valid = ck != null && ck['valid'] == true;
    final user = (ck == null ? '' : (ck['user'] ?? '').toString());
    final ckMs = ck == null ? '-' : '${ck['elapsed_ms'] ?? '-'} ms';
    final ckCode = ck == null ? '-' : (ck['code'] ?? '').toString();
    final String ckTxt;
    if (!provided) {
      ckTxt = '${'discover_douban_cookie_check'.tr}：${'discover_douban_cookie_none'.tr}';
    } else if (valid) {
      ckTxt = '${'discover_douban_cookie_check'.tr}：${'discover_douban_cookie_ok'.tr}'
          '${user.isEmpty ? '' : ' $user'} · $ckMs';
    } else {
      ckTxt = '${'discover_douban_cookie_check'.tr}：${'discover_douban_cookie_fail'.tr} · $ckCode';
    }

    setState(() {
      _doubanTesting = false;
      _doubanSiteOk = siteOk;
      _doubanCookieOk = valid;
      _doubanCookieNone = !provided;
      _doubanSiteText = r == null ? 'discover_douban_test_fail'.tr : siteTxt;
      _doubanCookieText = r == null ? '-' : ckTxt;
    });
  }

  /// 该类型的默认源目录（电影 → 第一个 movie/mixed，电视剧 → 第一个 tv/mixed）
  /// 立即扫描：按钮转圈 → 结果提示（待下载几条 / 新增几条 / 跳过几条）。
  /// 以前点了没有任何反馈，用户以为没生效就反复点，一次扫描就被触发好几遍。
  Future<void> _runScan() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _scanning = true);
    try {
      final r = await c.scanFavorites();
      final scanned = (r?['scanned'] as num?)?.toInt() ?? 0;
      final submitted = (r?['submitted'] as num?)?.toInt() ?? 0;
      final skipped = (r?['skipped'] as num?)?.toInt() ?? 0;
      final text = scanned == 0
          ? 'discover_scan_none'.tr
          : 'discover_scan_result'.tr
              .replaceAll('{scanned}', '$scanned')
              .replaceAll('{submitted}', '$submitted')
              .replaceAll('{skipped}', '$skipped');
      messenger.showSnackBar(SnackBar(content: Text(text)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  String _defaultPathFor(bool isMovie) {
    for (final s in c.videoSources) {
      final mt = (s['media_type'] ?? '').toString();
      if (isMovie ? (mt == 'movie' || mt == 'mixed') : (mt == 'tv' || mt == 'mixed')) {
        return (s['path'] ?? '').toString();
      }
    }
    return '';
  }

  /// 下载目录下拉：列出该类型的影视库源目录（movie/tv 各自带 mixed）
  Widget _dirDropdown(BuildContext context, String labelKey, bool isMovie) {
    final items = c.videoSources.where((s) {
      final mt = (s['media_type'] ?? '').toString();
      return isMovie ? (mt == 'movie' || mt == 'mixed') : (mt == 'tv' || mt == 'mixed');
    }).toList();
    final cur = isMovie ? _moviePath : _tvPath;
    final valid = items.any((s) => (s['path'] ?? '').toString() == cur) ? cur : '';
    return DropdownButtonFormField<String>(
      initialValue: valid,
      isExpanded: true,
      decoration: InputDecoration(labelText: labelKey.tr),
      items: [
        DropdownMenuItem(
            value: '',
            child: Text('discover_download_dir_default'.tr,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
        ...items.map((s) => DropdownMenuItem(
              value: (s['path'] ?? '').toString(),
              child: Text(
                '${s['library_name'] ?? ''} · ${s['path'] ?? ''}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            )),
      ],
      onChanged: (v) => setState(() {
        if (isMovie) {
          _moviePath = v ?? '';
        } else {
          _tvPath = v ?? '';
        }
      }),
    );
  }

  Widget _sectionTitle(String key) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(key.tr, style: Theme.of(context).textTheme.titleMedium),
      );

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _sectionTitle('discover_settings_tmdb'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Obx(() => TextField(
                  controller: _token,
                  decoration: InputDecoration(
                    labelText: 'discover_tmdb_token'.tr,
                    helperText: c.discoverSettings['token_configured'] == true
                        ? 'discover_settings_token_set'.tr
                        : 'discover_settings_token_unset'.tr,
                    helperStyle: TextStyle(
                      fontSize: 12,
                      color: c.discoverSettings['token_configured'] == true
                          ? Colors.green.shade600
                          : Colors.orange.shade700,
                    ),
                  ),
                )),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _runTest,
                      icon: _testing
                          ? const SizedBox(
                              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.network_check, size: 16),
                      label: Text('discover_settings_token_test'.tr),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _testResult,
                        style: TextStyle(
                          fontSize: 12,
                          color: _testResult.isEmpty
                              ? Theme.of(context).disabledColor
                              : (_testResult.startsWith('OK') ? Colors.green.shade600 : Colors.orange.shade700),
                        ),
                      ),
                    ),
                  ],
                ),
                TextField(
                    controller: _apiUrl,
                    decoration: InputDecoration(labelText: 'discover_tmdb_api_url'.tr)),
                // 代理不再单独配置：这里只读回显「系统设置 → 网络代理」实际生效的地址
                Obx(() {
                  final proxy = (c.discoverSettings['proxy_effective'] ?? '').toString();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${'discover_settings_proxy_now'.tr}: ${proxy.isEmpty ? '-' : proxy}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  );
                }),
                TextField(
                    controller: _language,
                    decoration: InputDecoration(labelText: 'discover_tmdb_language'.tr)),
              ],
            ),
          ),
        ),
        // ⭐ 评分体系：TMDB（默认）/ 豆瓣
        _sectionTitle('discover_rating_provider'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  children: [
                    for (final p in const ['tmdb', 'douban'])
                      ChoiceChip(
                        label: Text('discover_rating_$p'.tr, style: const TextStyle(fontSize: 12)),
                        selected: _ratingProvider == p,
                        onSelected: (_) => setState(() => _ratingProvider = p),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('discover_rating_hint'.tr,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _doubanCookie,
                  decoration: InputDecoration(
                    labelText: 'discover_douban_cookie'.tr,
                    helperText: 'discover_douban_cookie_hint'.tr,
                    helperStyle: const TextStyle(fontSize: 11),
                  ),
                ),
                const SizedBox(height: 8),
                // 测试豆瓣连通性：真打一次，回显耗时与命中样例
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _doubanTesting ? null : _runDoubanTest,
                      icon: _doubanTesting
                          ? const SizedBox(
                              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.network_check, size: 16),
                      label: Text('discover_douban_test'.tr),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ① 豆瓣网站连通性
                          Text(
                            _doubanSiteText,
                            style: TextStyle(
                              fontSize: 12,
                              color: _doubanSiteText.isEmpty
                                  ? Theme.of(context).disabledColor
                                  : (_doubanSiteOk
                                      ? Colors.green.shade600
                                      : Colors.orange.shade700),
                            ),
                          ),
                          const SizedBox(height: 2),
                          // ② 你填的 Cookie 是否有效（登录态）
                          Text(
                            _doubanCookieText,
                            style: TextStyle(
                              fontSize: 12,
                              color: (_doubanCookieText.isEmpty || _doubanCookieNone)
                                  ? Theme.of(context).disabledColor
                                  : (_doubanCookieOk
                                      ? Colors.green.shade600
                                      : Colors.orange.shade700),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_cacheText, style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ),
        ),
        _sectionTitle('discover_download_dir'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Obx(() => Row(
                  children: [
                    Expanded(
                        child: _dirDropdown(context, 'discover_download_dir_movie', true)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: _dirDropdown(context, 'discover_download_dir_tv', false)),
                  ],
                )),
          ),
        ),
        _sectionTitle('discover_download_filter'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 参与自动下载的站点
                Text('${'discover_filter_sites'.tr}：'),
                Obx(() => Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      children: c.sites.map((s) {
                        final id = s['id'];
                        final sid = id is int ? id : 0;
                        return FilterChip(
                          label: Text((s['name'] ?? '') as String,
                              style: const TextStyle(fontSize: 12)),
                          selected: _siteIds.contains(sid),
                          onSelected: (_) => setState(() {
                            if (_siteIds.contains(sid)) {
                              _siteIds.remove(sid);
                            } else {
                              _siteIds.add(sid);
                            }
                          }),
                        );
                      }).toList(),
                    )),
                const SizedBox(height: 8),
                // 画质
                Text('${'discover_quality'.tr}：'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final q in const ['all', '1080p', '1440p', '4k'])
                      ChoiceChip(
                        label: Text('discover_quality_$q'.tr, style: const TextStyle(fontSize: 12)),
                        selected: _quality == q,
                        onSelected: (_) => setState(() => _quality = q),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                // HDR
                Text('${'discover_hdr'.tr}：'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final h in const ['all', 'hdr', 'hdr10', 'hdr10plus', 'dolby'])
                      ChoiceChip(
                        label: Text('discover_hdr_$h'.tr, style: const TextStyle(fontSize: 12)),
                        selected: _hdr == h,
                        onSelected: (_) => setState(() => _hdr = h),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                // 动画音频
                Text('${'discover_audio'.tr}：'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final opt in kDiscoverAudioOptions)
                      FilterChip(
                        label: Text(opt['label']!.tr, style: const TextStyle(fontSize: 12)),
                        selected: _audio.contains(opt['code']),
                        onSelected: (_) => setState(() {
                          final code = opt['code']!;
                          if (_audio.contains(code)) {
                            _audio.remove(code);
                          } else {
                            _audio.add(code);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                // ⭐ 原「择种规则」并入这里的三项（画质/HDR/音轨门槛上面已有）
                // 两个输入框必须等高：左边有 helperText、右边没有时，
                // Row 默认居中会把右边整体抬高，看起来就没水平对齐。
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _maxSizeGb,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                            labelText: 'discover_rule_max_size'.tr,
                            helperText: 'discover_rule_max_size_hint'.tr,
                            helperStyle: const TextStyle(fontSize: 11)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _minSeeders,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'discover_rule_min_seeders'.tr,
                          // 占位 helper：与左边等高，输入框才能对齐
                          helperText: ' ',
                          helperStyle: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _excludedKw,
                  decoration: InputDecoration(
                      labelText: 'discover_rule_excluded'.tr,
                      helperText: 'discover_rule_list_hint'.tr,
                      helperStyle: const TextStyle(fontSize: 11)),
                ),
                const SizedBox(height: 8),
                // 扫描间隔 + 自动下载
                Row(
                  children: [
                    Text('${'discover_scan_interval'.tr}：${_interval.round()} ${'discover_minutes'.tr}'),
                    Expanded(
                      child: Slider(
                        value: _interval,
                        min: 5,
                        max: 360,
                        divisions: 71,
                        label: '${_interval.round()}',
                        onChanged: (v) => setState(() => _interval = v),
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('discover_auto_download'.tr),
                  value: _autoDownload,
                  onChanged: (v) => setState(() => _autoDownload = v),
                ),
                Row(
                  children: [
                    FilledButton(
                      onPressed: () async {
                        // 1) TMDB 凭据
                        await c.saveDiscoverSettings({
                          if (_token.text.trim().isNotEmpty) 'token': _token.text.trim(),
                          'api_url': _apiUrl.text.trim(),
                          'language': _language.text.trim(),
                          'rating_provider': _ratingProvider,
                          if (_doubanCookie.text.trim().isNotEmpty)
                            'douban_cookie': _doubanCookie.text.trim(),
                        });
                        // 2) 下载筛选
                        await c.saveFilter({
                          'site_ids': _siteIds.toList(),
                          'quality': _quality,
                          'hdr': _hdr,
                          'audio_langs': _audio.toList(),
                          'movie_save_path': _moviePath,
                          'tv_save_path': _tvPath,
                          'scan_interval_minutes': _interval.round(),
                          'auto_download': _autoDownload,
                          // 原择种规则并入的三项
                          'max_size_bytes': (double.tryParse(_maxSizeGb.text.trim()) ?? 0) <= 0
                              ? 0
                              : ((double.tryParse(_maxSizeGb.text.trim()) ?? 0) * 1024 * 1024 * 1024).round(),
                          'min_seeders': int.tryParse(_minSeeders.text.trim()) ?? 0,
                          'excluded_keywords': _splitList(_excludedKw.text),
                        });
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text('discover_saved'.tr)));
                        }
                      },
                      child: Text('discover_save'.tr),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _scanning ? null : () => _runScan(),
                      icon: _scanning
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search, size: 16),
                      label: Text(_scanning ? 'discover_scanning'.tr : 'discover_scan_now'.tr),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 删除下载任务的三选弹窗：确认删除 / 移到待下载 / 取消
Future<void> _confirmDeleteTask(
    BuildContext context, DiscoverController c, int id) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text('discover_task_delete'.tr),
      content: Text('discover_task_delete_confirm'.tr),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dctx, 'cancel'),
            child: Text('cancel'.tr)),
        TextButton(
            onPressed: () => Navigator.pop(dctx, 'favorite'),
            child: Text('discover_task_to_favorite'.tr)),
        FilledButton(
            onPressed: () => Navigator.pop(dctx, 'delete'),
            child: Text('discover_task_delete_ok'.tr)),
      ],
    ),
  );
  if (choice == 'delete') {
    await c.deleteTask(id, toFavorite: false);
  } else if (choice == 'favorite') {
    await c.deleteTask(id, toFavorite: true);
  }
}

/// 下载任务状态 → 展示文案
String _taskStatusText(dynamic s) {
  switch ((s ?? '').toString().toLowerCase()) {
    case 'downloading':
      return 'discover_status_downloading'.tr;
    case 'added':
    case 'queued':
      return 'discover_status_queued'.tr;
    case 'paused':
      return 'discover_status_paused'.tr;
    case 'completed':
    case 'seeding':
      return 'discover_status_completed'.tr;
    case 'error':
    case 'failed':
      return 'discover_status_error'.tr;
    default:
      return unknownStatusLabel();
  }
}

/// 逗号（中英文）/空格分隔的字符串 → 去空数组
List<String> _splitList(String s) => s
    .split(RegExp(r'[,，\s]+'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

// ==================== 影视详情页（全屏 · 固定布局） ====================
class _MediaDetailPage extends StatefulWidget {
  const _MediaDetailPage({
    required this.c,
    required this.mediaType,
    required this.mediaId,
    required this.preview,
  });

  final DiscoverController c;
  final String mediaType;
  final dynamic mediaId;
  final Map<String, dynamic> preview;

  @override
  State<_MediaDetailPage> createState() => _MediaDetailPageState();
}

class _MediaDetailPageState extends State<_MediaDetailPage> {
  Map<String, dynamic>? _detail;
  bool _loading = true;
  int _seasonIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 收藏状态依赖收藏列表，先拉一次，保证星标/已拥有判定准确
    widget.c.loadFavorites();
    final d = await widget.c.findDetail(widget.mediaType, widget.mediaId);
    if (!mounted) return;
    setState(() {
      _detail = d ?? widget.preview;
      _loading = false;
    });
  }

  Map<String, dynamic> get _d => _detail ?? widget.preview;
  bool get _isTv => widget.mediaType == 'tv';

  String get _title => (_d['title'] ?? '') as String;
  String get _poster => _posterOf(_d, size: 'w780');
  /// 详情页右侧「完整封面」用的中等尺寸（contain 展示，省流量也少占缓存）
  String get _posterSmall => _posterOf(_d, size: 'w500');

  String get _yearText {
    final rd = (_d['release_date'] ?? '').toString();
    return rd.isEmpty ? '' : rd.split('-').first;
  }

  double? get _vote {
    final v = _d['vote_average'];
    return v is num ? v.toDouble() : null;
  }

  String get _runtimeText {
    if (_isTv) {
      final seasons = (_d['number_of_seasons'] as num?)?.toInt() ?? 0;
      final eps = (_d['number_of_episodes'] as num?)?.toInt() ?? 0;
      if (seasons <= 0 && eps <= 0) return '';
      return '$seasons${'discover_detail_seasons'.tr} · $eps${'discover_detail_episodes'.tr}';
    }
    final rt = (_d['runtime'] as num?)?.toInt() ?? 0;
    return rt > 0 ? '$rt ${'discover_detail_minutes'.tr}' : '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 36),
              children: [
                _buildHeader(theme),
                _buildActions(theme),
                _buildOverview(theme),
                if (_isTv) _buildSeasons(theme),
                _buildInfo(theme),
                _buildCast(theme),
              ],
            ),
    );
  }

  // 固定 260 高的头图：海报拉伸 + 渐变 + 标题/副标题贴在左下
  Widget _buildHeader(ThemeData theme) {
    final vote = _vote;
    return SizedBox(
      height: 260,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _poster.isEmpty
              ? Container(color: theme.colorScheme.surfaceContainerHighest)
              : Image.network(_poster, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(color: theme.colorScheme.surfaceContainerHighest), headers: compatAuthHeaders,),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: 0.05), Colors.black.withValues(alpha: 0.82)],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 左侧：标题 / 年份 / 评分 / 类型
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                Text(
                  _title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (_yearText.isNotEmpty)
                      Text(_yearText,
                          style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    if (_runtimeText.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Text(_runtimeText,
                          style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    ],
                    if (vote != null && vote > 0) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: _ratingColor(vote), borderRadius: BorderRadius.circular(4)),
                        child: Text('★ ${vote.toStringAsFixed(1)}',
                            style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: ((_d['genres'] as List?) ?? [])
                      .map((g) => Text((g ?? '').toString(),
                          style: const TextStyle(color: Colors.white70, fontSize: 12)))
                      .toList(),
                ),
              ],
                  ),
                ),
                const SizedBox(width: 12),
                // ⭐ 右侧：完整封面（BoxFit.contain，不裁切；原先只用封面当背景裁成横幅，看不出全图）
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 104,
                    height: 156,
                    child: _posterSmall.isEmpty
                        ? Container(color: Colors.black26)
                        : Image.network(_posterSmall, fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => Container(color: Colors.black26), headers: compatAuthHeaders,),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: () => _showPtResults(context, widget.c, mediaId: (widget.mediaId is int) ? widget.mediaId as int : null),
            icon: const Icon(Icons.download, size: 16),
            label: Text('discover_search_pt'.tr),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: () async {
              final id = widget.mediaId;
              if (id is int) {
                await widget.c.toggleFavoriteByMediaId(id);
                if (mounted) setState(() {});
              }
            },
            icon: Icon(widget.c.isFavorited(widget.mediaId) ? Icons.star : Icons.star_border,
                size: 16, color: Colors.amber),
            label: Text(widget.c.isFavorited(widget.mediaId)
                ? 'discover_sub_added'.tr
                : 'discover_sub_add'.tr),
          ),
          const Spacer(),
          if (widget.c.isOwned(widget.mediaId))
            Text('discover_owned'.tr, style: TextStyle(color: Colors.green.shade700, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildOverview(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('discover_detail_overview'.tr,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              ((_d['overview'] ?? '') as String).trim().isEmpty ? '-' : (_d['overview'] as String),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
        ),
      );

  Widget _buildSeasons(ThemeData theme) {
    final seasons = ((_d['seasons'] as List?) ?? []).cast<Map<String, dynamic>>();
    if (seasons.isEmpty) return const SizedBox.shrink();
    final idx = _seasonIndex.clamp(0, seasons.length - 1);
    final cur = seasons[idx];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('discover_detail_seasons'.tr,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: seasons.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => Center(
                child: _pill(
                  theme,
                  dense: true,
                  label: (seasons[i]['name'] ?? 'S${seasons[i]['season_number']}').toString(),
                  selected: i == idx,
                  onTap: () => setState(() => _seasonIndex = i),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${(cur['name'] ?? '')} · ${(cur['episode_count'] ?? 0)}${'discover_detail_episodes'.tr}'
            '${(cur['air_date'] ?? '').toString().isEmpty ? '' : ' · ${cur['air_date']}'}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 36,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
          ),
          Expanded(
            child: Text(value,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  Widget _buildInfo(ThemeData theme) {
    final langs = ((_d['original_language'] ?? '') as String).toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('discover_detail_info'.tr,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          _kv(theme, 'discover_release_date'.tr, (_d['release_date'] ?? '').toString()),
          _kv(theme, 'discover_detail_status'.tr,
              tmdbStatusLabel((_d['status'] ?? '').toString())),
          _kv(theme, 'discover_detail_language'.tr, langs),
          _kv(theme, 'discover_detail_country'.tr, ((_d['countries'] as List?) ?? []).join(' / ')),
          _kv(theme, 'discover_detail_network'.tr, ((_d['networks'] as List?) ?? []).join(' / ')),
          _kv(theme, 'discover_detail_company'.tr, ((_d['companies'] as List?) ?? []).join(' / ')),
          _kv(theme, 'discover_detail_creator'.tr, ((_d['created_by'] as List?) ?? []).join(' / ')),
          _buildLinks(theme),
        ],
      ),
    );
  }

  Widget _buildLinks(ThemeData theme) {
    final links = (_d['links'] as Map?) ?? const {};
    final entries = <MapEntry<String, String>>[];
    if ((links['tmdb'] ?? '').toString().isNotEmpty) entries.add(MapEntry('TMDB', links['tmdb'].toString()));
    if ((links['imdb'] ?? '').toString().isNotEmpty) entries.add(MapEntry('IMDb', links['imdb'].toString()));
    if ((links['douban'] ?? '').toString().isNotEmpty) entries.add(MapEntry('豆瓣', links['douban'].toString()));
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        children: entries
            .map((e) => ActionChip(
                  label: Text(e.key, style: const TextStyle(fontSize: 12)),
                  onPressed: () => _openUrl(e.value),
                ))
            .toList(),
      ),
    );
  }

  Widget _buildCast(ThemeData theme) {
    final cast = ((_d['cast'] as List?) ?? []).cast<Map<String, dynamic>>();
    if (cast.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('discover_detail_cast'.tr,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cast.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final p = cast[i];
                final url = _proxiedImage((p['profile_url'] ?? '').toString(), size: 'w185');
                return SizedBox(
                  width: 84,
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: url.isEmpty
                            ? Container(
                                width: 84, height: 84, color: theme.colorScheme.surfaceContainerHighest)
                            : Image.network(url, width: 84, height: 84, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                    width: 84,
                                    height: 84,
                                    color: theme.colorScheme.surfaceContainerHighest), headers: compatAuthHeaders,),
                      ),
                      const SizedBox(height: 4),
                      Text((p['name'] ?? '') as String,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                      Text((p['character'] ?? '') as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: theme.disabledColor)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _openUrl(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// 菜单项 id → 页面（给外层 `AppNavShell` 用）。
///
/// 影视发现以前自己画顶部 5 个胶囊 + `IndexedStack`，手机端没有底部标签、
/// 桌面端也没有二级侧栏，形态和其它 App 不一致。改成由 `AppNavShell` 统管导航后，
/// 这里只负责「按 key 给页面」：
///   - 手机端 → 底部 5 个标签（`apps.json#nav.mobile.tabs`）
///   - 桌面端 → 左侧二级侧栏
///
/// `DiscoverView`（自带胶囊的整页版本）保留不动，作为回退入口。
Widget discoverTabContent(DiscoverController c, String key) {
  return switch (key) {
    'pt' => _PtTab(c),
    'rss' => _RssTab(c),
    'tasks' => _TasksTab(c),
    'settings' => _SettingsTab(c),
    _ => _DiscoverTab(c),
  };
}