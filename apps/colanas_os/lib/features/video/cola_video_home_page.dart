import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/scan_refresh.dart';
import '../../shell/mobile_frame.dart';
import 'video_card.dart';
import 'cola_video_detail_page.dart';
import 'video_image_library_page.dart';
import 'video_item_actions.dart';
import 'video_jp_pages.dart';
import 'video_list_view.dart';
import 'video_media_viewer_page.dart';
import 'video_series_detail_page.dart';
import 'video_series_grid_page.dart';
import 'video_series_widgets.dart';

/// 影视首页：**来源 / 推荐 / 继续观看 / 每库最近添加** 四段式。
///
/// 这是与既有实现 `video_home_page` 对齐的关键改动。旧版把一个搜索框加一整面
/// 无限网格当首页，语义是「查找」；既有实现是「编辑精选」式的浏览页，
/// 看着完全不像，问题就出在这里 —— 不是样式细节，是信息架构不同。
class VideoHomePage extends StatefulWidget {
  const VideoHomePage({super.key, this.embedded = false, this.onNavigate});

  final bool embedded;

  /// 点「来源」卡片时切二级菜单（传 `NavSelection.select`）。
  /// 左栏本来就有每个库的入口，桌面再推一整页等于重复造一个入口、还盖住左栏。
  final void Function(String key)? onNavigate;

  @override
  State<VideoHomePage> createState() => _VideoHomePageState();
}

class _VideoHomePageState extends State<VideoHomePage> {
  bool _loading = true;
  String? _error;
  VideoHomeResponse? _home;
  VideoStatsResponse? _stats;
  late final void Function() _unsub;

  /// 手机端底部浮动胶囊：0 = 主页，1..n = 各影视库（既有实现就是这么切库的）
  int _libIndex = 0;

  /// 库内容按需建、建完保活（切回主页再切回来不重新拉一页）
  final Map<int, Widget> _libViews = {};

  /// 胶囊里的库 = **全部**库（含没勾「首页显示」的）。
  /// 「首页显示」只决定它出不出现在主页推荐区，不该让它从导航里消失
  /// ——2026-11-04 用户要求：取消勾选后仍要在浮动胶囊里能点到。
  List<VideoLibraryItem> _libs = const [];

  @override
  void initState() {
    super.initState();
    // 扫描完成后自动刷新首页（和列表页共用同一个刷新信号）
    _unsub = listenScanDone('video', _load);
    _load();
  }

  @override
  void dispose() {
    _unsub();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = ApiSession.instance.client;
      final home = await c.videoHome();
      VideoStatsResponse? stats;
      try {
        stats = await c.videoStats();
      } catch (_) {
        // 统计失败不影响首页
      }
      // 全部库（不受「首页显示」开关影响），只用来做底部胶囊
      var libs = const <VideoLibraryItem>[];
      try {
        libs = (await c.videoLibraryList()).items;
      } catch (_) {
        // 库列表失败就退回首页给的来源，至少还能切
      }
      if (!mounted) return;
      setState(() {
        _home = home;
        _stats = stats;
        _libs = libs.isNotEmpty
            ? libs
            : [
                for (final s in home.sources)
                  VideoLibraryItem(
                    id: s.id,
                    name: s.name,
                    path: '',
                    items: s.items,
                    createdAt: 0,
                    lastScanAt: null,
                    libType: s.libType,
                  ),
              ];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _openItem(VideoItem item) {
    if (item.mediaType == 'image') {
      openMediaViewer(context, items: [item], initialIndex: 0);
      return;
    }
    openVideoDetail(context, item);
  }

  void _openAt(List<VideoItem> items, int index) {
    final item = items[index];
    if (item.mediaType == 'image') {
      openMediaViewer(context, items: items, initialIndex: index);
      return;
    }
    _openItem(item);
  }

  void _openLibrary(String id, String name, String libType) {
    // 有外壳就切菜单项，让左栏高亮跟着走（点完还能看到自己站在哪个库）
    final onNavigate = widget.onNavigate;
    if (onNavigate != null) {
      onNavigate('lib:$id');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => libType == 'jp_movie'
            // 日本库：先进演员列表（页内可切「影片」）
            ? VideoJpActorPage(embedded: false, libraryId: id)
            // 电视剧库：一剧一卡，点进去再看季 / 集
            : libType == 'tv' || libType == 'short_tv'
            ? VideoSeriesGridPage(libraryId: id)
            : libType == 'image' || libType == 'mixed'
            ? VideoImageLibraryPage(
                libraryId: id,
                libType: libType,
                title: name,
              )
            : VideoListView(libraryId: id, title: name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _load);
    }
    final home = _home;
    // 注意用 _libs 判空而不是 home.sources：库全部取消「首页显示」时，
    // 首页推荐区是空的，但库本身还在，胶囊必须照样给出来。
    final empty =
        home == null ||
        (home.recommend.isEmpty &&
            home.recentPlay.isEmpty &&
            home.recentAdd.isEmpty &&
            home.sources.isEmpty &&
            _libs.isEmpty);
    if (empty) {
      final emptyView = ListView(
        children: [
          NasEmptyState(
            title: tr('video.home.empty'),
            message: tr('video.home.emptyHint'),
            icon: Icons.movie_outlined,
          ),
        ],
      );
      return isCompactWidth(context) && _libs.isNotEmpty
          ? _withLibChips(emptyView)
          : emptyView;
    }

    final homeBody = RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: NasTokens.spaceLg),
        children: [
          if (_stats != null && _stats!.items > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                NasTokens.spaceMd,
                NasTokens.spaceMd,
                0,
              ),
              child: Text(
                tr('video.stats', {
                  'count': '${_stats!.items}',
                  'duration': formatDurationMs(_stats!.durationMs),
                }),
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
            ),
          if (home.sources.isNotEmpty) _sourcesSection(context, home.sources),
          if (home.recommend.isNotEmpty) _recommendSection(context, home.recommend),
          if (home.recentPlay.isNotEmpty) _recentPlaySection(context, home, home.progress),
          for (final row in home.recentAdd)
            if (row.items.isNotEmpty) _libraryRowSection(context, row),
        ],
      ),
    );

    // 桌面端保持原样：库入口就是「来源」卡片，点进整页。
    // 手机端才用底部浮动胶囊切库（主页 + 各库），与既有实现一致 ——
    // 手机上「点卡片 → 推整页 → 返回」来回两次，切库成本比桌面高得多。
    if (!isCompactWidth(context) || _libs.isEmpty) return homeBody;
    return _withLibChips(homeBody);
  }

  /// 手机端外壳：内容 + 底部库切换胶囊
  Widget _withLibChips(Widget homeBody) {
    final labels = [
      tr('video.home.main'),
      for (final l in _libs) l.name,
    ];
    final index = _libIndex.clamp(0, labels.length - 1);
    _libViews.putIfAbsent(index, () => _libView(index));
    return Stack(
      children: [
        Positioned.fill(
          // 底部留出胶囊高度：最后一行海报不被浮动条压住
          child: Padding(
            padding: const EdgeInsets.only(bottom: 56),
            child: IndexedStack(
              index: index,
              children: [
                // 主页内容每次重建（数据在本 State 里，缓存 widget 实例会冻结数据）；
                // 库视图自己拉数据，缓存实例即可保活滚动位置
                homeBody,
                for (var i = 1; i < labels.length; i++)
                  _libViews[i] ?? const SizedBox.shrink(),
              ],
            ),
          ),
        ),
        Positioned(
          left: NasTokens.spaceMd,
          right: NasTokens.spaceMd,
          bottom: 8,
          child: NasFloatingChips(
            scrollable: true,
            labels: labels,
            selectedIndex: index,
            onSelect: _selectLib,
          ),
        ),
      ],
    );
  }

  void _selectLib(int index) {
    if (index == _libIndex) return;
    setState(() {
      _libIndex = index;
      _libViews.putIfAbsent(index, () => _libView(index));
    });
  }

  Widget _libView(int index) {
    if (index <= 0) return const SizedBox.shrink();
    final lib = _libs[index - 1];
    // 日本库的入口是**演员网格**（既有实现同款：先进角色列表，右上角再切「影片」），
    // 不能像普通库那样直接甩一个影片列表 —— 2026-11-04 用户反馈。
    if (lib.libType == 'jp_movie') {
      return VideoJpActorPage(embedded: true, libraryId: lib.id);
    }
    // 电视剧库：**一部剧一张卡**。逐集铺卡等于把 40 集摊成 40 张同样的海报，
    // 用户看到的是「所有剧集」而不是「剧」—— 桌面外壳早就这么分了，手机端漏了。
    if (lib.libType == 'tv' || lib.libType == 'short_tv') {
      return VideoSeriesGridPage(
        key: ValueKey('video-tv-${lib.id}'),
        libraryId: lib.id,
        embedded: true,
      );
    }
    return lib.libType == 'image' || lib.libType == 'mixed'
        ? VideoImageLibraryPage(
            libraryId: lib.id,
            libType: lib.libType,
            title: lib.name,
            embedded: true,
          )
        : VideoListView(
            libraryId: lib.id,
            title: lib.name,
            embedded: true,
          );
  }

  Widget _sectionHeader(BuildContext context, String title, {VoidCallback? onMore}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: NasTokens.fontSubtitle, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          if (onMore != null)
            TextButton(onPressed: onMore, child: Text(tr('video.card.more'))),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 来源

  Widget _sourcesSection(BuildContext context, List<VideoHomeSource> sources) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.nasStyle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(context, tr('video.home.sources')),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: sources.length,
            separatorBuilder: (_, _) => const SizedBox(width: NasTokens.spaceSm),
            itemBuilder: (context, i) {
              final s = sources[i];
              return SizedBox(
                width: 210,
                child: InkWell(
                  borderRadius: BorderRadius.circular(NasTokens.radiusMd),
                  onTap: () => _openLibrary(s.id, s.name, s.libType),
                  child: Container(
                    decoration: BoxDecoration(
                      color: style.panelColor,
                      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
                      border: Border.all(color: style.panelBorderColor),
                    ),
                    padding: const EdgeInsets.all(NasTokens.spaceSm),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                          child: SizedBox(
                            width: 48,
                            height: 72,
                            child: s.coverId == null && (s.coverPath ?? '').isEmpty
                                ? Icon(Icons.movie_outlined, color: context.nasTextSecondary)
                                : NasCoverImage(
                                    url: s.coverPath != null && s.coverPath!.isNotEmpty
                                        ? '${ApiSession.instance.baseUrl}/api/v1/files/thumb?path=${Uri.encodeComponent(s.coverPath!)}&size=240'
                                        : '${ApiSession.instance.baseUrl}/api/v1/video/art?id=${Uri.encodeComponent(s.coverId!)}',
                                    headers: videoArtHeaders,
                                    fallbackText: s.name,
                                    icon: s.libType == 'image' || s.libType == 'mixed'
                                        ? Icons.image_outlined
                                        : Icons.movie_outlined,
                                  ),
                          ),
                        ),
                        const SizedBox(width: NasTokens.spaceSm),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${s.items}',
                                style: TextStyle(
                                  fontSize: NasTokens.fontCaption,
                                  color: context.nasTextSecondary,
                                ),
                              ),
                              if (s.onlineState == 2)
                                Text(
                                  tr('video.source.offline'),
                                  style: TextStyle(fontSize: NasTokens.fontMicro, color: scheme.error),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 首页卡片也用全站统一的影片动作。图片条目不刮削、打开走本页的媒体查看器。
  Future<void> _runItemAction(VideoItem item, String action) async {
    if (action == VideoItemAction.detail) {
      _openItem(item);
      return;
    }
    final changed = await runVideoItemAction(context, action, item);
    if (changed && mounted) await _load();
  }

  Future<void> _showItemActions(VideoItem item) async {
    final action = await showVideoItemActionSheet(
      context,
      item,
      allowScrape: item.mediaType != 'image',
    );
    if (action == null || !mounted) return;
    await _runItemAction(item, action);
  }

  // ---------------------------------------------------------------- 推荐

  Widget _recommendSection(BuildContext context, List<VideoItem> items) {
    final width = MediaQuery.of(context).size.width;
    final cardW = width >= 1200 ? 360.0 : width >= 900 ? 320.0 : 270.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(context, tr('video.home.recommend')),
        SizedBox(
          height: cardW / (16 / 9),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: NasTokens.spaceSm),
            itemBuilder: (context, i) {
              final item = items[i];
              // 服务端按剧聚合后的卡片：标题 / 海报 / 集数都按剧级展示，
              // 点进去是剧详情（不是「封面那一集」的播放页）。
              final info = item.seriesInfo;
              if (info != null) {
                return SizedBox(
                  height: cardW / (16 / 9),
                  child: VideoHeroCard(
                    item: item,
                    width: cardW,
                    // 服务端已按默认语言给出中文剧名；info.name 仍是剧的查询键
                    title: item.title,
                    meta: tr('video.seasonsEpisodes', {
                      'seasons': '${info.seasons}',
                      'episodes': '${info.episodes}',
                    }),
                    artUrl: seriesArtUrl(
                      info.posterId ?? info.coverId,
                      kind: 'fanart',
                      size: (cardW * 2).round(),
                    ),
                    // 与剧库卡片同一套三态角标（未看 / 已看 n/m / 已看完）
                    badge: SeriesWatchBadge(
                      watched: info.watchedEpisodes ?? 0,
                      total: info.episodes,
                    ),
                    onTap: () => openVideoSeries(
                      context,
                      name: info.name,
                      coverId: info.coverId,
                      posterId: info.posterId,
                      libraryId: item.libraryId,
                      headers: videoArtHeaders,
                    ),
                  ),
                );
              }
              return SizedBox(
                height: cardW / (16 / 9),
                child: NasContextMenuRegion(
                  entries: videoItemMenuEntries(
                    item,
                    onAction: (a) => _runItemAction(item, a),
                    allowScrape: item.mediaType != 'image',
                    context: context,
                  ),
                  child: GestureDetector(
                    onLongPress: () => _showItemActions(item),
                    child: VideoHeroCard(
                      item: item,
                      width: cardW,
                      onTap: () => _openItem(item),
                      onMore: () => _showItemActions(item),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 继续观看 / 最近添加

  Widget _recentPlaySection(
    BuildContext context,
    VideoHomeResponse home,
    List<VideoProgress> progress,
  ) {
    final byId = {for (final p in progress) p.itemId: p.percent / 100};
    return _hScroller(
      context,
      title: tr('video.home.continue'),
      items: home.recentPlay,
      progressOf: (it) => byId[it.id],
    );
  }

  Widget _libraryRowSection(BuildContext context, VideoHomeLibraryRow row) {
    final title = '${tr('video.home.recentAdd')} · ${row.libraryName}';
    // 电视剧库：服务端另给一份按剧聚合的卡片（`series`），一部剧一张，
    // 否则这里一排全是同一部剧的不同集（用户 2026-11-11 反馈）。
    final series = row.series;
    if ((row.libType == 'tv' || row.libType == 'short_tv') &&
        series != null &&
        series.isNotEmpty) {
      return _seriesScroller(
        context,
        title: title,
        libraryId: row.libraryId,
        items: series,
      );
    }
    return _hScroller(context, title: title, items: row.items);
  }

  /// 剧集卡片横滑（首页「最近添加 · 电视剧」用）。
  Widget _seriesScroller(
    BuildContext context, {
    required String title,
    required String libraryId,
    required List<VideoSeriesItem> items,
  }) {
    final width = MediaQuery.of(context).size.width;
    final cardW = width < 480 ? 104.0 : width < 900 ? 120.0 : 136.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(context, title),
        SizedBox(
          height: cardW * 1.5 + 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: NasTokens.spaceSm),
            itemBuilder: (context, i) {
              final s = items[i];
              return SeriesPosterCard(
                item: s,
                width: cardW,
                onTap: () => openVideoSeries(
                  context,
                  name: s.name,
                  coverId: s.coverId,
                  posterId: s.posterId,
                  libraryId: libraryId,
                  headers: videoArtHeaders,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _hScroller(
    BuildContext context, {
    required String title,
    required List<VideoItem> items,
    double? Function(VideoItem)? progressOf,
  }) {
    final width = MediaQuery.of(context).size.width;
    final cardW = width < 480 ? 104.0 : width < 900 ? 120.0 : 136.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(context, title),
        SizedBox(
          height: cardW * 1.5 + 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: NasTokens.spaceSm),
            itemBuilder: (context, i) {
              final item = items[i];
              return NasContextMenuRegion(
                entries: videoItemMenuEntries(
                  item,
                  onAction: (a) => _runItemAction(item, a),
                  allowScrape: item.mediaType != 'image',
                  context: context,
                ),
                child: GestureDetector(
                  onLongPress: () => _showItemActions(item),
                  child: VideoPosterCard(
                    item: item,
                    width: cardW,
                    progress: progressOf?.call(item),
                    onTap: () => _openAt(items, i),
                    onMore: () => _showItemActions(item),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
