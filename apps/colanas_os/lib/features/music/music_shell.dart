import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_nav_shell.dart';
import '../../shell/nav_spec_adapter.dart';
import 'music_page.dart';
import 'music_playback.dart';
import 'music_player_page.dart';

/// 音乐主页：左侧二级导航 + 内容区。
///
/// 菜单结构（曲目 / 歌单 / 设置三组）来自 `contracts/apps.json#nav`；
/// 「最近添加 / 最近播放 / 最常播放 / 从未播放」是歌单组下的**一级栏目**，
/// 不再嵌在歌单页里当三级菜单。
class MusicShellPage extends StatefulWidget {
  const MusicShellPage({super.key});

  @override
  State<MusicShellPage> createState() => _MusicShellPageState();
}

class _MusicShellPageState extends State<MusicShellPage> {
  /// 菜单项 id → 文案（自动歌单的标题直接取侧栏那一份，不另写死）
  String _labelOf(String key) => navItemLabel(
    kAppNavSpecs['music']!,
    key,
    tr,
    fallback: tr('ui.music.008'),
  );

  Widget _content(String key) {
    switch (key) {
      case 'favorites':
        return const _MusicFavoritesPage();
      case 'history':
        return const _MusicHistoryPage();
      case 'albums':
        return const _MusicGroupedPage(groupBy: 'album');
      case 'artists':
        return const _MusicGroupedPage(groupBy: 'artist');
      case 'files':
        return const _MusicGroupedPage(groupBy: 'folder');
      case 'playlists':
        return const MusicPlaylistsPage();
      // 自动歌单：服务端 kind → 左侧栏四个独立栏目（不再藏在歌单页里当三级菜单）
      case 'recentAdded':
        return MusicAutoPlaylistPage(
          kind: 'recent_added',
          title: _labelOf(key),
          embedded: true,
        );
      case 'recentPlayed':
        return MusicAutoPlaylistPage(
          kind: 'recently_played',
          title: _labelOf(key),
          embedded: true,
        );
      case 'mostPlayed':
        return MusicAutoPlaylistPage(
          kind: 'most_played',
          title: _labelOf(key),
          embedded: true,
        );
      case 'neverPlayed':
        return MusicAutoPlaylistPage(
          kind: 'never_played',
          title: _labelOf(key),
          embedded: true,
        );
      case 'settings':
        return const _MusicSettingsPage();
      // 未列出的菜单项落到曲目页
      // nav-default: songs
      default:
        return const MusicPage(embedded: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppNavShell(
      appId: 'music',
      defaultKey: 'songs',
      content: _content,
    );
  }
}


class _MusicFavoritesPage extends StatefulWidget {
  const _MusicFavoritesPage();

  @override
  State<_MusicFavoritesPage> createState() => _MusicFavoritesPageState();
}

class _MusicFavoritesPageState extends State<_MusicFavoritesPage> {
  bool _loading = true;
  String? _error;
  List<MusicStateItem> _items = const [];

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
      final res = await ApiSession.instance.client.musicFavorites();
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('music.nav.emptyFavorites'),
            icon: Icons.favorite_border,
          ),
        ],
      );
    }
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final t = _items[i];
        return ListTile(
          leading: const Icon(Icons.music_note),
          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${t.artist ?? '-'} · ${t.album ?? '-'}'),
        );
      },
    );
  }
}

class _MusicHistoryPage extends StatefulWidget {
  const _MusicHistoryPage();

  @override
  State<_MusicHistoryPage> createState() => _MusicHistoryPageState();
}

class _MusicHistoryPageState extends State<_MusicHistoryPage> {
  bool _loading = true;
  String? _error;
  List<MusicHistoryItem> _items = const [];

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
      final res = await ApiSession.instance.client.musicHistory(limit: 200);
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('music.nav.emptyHistory'),
            icon: Icons.history,
          ),
        ],
      );
    }
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final t = _items[i];
        return ListTile(
          leading: const Icon(Icons.history),
          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${t.artist ?? '-'} · ${t.album ?? '-'}'),
        );
      },
    );
  }
}

/// 专辑 / 歌手 / 文件视图：用全量曲目在前端聚合
class _MusicGroupedPage extends StatefulWidget {
  const _MusicGroupedPage({required this.groupBy});

  final String groupBy;

  @override
  State<_MusicGroupedPage> createState() => _MusicGroupedPageState();
}

class _GroupRow {
  const _GroupRow({
    required this.title,
    required this.subtitle,
    required this.count,
    this.coverTrackId,
  });

  final String title;
  final String subtitle;
  final int count;
  final String? coverTrackId;
}

/// 专辑 / 艺人 / 目录视图。
///
/// 此前三种视图都是「拉前 200 首在本地 groupBy」：库超过 200 首，专辑和艺人
/// 会**静默缺一部分**（用户只会觉得"有些专辑不见了"）。现在专辑与艺人走服务端
/// 聚合接口（不受 200 限制、可点进去看曲目），目录仍走本地分组。
class _MusicGroupedPageState extends State<_MusicGroupedPage> {
  bool _loading = true;
  String? _error;
  List<_GroupRow> _rows = const [];

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
      final client = ApiSession.instance.client;
      final rows = <_GroupRow>[];
      if (widget.groupBy == 'album') {
        final res = await client.musicAlbums(limit: 500);
        for (final a in res.items) {
          rows.add(
            _GroupRow(
              title: a.name,
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
        final res = await client.musicArtists(limit: 500);
        for (final a in res.items) {
          rows.add(
            _GroupRow(
              title: a.name,
              subtitle: tr('music.group.albumCount', {'count': '${a.albums}'}),
              count: a.tracks,
              coverTrackId: a.coverTrackId,
            ),
          );
        }
      } else {
        final res = await client.musicList(limit: 200);
        final map = <String, int>{};
        for (final t in res.items) {
          final key = t.path.contains('/')
              ? t.path.substring(0, t.path.lastIndexOf('/'))
              : '/';
          map[key] = (map[key] ?? 0) + 1;
        }
        final sorted = map.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        for (final e in sorted) {
          rows.add(_GroupRow(title: e.key, subtitle: '', count: e.value));
        }
      }
      if (!mounted) return;
      setState(() {
        _rows = rows;
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

  void _open(_GroupRow row) {
    if (widget.groupBy == 'folder') return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _GroupTracksPage(
          title: row.title,
          album: widget.groupBy == 'album' ? row.title : null,
          artist: widget.groupBy == 'artist' ? row.title : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_rows.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('music.nav.empty'),
            icon: Icons.library_music_outlined,
          ),
        ],
      );
    }
    return ListView.builder(
      itemCount: _rows.length,
      itemBuilder: (context, i) {
        final row = _rows[i];
        final coverUrl = row.coverTrackId == null
            ? null
            : '${ApiSession.instance.baseUrl}/api/v1/music/cover'
                  '?id=${Uri.encodeComponent(row.coverTrackId!)}';
        return ListTile(
          leading: SizedBox(
            width: 44,
            height: 44,
            child: coverUrl == null
                ? Icon(
                    widget.groupBy == 'artist'
                        ? Icons.person_outline
                        : widget.groupBy == 'folder'
                        ? Icons.folder_outlined
                        : Icons.album_outlined,
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                    child: NasCoverImage(
                      url: coverUrl,
                      headers: ApiSession.instance.authHeaders,
                      cacheWidth: 96,
                      icon: Icons.music_note_outlined,
                    ),
                  ),
          ),
          title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: row.subtitle.isEmpty
              ? null
              : Text(
                  row.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Text('${row.count}'),
          onTap: () => _open(row),
        );
      },
    );
  }
}

/// 专辑 / 艺人下的曲目列表：可整张播放，也能单曲点播。
class _GroupTracksPage extends StatefulWidget {
  const _GroupTracksPage({required this.title, this.album, this.artist});

  final String title;
  final String? album;
  final String? artist;

  @override
  State<_GroupTracksPage> createState() => _GroupTracksPageState();
}

class _GroupTracksPageState extends State<_GroupTracksPage> {
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
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _play(int index) {
    MusicPlaybackService.instance.playQueue(_tracks, index);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicPlayerPage(queue: _tracks, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: tr('music.group.playAll'),
            icon: const Icon(Icons.play_arrow),
            onPressed: _tracks.isEmpty ? null : () => _play(0),
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
              itemBuilder: (context, i) {
                final t = _tracks[i];
                return ListTile(
                  dense: true,
                  leading: Text(
                    t.trackNo == null ? '${i + 1}' : '${t.trackNo}',
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                  title: Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      t.artist ?? '',
                      t.album ?? '',
                    ].where((x) => x.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(formatDurationMs(t.durationMs ?? 0)),
                  onTap: () => _play(i),
                );
              },
            ),
    );
  }
}

class _MusicSettingsPage extends StatefulWidget {
  const _MusicSettingsPage();

  @override
  State<_MusicSettingsPage> createState() => _MusicSettingsPageState();
}

class _MusicSettingsPageState extends State<_MusicSettingsPage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<MusicLibraryItem> _libs = const [];

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
      final res = await ApiSession.instance.client.musicLibraryList();
      if (!mounted) return;
      setState(() {
        _libs = res.items;
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

  Future<void> _scan(String id) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.musicScan(
        body: MusicScanBody(libraryId: id),
      );
      messenger.showSnackBar(SnackBar(content: Text(tr('video.nav.scanDone'))));
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        Text(
          tr('music.nav.settingsHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: NasTokens.spaceMd),
        for (final lib in _libs)
          NasCard(
            padding: const EdgeInsets.all(NasTokens.spaceSm),
            child: Row(
              children: [
                const Icon(Icons.library_music_outlined),
                const SizedBox(width: NasTokens.spaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lib.name,
                        style: TextStyle(
                          fontSize: NasTokens.fontBody,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${lib.items}',
                        style: TextStyle(
                          fontSize: NasTokens.fontCaption,
                          color: context.nasTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : () => _scan(lib.id),
                  icon: const Icon(Icons.sync, size: 16),
                  label: Text(tr('photo.source.scanAll')),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
