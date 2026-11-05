import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/scan_refresh.dart';
import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import 'music_playback.dart';
import 'music_track_view.dart';

/// 曲库 · 歌曲：封面网格 + 搜索 / 排序 / 来源筛选。
///
///   * 曲库是**全局共享**的，页面里没有「新建音乐库 / 扫描」入口（来源在 设置 → 音乐来源）；
///   * 列表是封面网格，悬停出现播放 / 收藏 / 更多，右键与「更多」共用一批动作；
///   * 排序、来源筛选在顶部工具条，搜索边输入边过滤。
class MusicPage extends StatefulWidget {
  const MusicPage({super.key, this.embedded = false});

  /// 嵌在二级导航内容区时去掉自带 AppBar
  final bool embedded;

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  static const _pageSize = 120;

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  late final MusicSearchDebouncer _searchDebounce = MusicSearchDebouncer(
    _reload,
  );

  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _cursor;
  String _query = '';
  String _sort = 'title';
  bool _desc = false;
  String? _libraryId;

  List<MusicTrack> _tracks = const [];
  List<MusicLibraryItem> _sources = const [];
  Set<String> _favoriteIds = <String>{};
  MusicStatsResponse? _stats;

  late final void Function() _unsubScan;

  @override
  void initState() {
    super.initState();
    _unsubScan = listenScanDone('music', () {
      if (mounted) _bootstrap();
    });
    _scroll.addListener(_onScroll);
    // NasSearchField 只暴露回车 / 清除，边输入边过滤要靠 controller 监听 + 防抖
    _searchCtrl.addListener(_onSearchText);
    _bootstrap();
  }

  void _onSearchText() {
    final next = _searchCtrl.text.trim();
    if (next == _query) return;
    _query = next;
    _searchDebounce.run();
  }

  @override
  void dispose() {
    _unsubScan();
    _scroll.dispose();
    _searchCtrl.removeListener(_onSearchText);
    _searchCtrl.dispose();
    _searchDebounce.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || _cursor == null) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ApiSession.instance.client;
      final results = await Future.wait<Object>([
        client.musicList(limit: _pageSize, sort: _sort, order: _order),
        client.musicStats(),
        client.musicLibraryList(),
        client.musicFavorites(),
      ]);
      final list = results[0] as MusicListResponse;
      final stats = results[1] as MusicStatsResponse;
      final libs = results[2] as MusicLibraryListResponse;
      final favs = results[3] as MusicListResponse;
      if (!mounted) return;
      setState(() {
        _tracks = list.items;
        _cursor = list.nextCursor;
        _stats = stats;
        _sources = libs.items;
        _favoriteIds = favs.items.map((t) => t.id).toSet();
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

  String get _order => _desc ? 'desc' : 'asc';

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _cursor = null;
    });
    try {
      final res = await ApiSession.instance.client.musicList(
        q: _query.isEmpty ? null : _query,
        libraryId: _libraryId,
        sort: _sort,
        order: _order,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _tracks = res.items;
        _cursor = res.nextCursor;
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final cursor = _cursor;
    if (cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final res = await ApiSession.instance.client.musicList(
        q: _query.isEmpty ? null : _query,
        libraryId: _libraryId,
        sort: _sort,
        order: _order,
        cursor: cursor,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _tracks = [..._tracks, ...res.items];
        _cursor = res.nextCursor;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _toggleFavorite(MusicTrack track) async {
    final next = !_favoriteIds.contains(track.id);
    setState(() {
      if (next) {
        _favoriteIds = {..._favoriteIds, track.id};
      } else {
        _favoriteIds = _favoriteIds.where((id) => id != track.id).toSet();
      }
    });
    final ok = await musicSetFavorite(track.id, next);
    if (!ok && mounted) {
      setState(() {
        if (next) {
          _favoriteIds = _favoriteIds.where((id) => id != track.id).toSet();
        } else {
          _favoriteIds = {..._favoriteIds, track.id};
        }
      });
    }
  }

  Future<void> _addToPlaylist(MusicTrack track) async {
    final messenger = ScaffoldMessenger.of(context);
    final playlists = await ApiSession.instance.client.musicPlaylistList();
    if (!mounted) return;
    if (playlists.items.isEmpty) {
      NasSnack.showOn(messenger, tr('ui.music.006'));
      return;
    }
    final target = await showDialog<MusicPlaylist>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('ui.music.007')),
        children: [
          for (final p in playlists.items)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text(p.name),
            ),
        ],
      ),
    );
    if (target == null) return;
    try {
      await ApiSession.instance.client.musicPlaylistAdd(
        body: MusicPlaylistMembersBody(
          playlistId: target.id,
          trackIds: [track.id],
        ),
      );
      NasSnack.showOn(messenger, tr('music.addedTo', {'name': target.name}));
    } catch (e) {
      NasSnack.showOn(messenger, tr('music.joinFailed', {'error': '$e'}));
    }
  }

  Future<void> _copyPlayUrl(MusicTrack track) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.musicStreamUrl(id: track.id);
      await Clipboard.setData(
        ClipboardData(text: '${ApiSession.instance.baseUrl}${res.url}'),
      );
      NasSnack.showOn(
        messenger,
        tr('music.copyUrl', {'minutes': '${res.expiresInSec ~/ 60}'}),
      );
    } catch (e) {
      NasSnack.showOn(messenger, tr('music.playUrlFailed', {'error': '$e'}));
    }
  }

  void _openLyrics(MusicTrack track) {
    showDialog<void>(
      context: context,
      builder: (_) => MusicLyricsDialog(track: track),
    );
  }

  List<NasMenuEntry> _menuFor(MusicTrack track) => [
    NasMenuEntry(
      label: tr('music.play'),
      icon: Icons.play_arrow,
      onSelected: () {
        final i = _tracks.indexWhere((t) => t.id == track.id);
        musicPlayTracks(context, _tracks, i < 0 ? 0 : i);
      },
    ),
    NasMenuEntry(
      label: _favoriteIds.contains(track.id)
          ? tr('music.favorite.remove')
          : tr('music.favorite.add'),
      icon: _favoriteIds.contains(track.id)
          ? Icons.favorite
          : Icons.favorite_border,
      onSelected: () => _toggleFavorite(track),
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('ui.music.007'),
      icon: Icons.playlist_add,
      onSelected: () => _addToPlaylist(track),
    ),
    NasMenuEntry(
      label: tr('ui.music.014'),
      icon: Icons.link,
      onSelected: () => _copyPlayUrl(track),
    ),
    NasMenuEntry(
      label: tr('music.lyrics.title'),
      icon: Icons.lyrics_outlined,
      onSelected: () => _openLyrics(track),
    ),
  ];

  Widget _sourceButton() {
    if (_sources.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<String?>(
      tooltip: tr('music.source.title'),
      icon: Icon(
        Icons.source_outlined,
        size: 20,
        color: _libraryId == null
            ? null
            : Theme.of(context).colorScheme.primary,
      ),
      onSelected: (v) {
        setState(() => _libraryId = v);
        _reload();
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem<String?>(
          value: null,
          checked: _libraryId == null,
          child: Text(tr('music.source.all')),
        ),
        for (final s in _sources)
          CheckedPopupMenuItem<String?>(
            value: s.id,
            checked: _libraryId == s.id,
            child: Text(s.name),
          ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(NasTokens.spaceMd),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final stats = _stats;
    if (stats == null) return const SizedBox(height: NasTokens.spaceMd);
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceLg),
      child: Center(
        child: Text(
          tr('music.stats', {
            'tracks': '${stats.tracks}',
            'albums': '${stats.albums}',
            'artists': '${stats.artists}',
          }),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _bootstrap);
    }

    final service = MusicPlaybackService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final currentId = service.track?.id;
        return CustomScrollView(
          controller: _scroll,
          slivers: [
            if (_tracks.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: NasEmptyState(
                  title: _query.isEmpty
                      ? tr('ui.music.012')
                      : tr('ui.music.013'),
                  message: _query.isEmpty ? tr('ui.music.h266f73') : null,
                  icon: Icons.library_music_outlined,
                ),
              )
            else ...[
              MusicTrackGridSliver(
                tracks: _tracks,
                itemBuilder: (context, track, i) => MusicTrackCard(
                  track: track,
                  favorite: _favoriteIds.contains(track.id),
                  current: currentId == track.id,
                  playing: service.playing,
                  onPlay: () => musicPlayTracks(context, _tracks, i),
                  onToggleFavorite: () => _toggleFavorite(track),
                  menuEntries: _menuFor(track),
                ),
              ),
              SliverToBoxAdapter(child: _footer(context)),
            ],
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        MusicToolbar(
          searchController: _searchCtrl,
          searchHint: tr('ui.music.011'),
          onSubmitted: (v) {
            final next = v.trim();
            if (next == _query) return;
            _query = next;
            _reload();
          },
          onClear: () {
            if (_query.isEmpty) return;
            setState(() => _query = '');
            _reload();
          },
          actions: [
            _sourceButton(),
            MusicSortButton(
              value: _sort,
              desc: _desc,
              options: const [
                ('title', 'music.sort.title'),
                ('artist', 'music.sort.artist'),
                ('album', 'music.sort.album'),
                ('year', 'music.sort.year'),
                ('duration', 'music.sort.duration'),
                ('created', 'music.sort.created'),
              ],
              onChanged: (value, desc) {
                setState(() {
                  _sort = value;
                  _desc = desc;
                });
                _reload();
              },
            ),
            NasRefreshButton(onPressed: _bootstrap),
          ],
        ),
        Expanded(child: _body()),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('ui.music.008'))),
      body: body,
    );
  }
}

/// 歌词弹窗：旁挂 `LRC` 优先、其次内嵌（ID3 USLT / flac Vorbis comment）。
class MusicLyricsDialog extends StatefulWidget {
  const MusicLyricsDialog({super.key, required this.track});

  final MusicTrack track;

  @override
  State<MusicLyricsDialog> createState() => _MusicLyricsDialogState();
}

class _MusicLyricsDialogState extends State<MusicLyricsDialog> {
  bool _loading = true;
  String? _error;
  MusicLyricsResponse? _data;

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
      final data = await ApiSession.instance.client.musicLyrics(
        id: widget.track.id,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = tr('music.lyricsFailed', {'error': '$e'});
      });
    }
  }

  String get _sourceLabel => switch (_data?.source) {
    'lrc' => tr('ui.music.hff934c'),
    'embedded' => tr('ui.music.h1e684d'),
    _ => tr('ui.music.h7a430c'),
  };

  static String _stamp(int ms) {
    final total = ms ~/ 1000;
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);

    final data = _data;
    if (data == null || data.lines.isEmpty) {
      return NasEmptyState(
        title: tr('ui.music.016'),
        message: tr('ui.music.hdb4c02'),
        icon: Icons.lyrics_outlined,
      );
    }

    final meta = [
      data.title,
      data.artist,
      data.album,
    ].whereType<String>().where((s) => s.isNotEmpty).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            0,
            NasTokens.spaceMd,
            NasTokens.spaceSm,
          ),
          child: Text(
            [
              _sourceLabel,
              if (meta.isNotEmpty) meta.join(' · '),
              if (!data.synced) tr('ui.music.h952253'),
            ].join('  |  '),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ),
        for (final line in data.lines)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NasTokens.spaceMd,
              vertical: NasTokens.spaceXs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (line.timeMs != null)
                  SizedBox(
                    width: 56,
                    child: Text(
                      _stamp(line.timeMs!),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: NasTokens.fontMono,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ),
                Expanded(child: SelectableText(line.text)),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        tr('music.lyricsTitle', {'title': widget.track.title}),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(width: 520, height: 420, child: _body()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.close')),
        ),
      ],
    );
  }
}
