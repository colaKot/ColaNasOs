import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import 'music_page.dart';
import 'music_track_view.dart';

/// 曲库 · 收藏：与歌曲页同一套封面网格，按收藏时间倒序（服务端已排好）。
class MusicFavoritesPage extends StatefulWidget {
  const MusicFavoritesPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<MusicFavoritesPage> createState() => _MusicFavoritesPageState();
}

class _MusicFavoritesPageState extends State<MusicFavoritesPage> {
  final _searchCtrl = TextEditingController();
  late final MusicSearchDebouncer _searchDebounce = MusicSearchDebouncer(
    () => setState(() {}),
  );

  bool _loading = true;
  String? _error;
  List<MusicTrack> _items = const [];
  String _query = '';
  String _sort = 'favorite';
  bool _desc = true;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchText);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchText);
    _searchCtrl.dispose();
    _searchDebounce.dispose();
    super.dispose();
  }

  void _onSearchText() {
    final next = _searchCtrl.text.trim();
    if (next == _query) return;
    _query = next;
    _searchDebounce.run();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.musicFavorites();
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

  List<MusicTrack> get _visible {
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? [..._items]
        : _items
              .where(
                (t) =>
                    t.title.toLowerCase().contains(q) ||
                    (t.artist ?? '').toLowerCase().contains(q) ||
                    (t.album ?? '').toLowerCase().contains(q),
              )
              .toList();
    if (_sort == 'favorite') return list;
    int cmp(MusicTrack a, MusicTrack b) => switch (_sort) {
      'artist' => (a.artist ?? '').compareTo(b.artist ?? ''),
      'album' => (a.album ?? '').compareTo(b.album ?? ''),
      'year' => (a.year ?? 0).compareTo(b.year ?? 0),
      'duration' => (a.durationMs ?? 0).compareTo(b.durationMs ?? 0),
      _ => a.title.compareTo(b.title),
    };
    list.sort((a, b) => _desc ? cmp(b, a) : cmp(a, b));
    return list;
  }

  Future<void> _unfavorite(MusicTrack track) async {
    final ok = await musicSetFavorite(track.id, false);
    if (!ok || !mounted) return;
    setState(() => _items = _items.where((t) => t.id != track.id).toList());
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

  void _copyPlayUrl(MusicTrack track) async {
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

  List<NasMenuEntry> _menuFor(
    MusicTrack track,
    List<MusicTrack> queue,
    int i,
  ) => [
    NasMenuEntry(
      label: tr('music.play'),
      icon: Icons.play_arrow,
      onSelected: () => musicPlayTracks(context, queue, i),
    ),
    NasMenuEntry(
      label: tr('music.favorite.remove'),
      icon: Icons.favorite,
      onSelected: () => _unfavorite(track),
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
      onSelected: () => showDialog<void>(
        context: context,
        builder: (_) => MusicLyricsDialog(track: track),
      ),
    ),
  ];

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final tracks = _visible;
    if (tracks.isEmpty) {
      return NasEmptyState(
        title: tr('music.nav.emptyFavorites'),
        icon: Icons.favorite_border,
      );
    }
    return CustomScrollView(
      slivers: [
        MusicTrackGridSliver(
          tracks: tracks,
          itemBuilder: (context, track, i) => MusicTrackCard(
            track: track,
            favorite: true,
            onPlay: () => musicPlayTracks(context, tracks, i),
            onToggleFavorite: () => _unfavorite(track),
            menuEntries: _menuFor(track, tracks, i),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        MusicToolbar(
          searchController: _searchCtrl,
          searchHint: tr('ui.music.011'),
          onClear: () => setState(() {}),
          actions: [
            MusicSortButton(
              value: _sort,
              desc: _desc,
              options: const [
                ('favorite', 'music.sort.favorite'),
                ('title', 'music.sort.title'),
                ('artist', 'music.sort.artist'),
                ('album', 'music.sort.album'),
                ('year', 'music.sort.year'),
                ('duration', 'music.sort.duration'),
              ],
              onChanged: (value, desc) => setState(() {
                _sort = value;
                _desc = desc;
              }),
            ),
            NasRefreshButton(onPressed: _load),
          ],
        ),
        Expanded(child: _body()),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('nav.favorites'))),
      body: body,
    );
  }
}

/// 曲库 · 播放历史：服务端按播放时间倒序返回，行式列表（对齐既有实现的表格行）。
class MusicHistoryPage extends StatefulWidget {
  const MusicHistoryPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<MusicHistoryPage> createState() => _MusicHistoryPageState();
}

class _MusicHistoryPageState extends State<MusicHistoryPage> {
  final _searchCtrl = TextEditingController();
  late final MusicSearchDebouncer _searchDebounce = MusicSearchDebouncer(
    () => setState(() {}),
  );

  bool _loading = true;
  String? _error;
  List<MusicTrack> _items = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchText);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchText);
    _searchCtrl.dispose();
    _searchDebounce.dispose();
    super.dispose();
  }

  void _onSearchText() {
    final next = _searchCtrl.text.trim();
    if (next == _query) return;
    _query = next;
    _searchDebounce.run();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.musicHistory(limit: 200);
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

  List<MusicTrack> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              (t.artist ?? '').toLowerCase().contains(q) ||
              (t.album ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final tracks = _visible;
    if (tracks.isEmpty) {
      return NasEmptyState(
        title: tr('music.nav.emptyHistory'),
        icon: Icons.history,
      );
    }
    return ListView.separated(
      itemCount: tracks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => MusicTrackRow(
        track: tracks[i],
        onPlay: () => musicPlayTracks(context, tracks, i),
        leading: const Icon(Icons.history, size: 18),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        MusicToolbar(
          searchController: _searchCtrl,
          searchHint: tr('ui.music.011'),
          onClear: () => setState(() {}),
          actions: [
            IconButton(
              tooltip: tr('ui.music.024'),
              icon: const Icon(Icons.play_circle_outline),
              onPressed: _visible.isEmpty
                  ? null
                  : () => musicPlayTracks(context, _visible, 0),
            ),
            NasRefreshButton(onPressed: _load),
          ],
        ),
        Expanded(child: _body()),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('music.nav.history'))),
      body: body,
    );
  }
}

/// 曲库 · 专辑 / 歌手：封面卡片网格，点开看曲目。
class MusicGroupedPage extends StatefulWidget {
  const MusicGroupedPage({
    super.key,
    required this.groupBy,
    this.embedded = true,
  });

  /// `album` / `artist` / `folder`
  final String groupBy;
  final bool embedded;

  @override
  State<MusicGroupedPage> createState() => _MusicGroupedPageState();
}

class _GroupItem {
  const _GroupItem({
    required this.name,
    required this.subtitle,
    required this.count,
    this.coverTrackId,
  });

  final String name;
  final String subtitle;
  final int count;
  final String? coverTrackId;
}

class _MusicGroupedPageState extends State<MusicGroupedPage> {
  final _searchCtrl = TextEditingController();
  late final MusicSearchDebouncer _searchDebounce = MusicSearchDebouncer(_load);

  bool _loading = true;
  String? _error;
  List<_GroupItem> _items = const [];
  String _query = '';
  String _sort = 'count';
  bool _desc = true;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _searchDebounce.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final next = _searchCtrl.text.trim();
    if (next == _query) return;
    _query = next;
    _searchDebounce.run();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ApiSession.instance.client;
      final items = <_GroupItem>[];
      if (widget.groupBy == 'album') {
        final res = await client.musicAlbums(
          q: _query.isEmpty ? null : _query,
          sort: _sort == 'year'
              ? 'year'
              : (_sort == 'count' ? 'tracks' : 'name'),
          limit: 1000,
        );
        for (final a in res.items) {
          items.add(
            _GroupItem(
              name: a.name,
              subtitle: [
                a.artist ?? '',
                a.year == null ? '' : '${a.year}',
              ].where((x) => x.isNotEmpty).join(' · '),
              count: a.tracks,
              coverTrackId: a.coverTrackId,
            ),
          );
        }
      } else if (widget.groupBy == 'artist') {
        final res = await client.musicArtists(
          q: _query.isEmpty ? null : _query,
          sort: _sort == 'count' ? 'tracks' : 'name',
          limit: 1000,
        );
        for (final a in res.items) {
          items.add(
            _GroupItem(
              name: a.name,
              subtitle: tr('music.group.albumCount', {'count': '${a.albums}'}),
              count: a.tracks,
              coverTrackId: a.coverTrackId,
            ),
          );
        }
      } else {
        // 文件夹视图：服务端没有按目录聚合，这里按前 200 首的父目录分组
        final res = await client.musicList(limit: 200);
        final map = <String, int>{};
        for (final t in res.items) {
          final key = t.path.contains('/')
              ? t.path.substring(0, t.path.lastIndexOf('/'))
              : '/';
          map[key] = (map[key] ?? 0) + 1;
        }
        for (final e in map.entries) {
          items.add(_GroupItem(name: e.key, subtitle: '', count: e.value));
        }
      }
      if (widget.groupBy == 'folder') {
        items.sort(
          (a, b) => _desc ? b.name.compareTo(a.name) : a.name.compareTo(b.name),
        );
      }
      if (!mounted) return;
      setState(() {
        _items = items;
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

  void _open(_GroupItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicGroupTracksPage(
          title: item.name,
          album: widget.groupBy == 'album' ? item.name : null,
          artist: widget.groupBy == 'artist' ? item.name : null,
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('music.nav.empty'),
        icon: Icons.library_music_outlined,
      );
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceXs,
            NasTokens.spaceMd,
            NasTokens.spaceMd,
          ),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              // 与曲目网格同一套算法：行高由格子宽 + 文字区高度直接算出，
              // 不用 childAspectRatio，窄屏也不会溢出。
              // `crossAxisExtent` 已扣过外层 SliverPadding，别再减 spaceMd*2
              // （见 MusicTrackGridSliver 的注释：多减一次会让格子算窄、卡片溢出）。
              const desiredWidth = 150.0;
              const spacing = NasTokens.spaceSm;
              final content = constraints.crossAxisExtent.clamp(
                0.0,
                double.infinity,
              );
              final count = (content / desiredWidth).floor().clamp(2, 10);
              final cellWidth = ((content - spacing * (count - 1)) / count)
                  .floorToDouble();
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: count,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                  // 封面（= 格子宽）+ 6 间距 + 44 文字 + 4 余量
                  mainAxisExtent: cellWidth + 54,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _GroupCard(
                    item: _items[i],
                    isArtist: widget.groupBy == 'artist',
                    isFolder: widget.groupBy == 'folder',
                    onTap: () => _open(_items[i]),
                  ),
                  childCount: _items.length,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final countKey = widget.groupBy == 'album'
        ? 'music.nav.albums'
        : widget.groupBy == 'artist'
        ? 'music.nav.artists'
        : 'nav.filesView';
    final body = Column(
      children: [
        MusicToolbar(
          searchController: _searchCtrl,
          searchHint: tr('ui.music.011'),
          onClear: () {
            if (_query.isEmpty) return;
            _query = '';
            _load();
          },
          actions: [
            MusicSortButton(
              value: _sort,
              desc: _desc,
              options: widget.groupBy == 'album'
                  ? const [
                      ('count', 'music.sort.count'),
                      ('name', 'music.sort.name'),
                      ('year', 'music.sort.year'),
                    ]
                  : const [
                      ('count', 'music.sort.count'),
                      ('name', 'music.sort.name'),
                    ],
              onChanged: (value, desc) {
                setState(() {
                  _sort = value;
                  _desc = desc;
                });
                _load();
              },
            ),
            NasRefreshButton(onPressed: _load),
          ],
        ),
        Expanded(child: _body()),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr(countKey))),
      body: body,
    );
  }
}

class _GroupCard extends StatefulWidget {
  const _GroupCard({
    required this.item,
    required this.onTap,
    this.isArtist = false,
    this.isFolder = false,
  });

  final _GroupItem item;
  final VoidCallback onTap;
  final bool isArtist;
  final bool isFolder;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cover = Stack(
      fit: StackFit.expand,
      children: [
        if (widget.item.coverTrackId != null)
          NasCoverImage(
            url: musicCoverUrl(widget.item.coverTrackId!),
            headers: ApiSession.instance.authHeaders,
            cacheWidth: 360,
            icon: widget.isArtist ? Icons.person_outline : Icons.album_outlined,
            borderRadius: 0,
          )
        else
          ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Icon(
              widget.isArtist
                  ? Icons.person_outline
                  : widget.isFolder
                  ? Icons.folder_outlined
                  : Icons.album_outlined,
              size: 34,
              color: context.nasTextSecondary,
            ),
          ),
        if (_hovered) ColoredBox(color: Colors.black.withValues(alpha: 0.22)),
      ],
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(NasTokens.radiusMd),
              child: AspectRatio(aspectRatio: 1, child: cover),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 44,
              child: Column(
                children: [
                  Text(
                    widget.item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: NasTokens.fontBody,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (widget.item.subtitle.isNotEmpty) widget.item.subtitle,
                      tr('ui.music.039', {'n': '${widget.item.count}'}),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 专辑 / 歌手下的曲目列表：整张播放 + 单曲点播。
class MusicGroupTracksPage extends StatefulWidget {
  const MusicGroupTracksPage({
    super.key,
    required this.title,
    this.album,
    this.artist,
  });

  final String title;
  final String? album;
  final String? artist;

  @override
  State<MusicGroupTracksPage> createState() => _MusicGroupTracksPageState();
}

class _MusicGroupTracksPageState extends State<MusicGroupTracksPage> {
  bool _loading = true;
  String? _error;
  List<MusicTrack> _tracks = const [];

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
      final res = await ApiSession.instance.client.musicList(
        album: widget.album,
        artist: widget.artist,
        sort: 'title',
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _tracks = res.items;
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: tr('ui.music.024'),
            icon: const Icon(Icons.play_circle_outline),
            onPressed: _tracks.isEmpty
                ? null
                : () => musicPlayTracks(context, _tracks, 0),
          ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : ListView.separated(
              itemCount: _tracks.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => MusicTrackRow(
                track: _tracks[i],
                onPlay: () => musicPlayTracks(context, _tracks, i),
              ),
            ),
    );
  }
}
