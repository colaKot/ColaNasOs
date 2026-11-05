import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/scan_refresh.dart';
import '../../core/session.dart';
import '../../shell/app_nav_shell.dart';
import '../../shell/nav_spec_adapter.dart';
import 'video_collections_page.dart';
import 'video_duplicates_page.dart';
import 'video_image_library_page.dart';
import 'video_jp_pages.dart';
import 'video_media_browser_page.dart';
import 'video_page.dart';
import 'video_app_settings_page.dart';
import 'video_client_settings_page.dart';
import 'video_settings_pages.dart';
import 'video_smart_albums_page.dart';

/// 影视主页：左侧二级导航 + 内容区。
///
/// 导航结构照上游口径：
///   影视库（首页 / 每个有内容的库 / 播放历史 / 收藏 / 日本榜单 / 日本演员 / 剧集浏览）
///   设置（影视库管理）
/// 库是共享实体（不是每用户一份），左栏按「选中库 → 列表过滤」而不是每用户筛。
class VideoShellPage extends StatefulWidget {
  const VideoShellPage({super.key});

  @override
  State<VideoShellPage> createState() => _VideoShellPageState();
}

class _VideoShellPageState extends State<VideoShellPage> {
  List<VideoLibraryItem> _libraries = const [];

  /// SMB 状态翻转时 +1，让当前页按新 key 重建（内容随离线过滤重新拉一次）
  int _epoch = 0;
  void Function()? _offSmb;

  @override
  void initState() {
    super.initState();
    _loadLibraries();
    // SMB 库离线时服务端把内容过滤掉，探到在线后要自己「长出来」。
    // 只订阅翻转事件（服务端每 20s 心跳，但只在状态变化时发），不做定时刷新。
    _offSmb = listenSmbOnline(() {
      if (!mounted) return;
      _loadLibraries();
      setState(() => _epoch++);
    });
  }

  @override
  void dispose() {
    _offSmb?.call();
    super.dispose();
  }

  Future<void> _loadLibraries() async {
    try {
      final res = await ApiSession.instance.client.videoLibraryList();
      if (!mounted) return;
      setState(() => _libraries = res.items);
    } catch (_) {
      // 库列表读不到：菜单里就少几个库入口，不影响其它板块
    }
  }

  bool get _hasJpLibrary => _libraries.any((l) => l.libType == 'jp_movie');

  /// 动态库项的标题是运行时的库名，其余走契约反查
  String _titleOf(String key) {
    if (key.startsWith('lib:')) {
      final id = key.substring(4);
      for (final lib in _libraries) {
        if (lib.id == id) return lib.name;
      }
    }
    return navItemLabel(
      kAppNavSpecs['video']!,
      key,
      tr,
      fallback: tr('app.video'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppNavShell(
      appId: 'video',
      defaultKey: 'home',
      titleOf: _titleOf,
      dynamic: {
        'video.libraries': [
          for (final lib in _libraries)
            NavDynamicEntry(
              id: lib.id,
              label: lib.name,
              icon: lib.libType == 'tv'
                  ? 'live_tv_outlined'
                  : lib.libType == 'jp_movie'
                  ? 'local_movies_outlined'
                  : 'movie_outlined',
            ),
        ],
      },
      conditions: {if (_hasJpLibrary) 'hasJpLibrary'},
      content: (key) => KeyedSubtree(key: ValueKey('$key#$_epoch'), child: _content(key)),
    );
  }

  Widget _content(String key) {
    if (key.startsWith('lib:')) {
      for (final lib in _libraries) {
        if ('lib:${lib.id}' == key) {
          // 日本电影库和普通电影库的「入口」不同：参考实现是先进演员网格，
          // 点演员再看她的作品；点右上角「影片」才切回普通列表。
          if (lib.libType == 'jp_movie') {
            return VideoJpActorPage(embedded: true, libraryId: lib.id);
          }
          if (lib.libType == 'image' || lib.libType == 'mixed') {
            return VideoImageLibraryPage(
              embedded: true,
              libraryId: lib.id,
              libType: lib.libType,
              title: lib.name,
            );
          }
          return VideoPage(embedded: true, libraryId: lib.id);
        }
      }
      return const VideoPage(embedded: true);
    }
    switch (key) {
      case 'history':
        return const VideoHistoryPage();
      case 'favorites':
        return const VideoFavoritesPage();
      case 'series':
        return const VideoSeriesPage();
      case 'browse':
        return const VideoMediaBrowserPage();
      case 'jp_rank':
        return const VideoJpRankPage();
      case 'jp_actor':
        final jp = _libraries.where((l) => l.libType == 'jp_movie').toList();
        return VideoJpActorPage(
          embedded: true,
          libraryId: jp.isEmpty ? null : jp.first.id,
        );
      case 'collections':
        return const VideoCollectionsPage();
      case 'smartAlbums':
        return const VideoSmartAlbumsPage();
      case 'settings.library':
        return VideoLibrarySettingsPage(onLibrariesChanged: _loadLibraries);
      case 'settings.app':
        return const VideoAppSettingsPage();
      case 'settings.client':
        return const VideoClientSettingsPage();
      case 'duplicates':
        return const VideoDuplicatesPage();
      // 未列出的菜单项落到这个默认页
      // nav-default: home
      default:
        return const VideoPage(embedded: true);
    }
  }
}

/// 剧集浏览：剧名 + 季 / 集数（点击进剧集详情）
class VideoSeriesPage extends StatefulWidget {
  const VideoSeriesPage({super.key});

  @override
  State<VideoSeriesPage> createState() => _VideoSeriesPageState();
}

class _VideoSeriesPageState extends State<VideoSeriesPage> {
  bool _loading = true;
  String? _error;
  List<VideoSeriesItem> _items = const [];

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
      final res = await ApiSession.instance.client.videoSeriesList(limit: 200);
      if (!mounted) return;
      setState(() {
        _items = res.items;
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
    return NasAsyncView<List<VideoSeriesItem>>(
      loading: _loading,
      error: _error,
      onRetry: _load,
      data: _items,
      isEmpty: (items) => items.isEmpty,
      empty: NasEmptyState(
        title: tr('video.nav.emptyFiles'),
        icon: Icons.video_library_outlined,
      ),
      builder: (items) => ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final s = items[i];
          return ListTile(
            leading: const Icon(Icons.video_library_outlined),
            title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              tr('video.seasonsEpisodes', {
                'seasons': '${s.seasons}',
                'episodes': '${s.episodes}',
              }),
            ),
          );
        },
      ),
    );
  }
}

class VideoHistoryPage extends StatefulWidget {
  const VideoHistoryPage({super.key});

  @override
  State<VideoHistoryPage> createState() => _VideoHistoryPageState();
}

class _VideoHistoryPageState extends State<VideoHistoryPage> {
  bool _loading = true;
  String? _error;
  List<VideoProgressItem> _items = const [];

  /// all / unfinished / finished（「看完」的门在服务端，客户端不自己定 95）
  String _state = 'all';

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
      final res = await ApiSession.instance.client.videoProgressList(
        state: _state,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
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

  Future<void> _clear({bool onlyFinished = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          tr(
            onlyFinished
                ? 'video.history.clearFinished'
                : 'video.history.clearAll',
          ),
        ),
        content: Text(
          tr(
            onlyFinished
                ? 'video.history.clearFinishedBody'
                : 'video.history.clearAllBody',
          ),
        ),
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
    try {
      final res = await ApiSession.instance.client.videoProgressClear(
        body: VideoProgressClearBody(onlyFinished: onlyFinished),
      );
      if (!mounted) return;
      NasSnack.show(context, tr('video.history.cleared', {'n': '${res.cleared}'}));
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final filters = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            0,
          ),
          child: Row(
            children: [
              for (final (value, key) in const [
                ('all', 'video.history.all'),
                ('unfinished', 'video.history.unfinished'),
                ('finished', 'video.history.finished'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: NasTokens.spaceXs),
                  child: NasChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(tr(key)),
                    selected: _state == value,
                    onSelected: (_) {
                      setState(() => _state = value);
                      _load();
                    },
                  ),
                ),
              const Spacer(),
              PopupMenuButton<bool>(
                tooltip: tr('video.history.clear'),
                icon: const Icon(Icons.delete_sweep_outlined),
                onSelected: (onlyFinished) =>
                    _clear(onlyFinished: onlyFinished),
                itemBuilder: (ctx) => [
                  PopupMenuItem(
                    value: true,
                    child: Text(tr('video.history.clearFinished')),
                  ),
                  PopupMenuItem(
                    value: false,
                    child: Text(tr('video.history.clearAll')),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const NasLoading()
              : _error != null
              ? NasErrorState(message: _error!, onRetry: _load)
              : _items.isEmpty
              ? ListView(
                  children: [
                    NasEmptyState(
                      title: tr('video.nav.emptyHistory'),
                      icon: Icons.history,
                    ),
                  ],
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final p = _items[i];
                    final ratio = (p.percent / 100).clamp(0.0, 1.0);
                    return ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(
                        p.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(value: ratio, minHeight: 3),
                          const SizedBox(height: 2),
                          Text('${p.position} · ${p.percent}%'),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
    return filters;
  }
}

/// 收藏（每用户独立）
class VideoFavoritesPage extends StatefulWidget {
  const VideoFavoritesPage({super.key});

  @override
  State<VideoFavoritesPage> createState() => _VideoFavoritesPageState();
}

class _VideoFavoritesPageState extends State<VideoFavoritesPage> {
  bool _loading = true;
  String? _error;
  List<VideoItem> _items = const [];

  /// 剧集级收藏（按 series 聚合）
  List<VideoSeriesFavoriteItem> _series = const [];

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
      final res = await ApiSession.instance.client.videoFavorites(limit: 200);
      List<VideoSeriesFavoriteItem> series = const [];
      try {
        final fav = await ApiSession.instance.client.videoSeriesFavorites();
        series = fav.items;
      } catch (_) {
        // 剧集收藏读取失败不影响影片收藏列表
      }
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _series = series;
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

  Future<void> _remove(VideoItem item) async {
    try {
      await ApiSession.instance.client.videoFavoriteSet(
        body: VideoFavoriteBody(ids: [item.id], favorite: false),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty && _series.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.nav.emptyFavorites'),
            icon: Icons.favorite_border,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_series.isNotEmpty) _seriesRail(context),
        Expanded(
          child: _items.isEmpty
              ? Center(
                  child: Text(
                    tr('video.nav.emptyFavorites'),
                    style: TextStyle(color: context.nasTextSecondary),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(NasTokens.spaceMd),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    mainAxisSpacing: NasTokens.spaceSm,
                    crossAxisSpacing: NasTokens.spaceSm,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final item = _items[i];
                    return NasCard(
                      padding: const EdgeInsets.all(NasTokens.spaceXs),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Center(
                              child: Icon(
                                Icons.movie_outlined,
                                size: 32,
                                color: context.nasTextSecondary,
                              ),
                            ),
                          ),
                          Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: NasTokens.fontCaption),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              tooltip: tr('nav.favorites'),
                              icon: const Icon(Icons.favorite, size: 16),
                              onPressed: () => _remove(item),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 剧集级收藏横条：点进去是剧集详情（季 / 集列表）
  Widget _seriesRail(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceMd,
            NasTokens.spaceMd,
            NasTokens.spaceXs,
          ),
          child: Text(
            tr('ui.video.011'),
            style: const TextStyle(
              fontSize: NasTokens.fontSubtitle,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(
          height: 116,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: _series.length,
            separatorBuilder: (_, _) =>
                const SizedBox(width: NasTokens.spaceSm),
            itemBuilder: (context, i) {
              final s = _series[i];
              return SizedBox(
                width: 150,
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => VideoSeriesDetailPage(
                        name: s.series,
                        coverId: s.coverId,
                        posterUrl: null,
                        headers: {
                          if (ApiSession.instance.token != null)
                            'authorization':
                                'Bearer ${ApiSession.instance.token}',
                        },
                      ),
                    ),
                  ),
                  child: NasCard(
                    padding: const EdgeInsets.all(NasTokens.spaceXs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Center(
                            child: Icon(
                              Icons.video_library_outlined,
                              size: 28,
                              color: context.nasTextSecondary,
                            ),
                          ),
                        ),
                        Text(
                          s.series,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: NasTokens.fontCaption),
                        ),
                        Text(
                          tr('video.seasonsEpisodes', {
                            'seasons': '${s.seasons}',
                            'episodes': '${s.episodes}',
                          }),
                          style: TextStyle(
                            fontSize: NasTokens.fontMicro,
                            color: context.nasTextSecondary,
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
}
