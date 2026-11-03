import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/scan_refresh.dart';
import '../../core/session.dart';
import 'music_playback.dart';
import 'music_player_page.dart';

/// 音乐封面地址（`NasCoverImage` 用）。以前三个类各写一份，现在走会话里的统一实现。
String _musicCover(String id) => ApiSession.instance.coverUrl('music', id);

/// 音乐：曲目 / 搜索 / 歌单 / 内嵌封面 / 播放地址（一期）。
///
/// 宽屏：左侧歌单栏 + 右侧曲目列表；窄屏：分段切换曲目与歌单。
class MusicPage extends StatefulWidget {
  const MusicPage({super.key, this.embedded = false});

  /// 嵌入音乐二级导航内容区时去掉自带 AppBar，动作按钮平铺到内容顶部
  final bool embedded;

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  static const _pageSize = 80;

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _nextCursor;
  String _query = '';

  /// 排序：字段 + 方向（服务端做，cursor 跟排序键走）
  String _sort = 'title';
  bool _desc = false;

  List<MusicTrack> _tracks = const [];
  List<MusicPlaylist> _playlists = const [];
  List<MusicLibraryItem> _libraries = const [];
  MusicStatsResponse? _stats;

  late final void Function() _unsubScan;

  @override
  void initState() {
    super.initState();
    _unsubScan = listenScanDone('music', () {
      if (mounted) _bootstrap();
    });
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _unsubScan();
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  String get _baseUrl => ApiSession.instance.baseUrl;

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || _nextCursor == null) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _loadTracks(more: true);
    }
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ApiSession.instance.client;
      final list = await client.musicList(limit: _pageSize);
      final stats = await client.musicStats();
      final libraries = await client.musicLibraryList();
      final playlists = await client.musicPlaylistList();
      if (!mounted) return;
      setState(() {
        _tracks = list.items;
        _nextCursor = list.nextCursor;
        _stats = stats;
        _libraries = libraries.items;
        _playlists = playlists.items;
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

  Future<void> _loadTracks({bool more = false}) async {
    if (more && (_loadingMore || _nextCursor == null)) return;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final res = await ApiSession.instance.client.musicList(
        q: _query.isEmpty ? null : _query,
        sort: _sort,
        order: _desc ? 'desc' : 'asc',
        cursor: more ? _nextCursor : null,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _tracks = more ? [..._tracks, ...res.items] : res.items;
        _nextCursor = res.nextCursor;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _refreshPlaylists() async {
    final client = ApiSession.instance.client;
    final res = await client.musicPlaylistList();
    if (!mounted) return;
    setState(() {
      _playlists = res.items;
    });
  }

  Future<void> _scan() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.musicScan(
        body: const MusicScanBody(),
      );
      final missing = res.missing ?? 0;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('music.scanDone', {'added': '${res.added}', 'updated': '${res.updated}', 'skipped': '${res.skipped}', 'probed': '${res.probed}'}) +
                (missing > 0 ? tr('common.missingOnDisk', {'count': '$missing'}) : ''),
          ),
          action: missing > 0
              ? SnackBarAction(
                  label: tr('ui.book.001'),
                  onPressed: () => _pruneMissing(missing),
                )
              : null,
        ),
      );
      await _bootstrap();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('common.scanFailed', {'error': '$e'}))));
    }
  }

  /// 清理「索引有、磁盘无」的曲目（服务端默认不删，需显式 prune）
  Future<void> _pruneMissing(int count) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.music.001')),
        content: Text(tr('music.pruneConfirm', {'count': '$count'})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.book.001')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await ApiSession.instance.client.musicScan(
        body: const MusicScanBody(prune: true),
      );
      messenger.showSnackBar(
        SnackBar(content: Text(tr('common.prunedRecords', {'count': '${res.pruned ?? 0}'}))),
      );
      await _bootstrap();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('common.cleanupFailed', {'error': '$e'}))));
    }
  }

  Future<void> _createLibrary() async {
    final nameCtrl = TextEditingController(text: tr('ui.music.h7f0ce4'));
    final pathCtrl = TextEditingController(text: 'music');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.music.002')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(labelText: tr('ui.book.004')),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            TextField(
              controller: pathCtrl,
              decoration: InputDecoration(
                labelText: tr('ui.book.005'),
                hintText: 'music',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.accounts.006')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiSession.instance.client.musicLibraryCreate(
        body: MusicLibraryCreateBody(
          name: nameCtrl.text.trim(),
          path: pathCtrl.text.trim(),
        ),
      );
      await _bootstrap();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.createFailed', {'error': '$e'}))));
    }
  }

  Future<void> _createPlaylist() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.music.003')),
        content: TextField(
          controller: nameCtrl,
          decoration: InputDecoration(labelText: tr('ui.music.004')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.accounts.006')),
          ),
        ],
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    try {
      await ApiSession.instance.client.musicPlaylistCreate(
        body: MusicPlaylistCreateBody(name: nameCtrl.text.trim()),
      );
      if (!mounted) return;
      await _refreshPlaylists();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.createFailed', {'error': '$e'}))));
    }
  }

  Future<void> _addToPlaylist(MusicTrack track) async {
    if (_playlists.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('ui.music.006'))));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final playlist = await showDialog<MusicPlaylist>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('ui.music.007')),
        children: [
          for (final p in _playlists)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text(p.name),
            ),
        ],
      ),
    );
    if (playlist == null) return;
    try {
      await ApiSession.instance.client.musicPlaylistAdd(
        body: MusicPlaylistMembersBody(
          playlistId: playlist.id,
          trackIds: [track.id],
        ),
      );
      messenger.showSnackBar(SnackBar(content: Text(tr('music.addedTo', {'name': playlist.name}))));
      await _refreshPlaylists();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('music.joinFailed', {'error': '$e'}))));
    }
  }

  Future<void> _copyPlayUrl(MusicTrack track) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.musicStreamUrl(id: track.id);
      await Clipboard.setData(ClipboardData(text: '$_baseUrl${res.url}'));
      messenger.showSnackBar(
        SnackBar(content: Text(tr('music.copyUrl', {'minutes': '${res.expiresInSec ~/ 60}'}))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('music.playUrlFailed', {'error': '$e'}))));
    }
  }

  void _openTrack(MusicTrack track) {
    final index = _tracks.indexWhere((t) => t.id == track.id);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TrackSheet(
        track: track,
        coverUrl: _musicCover(track.id),
        headers: ApiSession.instance.authHeaders,
        onPlay: () => _playQueue(_tracks, index < 0 ? 0 : index),
        onCopyUrl: () => _copyPlayUrl(track),
        onAddToPlaylist: () => _addToPlaylist(track),
        onShowLyrics: () => _openLyrics(track),
      ),
    );
  }

  /// 内置播放器：队列为当前列表 / 歌单，带歌词跟播高亮
  void _playQueue(List<MusicTrack> queue, int index) {
    if (queue.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicPlayerPage(queue: queue, initialIndex: index),
      ),
    );
  }

  /// 歌词：旁挂 `.lrc` 优先，其次内嵌（ID3 USLT / flac Vorbis）
  void _openLyrics(MusicTrack track) {
    showDialog<void>(
      context: context,
      builder: (_) => _LyricsDialog(track: track),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Scaffold(
          appBar: widget.embedded
              ? null
              : AppBar(
            title: Text(tr('ui.music.008')),
            actions: [
              IconButton(
                tooltip: tr('ui.music.002'),
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: _createLibrary,
              ),
              IconButton(
                tooltip: tr('ui.music.003'),
                icon: const Icon(Icons.playlist_add),
                onPressed: _createPlaylist,
              ),
              IconButton(
                tooltip: tr('ui.book.012'),
                icon: const Icon(Icons.sync),
                onPressed: _scan,
              ),
              IconButton(
                tooltip: tr('ui.accounts.021'),
                icon: const Icon(Icons.refresh),
                onPressed: _bootstrap,
              ),
            ],
          ),
          body: Column(
            children: [
              if (widget.embedded) _embeddedToolbar(),
              Expanded(
                child: _loading
              ? const NasLoading()
              : _error != null
              ? NasErrorState(message: _error!, onRetry: _bootstrap)
              : _trackPane(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _embeddedToolbar() {
    return Padding(
      padding: const EdgeInsets.only(right: NasTokens.spaceSm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            tooltip: tr('ui.music.002'),
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            onPressed: _createLibrary,
          ),
          IconButton(
            tooltip: tr('ui.music.003'),
            icon: const Icon(Icons.playlist_add, size: 18),
            onPressed: _createPlaylist,
          ),
          IconButton(
            tooltip: tr('ui.book.012'),
            icon: const Icon(Icons.sync, size: 18),
            onPressed: _scan,
          ),
          IconButton(
            tooltip: tr('ui.accounts.021'),
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _bootstrap,
          ),
        ],
      ),
    );
  }

  /// 排序菜单：字段 + 方向。此前列表写死 `title asc`，几百首的库想按"最近添加"看只能翻。
  Widget _sortMenu() {
    const labels = <String, String>{
      'title': 'music.sort.title',
      'artist': 'music.sort.artist',
      'album': 'music.sort.album',
      'created': 'music.sort.created',
      'duration': 'music.sort.duration',
      'year': 'music.sort.year',
    };
    return PopupMenuButton<String>(
      tooltip: tr('music.sort.title'),
      icon: const Icon(Icons.sort, size: 20),
      onSelected: (v) {
        if (v == 'toggle') {
          setState(() => _desc = !_desc);
        } else {
          setState(() => _sort = v);
        }
        _loadTracks();
      },
      itemBuilder: (ctx) => [
        for (final e in labels.entries)
          CheckedPopupMenuItem<String>(
            value: e.key,
            checked: _sort == e.key,
            child: Text(tr(e.value)),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'toggle',
          child: Row(
            children: [
              Icon(_desc ? Icons.arrow_downward : Icons.arrow_upward, size: 16),
              const SizedBox(width: NasTokens.spaceXs),
              Text(tr(_desc ? 'music.sort.desc' : 'music.sort.asc')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _trackPane() {
    final stats = _stats;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceMd,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: NasSearchField(
                  controller: _searchCtrl,
                  hintText: tr('ui.music.011'),
                  onClear: () {
                    setState(() => _query = '');
                    _loadTracks();
                  },
                  onSubmitted: (v) {
                    setState(() => _query = v.trim());
                    _loadTracks();
                  },
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              _sortMenu(),
              const SizedBox(width: NasTokens.spaceSm),
              Text(
                stats == null
                    ? ''
                    : tr('music.stats', {'tracks': '${stats.tracks}', 'albums': '${stats.albums}', 'artists': '${stats.artists}'}),
                style: TextStyle(
                  color: context.nasTextSecondary,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _tracks.isEmpty
              ? NasEmptyState(
                  title: _query.isEmpty
                      ? tr('ui.music.012')
                      : tr('ui.music.013'),
                  message: _libraries.isEmpty
                      ? tr('ui.music.h266f73')
                      : tr('ui.music.hea2dd3'),
                  icon: Icons.library_music_outlined,
                )
              : ListView.separated(
                  controller: _scroll,
                  itemCount: _tracks.length + (_loadingMore ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    if (i >= _tracks.length) {
                      return const Padding(
                        padding: EdgeInsets.all(NasTokens.spaceMd),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final track = _tracks[i];
                    return ListTile(
                      leading: _TrackCover(
                        url: _musicCover(track.id),
                        headers: ApiSession.instance.authHeaders,
                        size: 44,
                      ),
                      title: Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          track.artist ?? tr('ui.music.hfcc741'),
                          track.album ?? tr('ui.music.h324451'),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (track.durationMs != null)
                            Text(
                              formatDurationMs(track.durationMs!),
                              style: TextStyle(
                                color: context.nasTextSecondary,
                                fontSize: NasTokens.fontCaption,
                              ),
                            ),
                          PopupMenuButton<String>(
                            tooltip: tr('ui.mount.014'),
                            onSelected: (v) {
                              if (v == 'url') _copyPlayUrl(track);
                              if (v == 'add') _addToPlaylist(track);
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'url',
                                child: Text(tr('ui.music.014')),
                              ),
                              PopupMenuItem(
                                value: 'add',
                                child: Text(tr('ui.music.007')),
                              ),
                            ],
                          ),
                        ],
                      ),
                      onTap: () => _openTrack(track),
                    );
                  },
                ),
        ),
      ],
    );
  }

}

class _TrackCover extends StatelessWidget {
  const _TrackCover({
    required this.url,
    required this.headers,
    required this.size,
  });

  final String url;
  final Map<String, String> headers;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: NasCoverImage(
        url: url,
        headers: headers,
        cacheWidth: (size * 2).round(),
        icon: Icons.music_note,
        borderRadius: NasTokens.radiusSm,
      ),
    );
  }
}

class _TrackSheet extends StatelessWidget {
  const _TrackSheet({
    required this.track,
    required this.coverUrl,
    required this.headers,
    required this.onPlay,
    required this.onCopyUrl,
    required this.onAddToPlaylist,
    required this.onShowLyrics,
  });

  final MusicTrack track;
  final String coverUrl;
  final Map<String, String> headers;
  final VoidCallback onPlay;
  final VoidCallback onCopyUrl;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onShowLyrics;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      (tr('ui.music.h038f7a'), track.artist ?? tr('ui.book.hd9c32a')),
      (tr('ui.music.h14f4d5'), track.album ?? tr('ui.book.hd9c32a')),
      (
        tr('ui.music.hd19e86'),
        track.trackNo == null ? tr('ui.book.hd9c32a') : '${track.trackNo}',
      ),
      (
        tr('ui.music.hc668c7'),
        track.year == null ? tr('ui.book.hd9c32a') : '${track.year}',
      ),
      (
        tr('ui.music.h29d055'),
        track.durationMs == null
            ? tr('ui.book.hd9c32a')
            : formatDurationMs(track.durationMs!),
      ),
      (
        tr('ui.book.h9d2601'),
        [
          track.codec ?? tr('ui.book.hd9c32a'),
          if (track.bitrate != null) '${track.bitrate} kbps',
        ].join(' · '),
      ),
      (
        tr('ui.music.h2d84c5'),
        [
          if (track.sampleRate != null) '${track.sampleRate} Hz',
          if (track.channels != null) track.channels!,
        ].join(' · '),
      ),
      (tr('files.size'), formatBytes(track.size)),
      (tr('ui.book.025'), track.path),
    ];

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(NasTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _TrackCover(url: coverUrl, headers: headers, size: 96),
                const SizedBox(width: NasTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        style: const TextStyle(fontSize: NasTokens.fontTitle),
                      ),
                      const SizedBox(height: NasTokens.spaceXs),
                      Text(
                        [
                          track.artist ?? tr('ui.music.hfcc741'),
                          track.album ?? tr('ui.music.h324451'),
                        ].join(' · '),
                        style: TextStyle(
                          color: context.nasTextSecondary,
                          fontSize: NasTokens.fontCaption,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceMd),
            Wrap(
              spacing: NasTokens.spaceSm,
              runSpacing: NasTokens.spaceXs,
              children: [
                FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(tr('ui.music.019')),
                ),
                OutlinedButton.icon(
                  onPressed: onCopyUrl,
                  icon: const Icon(Icons.link),
                  label: Text(tr('ui.music.014')),
                ),
                OutlinedButton.icon(
                  onPressed: onShowLyrics,
                  icon: const Icon(Icons.lyrics_outlined),
                  label: Text(tr('ui.music.015')),
                ),
                OutlinedButton.icon(
                  onPressed: onAddToPlaylist,
                  icon: const Icon(Icons.playlist_add),
                  label: Text(tr('ui.music.007')),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    MusicPlaybackService.instance.enqueueNext(track);
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(tr('music.queue.nextAdded'))),
                    );
                  },
                  icon: const Icon(Icons.playlist_play),
                  label: Text(tr('music.queue.playNext')),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    MusicPlaybackService.instance.enqueue(track);
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(tr('music.queue.added'))),
                    );
                  },
                  icon: const Icon(Icons.queue_music),
                  label: Text(tr('music.queue.add')),
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceSm),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: NasTokens.spaceXs,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(
                        label,
                        style: TextStyle(
                          color: context.nasTextSecondary,
                          fontSize: NasTokens.fontCaption,
                        ),
                      ),
                    ),
                    Expanded(child: SelectableText(value)),
                  ],
                ),
              ),
            const SizedBox(height: NasTokens.spaceSm),
            Text(
              tr('ui.music.hfa69ac'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌词弹窗：旁挂 `LRC` 优先、其次内嵌（ID3 USLT / flac Vorbis comment）。
///
/// 只读浏览；逐行跟播高亮在内置播放器 [MusicPlayerPage] 里（播放器提供进度）。
class _LyricsDialog extends StatefulWidget {
  const _LyricsDialog({required this.track});

  final MusicTrack track;

  @override
  State<_LyricsDialog> createState() => _LyricsDialogState();
}

class _LyricsDialogState extends State<_LyricsDialog> {
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

class _PlaylistDetailPage extends StatefulWidget {
  const _PlaylistDetailPage({
    required this.playlist,
    required this.coverUrl,
    required this.headers,
  });

  final MusicPlaylist playlist;
  final String? coverUrl;
  final Map<String, String> headers;

  @override
  State<_PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<_PlaylistDetailPage> {
  bool _loading = true;
  String? _error;
  List<MusicTrack> _items = const [];

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
      final res = await ApiSession.instance.client.musicPlaylistItems(
        playlistId: widget.playlist.id,
        limit: 500,
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

  Future<void> _remove(MusicTrack track) async {
    try {
      await ApiSession.instance.client.musicPlaylistRemove(
        body: MusicPlaylistMembersBody(
          playlistId: widget.playlist.id,
          trackIds: [track.id],
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('music.removeFailed', {'error': '$e'}))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist.name),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              tooltip: tr('ui.music.024'),
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      MusicPlayerPage(queue: _items, initialIndex: 0),
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? NasEmptyState(
              title: tr('ui.music.017'),
              message: tr('ui.music.h3077a5'),
              icon: Icons.queue_music,
            )
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final track = _items[i];
                return ListTile(
                  title: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      track.artist ?? tr('ui.music.hfcc741'),
                      track.album ?? tr('ui.music.h324451'),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: tr('ui.music.018'),
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => _remove(track),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          MusicPlayerPage(queue: _items, initialIndex: i),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 栏目页的头部：标题 + 右侧动作（以前每个页面自己画一行，这里统一一份）。
class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: NasTokens.fontSubtitle,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 一个曲目列表（播放全部 + 点条目进播放器）。自动歌单与歌单详情共用。
class _TrackListView extends StatelessWidget {
  const _TrackListView({
    required this.tracks,
    required this.onPlayAt,
    this.trailingOf,
  });

  final List<MusicTrack> tracks;
  final void Function(int index) onPlayAt;
  final Widget? Function(MusicTrack track)? trailingOf;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: tracks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final track = tracks[i];
        return ListTile(
          leading: _TrackCover(
            url: _musicCover(track.id),
            headers: ApiSession.instance.authHeaders,
            size: 44,
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              track.artist ?? tr('ui.music.hfcc741'),
              track.album ?? tr('ui.music.h324451'),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailingOf?.call(track),
          onTap: () => onPlayAt(i),
        );
      },
    );
  }
}

/// 自动歌单（最近添加 / 最近播放 / 最常播放 / 从未播放）。
///
/// 以前挂在「歌单」页内的一个小栏里（三级菜单）；现在左侧栏直接有这四个栏目，
/// 这里只负责按 [kind] 拉服务端算好的列表。
class MusicAutoPlaylistPage extends StatefulWidget {
  const MusicAutoPlaylistPage({
    super.key,
    required this.kind,
    required this.title,
    this.embedded = false,
  });

  /// 服务端的自动歌单类型：`recent_added` / `recently_played` / `most_played` / `never_played`
  final String kind;
  final String title;

  /// 嵌在二级导航内容区里时不再画 AppBar
  final bool embedded;

  @override
  State<MusicAutoPlaylistPage> createState() => _MusicAutoPlaylistPageState();
}

class _MusicAutoPlaylistPageState extends State<MusicAutoPlaylistPage> {
  bool _loading = true;
  String? _error;
  List<MusicTrack> _items = const [];

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
      final res = await ApiSession.instance.client.musicAutoPlaylist(
        kind: widget.kind,
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

  void _playAll() {
    if (_items.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicPlayerPage(queue: _items, initialIndex: 0),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _load);
    }
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('ui.music.038'),
        message: tr('ui.music.h3077a5'),
        icon: Icons.auto_awesome,
      );
    }
    return _TrackListView(
      tracks: _items,
      onPlayAt: (i) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MusicPlayerPage(queue: _items, initialIndex: i),
        ),
      ),
      trailingOf: (track) => track.durationMs == null
          ? null
          : Text(
              formatDurationMs(track.durationMs!),
              style: TextStyle(
                color: context.nasTextSecondary,
                fontSize: NasTokens.fontCaption,
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playAll = IconButton(
      tooltip: tr('ui.music.024'),
      icon: const Icon(Icons.play_circle_outline),
      onPressed: _items.isEmpty ? null : _playAll,
    );
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [if (_items.isNotEmpty) playAll],
        ),
        body: _body(),
      );
    }
    return Column(
      children: [
        _PaneHeader(title: widget.title, trailing: playAll),
        Expanded(child: _body()),
      ],
    );
  }
}

/// 我的歌单：左侧栏「歌单」栏目 → 列表 + 新建 + 删除。
class MusicPlaylistsPage extends StatefulWidget {
  const MusicPlaylistsPage({super.key, this.onPlaylistsChanged});

  /// 歌单增删后通知外层（曲目页的「加入歌单」菜单要跟着变）
  final VoidCallback? onPlaylistsChanged;

  @override
  State<MusicPlaylistsPage> createState() => _MusicPlaylistsPageState();
}

class _MusicPlaylistsPageState extends State<MusicPlaylistsPage> {
  bool _loading = true;
  String? _error;
  List<MusicPlaylist> _items = const [];

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
      final res = await ApiSession.instance.client.musicPlaylistList();
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

  Future<void> _create() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.music.003')),
        content: TextField(
          controller: nameCtrl,
          decoration: InputDecoration(labelText: tr('ui.music.004')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.accounts.006')),
          ),
        ],
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    try {
      await ApiSession.instance.client.musicPlaylistCreate(
        body: MusicPlaylistCreateBody(name: nameCtrl.text.trim()),
      );
      if (!mounted) return;
      await _load();
      widget.onPlaylistsChanged?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('common.createFailed', {'error': '$e'}))),
      );
    }
  }

  Future<void> _delete(MusicPlaylist playlist) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.music.005')),
        content: Text(tr('music.deleteConfirm', {'name': playlist.name})),
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
      await ApiSession.instance.client.musicPlaylistDelete(
        body: MusicPlaylistDeleteBody(playlistId: playlist.id),
      );
      if (!mounted) return;
      await _load();
      widget.onPlaylistsChanged?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('common.deleteFailed', {'error': '$e'}))),
      );
    }
  }

  Future<void> _open(MusicPlaylist playlist) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _PlaylistDetailPage(
          playlist: playlist,
          coverUrl: playlist.coverTrackId == null
              ? null
              : _musicCover(playlist.coverTrackId!),
          headers: ApiSession.instance.authHeaders,
        ),
      ),
    );
    await _load();
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _load);
    }
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('ui.music.006'),
        message: tr('ui.music.h3077a5'),
        icon: Icons.queue_music,
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final playlist = _items[i];
        return ListTile(
          leading: playlist.coverTrackId == null
              ? const Icon(Icons.queue_music)
              : _TrackCover(
                  url: _musicCover(playlist.coverTrackId!),
                  headers: ApiSession.instance.authHeaders,
                  size: 44,
                ),
          title: Text(playlist.name),
          subtitle: Text(tr('ui.music.039', {'n': playlist.tracks})),
          trailing: IconButton(
            tooltip: tr('ui.music.005'),
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(playlist),
          ),
          onTap: () => _open(playlist),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PaneHeader(
          title: tr('ui.music.030'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('ui.music.003'),
                icon: const Icon(Icons.playlist_add),
                onPressed: _create,
              ),
              IconButton(
                tooltip: tr('ui.accounts.021'),
                icon: const Icon(Icons.refresh),
                onPressed: _load,
              ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }
}
