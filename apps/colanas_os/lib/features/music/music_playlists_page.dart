import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import '../sync/sync_remote_dir_picker.dart';
import 'music_track_view.dart';

/// 歌单 · 我的歌单：卡片网格 + 新建 / 重命名 / 删除。
///
/// 卡片样式对齐参考实现：封面铺满、底部渐变压一层名字与曲目数，右上角「更多」。
class MusicPlaylistsPage extends StatefulWidget {
  const MusicPlaylistsPage({super.key, this.embedded = true});

  final bool embedded;

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
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final name = await _promptName(
      title: tr('ui.music.003'),
      label: tr('ui.music.004'),
    );
    if (name == null || !mounted) return;
    try {
      await ApiSession.instance.client.musicPlaylistCreate(
        body: MusicPlaylistCreateBody(name: name),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.createFailed', {'error': '$e'}));
    }
  }

  Future<void> _rename(MusicPlaylist playlist) async {
    final name = await _promptName(
      title: tr('music.playlist.rename'),
      label: tr('ui.music.004'),
      initial: playlist.name,
    );
    if (name == null || !mounted) return;
    try {
      await ApiSession.instance.client.musicPlaylistRename(
        body: MusicPlaylistRenameBody(playlistId: playlist.id, name: name),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.error'));
    }
  }

  Future<String?> _promptName({
    required String title,
    required String label,
    String initial = '',
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('common.confirm')),
          ),
        ],
      ),
    );
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
    if (ok != true || !mounted) return;
    try {
      await ApiSession.instance.client.musicPlaylistDelete(
        body: MusicPlaylistDeleteBody(playlistId: playlist.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  Future<void> _open(MusicPlaylist playlist) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicPlaylistDetailPage(playlist: playlist),
      ),
    );
    await _load();
  }

  List<NasMenuEntry> _menuFor(MusicPlaylist p) => [
    NasMenuEntry(
      label: tr('common.open'),
      icon: Icons.queue_music,
      onSelected: () => _open(p),
    ),
    NasMenuEntry(
      label: tr('music.playlist.rename'),
      icon: Icons.edit_outlined,
      onSelected: () => _rename(p),
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('common.delete'),
      icon: Icons.delete_outline,
      danger: true,
      onSelected: () => _delete(p),
    ),
  ];

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return NasEmptyState(title: tr('ui.music.006'), icon: Icons.queue_music);
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
              final compact = constraints.crossAxisExtent < 750;
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: compact ? 1 : 3,
                  crossAxisSpacing: NasTokens.spaceSm,
                  mainAxisSpacing: NasTokens.spaceSm,
                  childAspectRatio: 1.8,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _PlaylistCard(
                    playlist: _items[i],
                    menuEntries: _menuFor(_items[i]),
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
    final body = Column(
      children: [
        MusicPaneHeader(
          title: tr('ui.music.030'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('ui.music.003'),
                icon: const Icon(Icons.playlist_add),
                onPressed: _create,
              ),
              NasRefreshButton(onPressed: _load),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('ui.music.030'))),
      body: body,
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    required this.playlist,
    required this.menuEntries,
    required this.onTap,
  });

  final MusicPlaylist playlist;
  final List<NasMenuEntry> menuEntries;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (playlist.coverTrackId != null)
            NasCoverImage(
              url: musicCoverUrl(playlist.coverTrackId!),
              headers: ApiSession.instance.authHeaders,
              cacheWidth: 480,
              icon: Icons.queue_music,
              borderRadius: 0,
            )
          else
            ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Icon(
                Icons.queue_music,
                size: 36,
                color: context.nasTextSecondary,
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
                stops: [0.45, 1],
              ),
            ),
          ),
          Positioned(
            left: NasTokens.spaceSm,
            right: 40,
            bottom: NasTokens.spaceSm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('ui.music.039', {'n': '${playlist.tracks}'}),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: _CardMenuButton(entries: menuEntries),
          ),
        ],
      ),
    );
    return NasContextMenuRegion(
      entries: menuEntries,
      child: GestureDetector(onTap: onTap, child: card),
    );
  }
}

class _CardMenuButton extends StatelessWidget {
  const _CardMenuButton({required this.entries});

  final List<NasMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          ),
        ),
      ),
      menuChildren: [
        for (final e in entries)
          if (e.isDivider)
            const Divider(height: 1)
          else
            MenuItemButton(
              leadingIcon: e.icon == null
                  ? null
                  : Icon(
                      e.icon,
                      size: NasTokens.iconSm,
                      color: e.danger ? scheme.error : scheme.onSurface,
                    ),
              onPressed: e.onSelected,
              child: Text(e.label),
            ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: tr('common.more'),
        icon: const Icon(Icons.more_horiz, color: Colors.white),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// 歌单详情：曲目列表 + 整单播放 + 移出歌单。
class MusicPlaylistDetailPage extends StatefulWidget {
  const MusicPlaylistDetailPage({super.key, required this.playlist});

  final MusicPlaylist playlist;

  @override
  State<MusicPlaylistDetailPage> createState() =>
      _MusicPlaylistDetailPageState();
}

class _MusicPlaylistDetailPageState extends State<MusicPlaylistDetailPage> {
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
        _error = '$e';
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
      NasSnack.show(context, tr('music.removeFailed', {'error': '$e'}));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist.name),
        actions: [
          IconButton(
            tooltip: tr('ui.music.024'),
            icon: const Icon(Icons.play_circle_outline),
            onPressed: _items.isEmpty
                ? null
                : () => musicPlayTracks(context, _items, 0),
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
              itemBuilder: (context, i) => MusicTrackRow(
                track: _items[i],
                onPlay: () => musicPlayTracks(context, _items, i),
                trailing: IconButton(
                  tooltip: tr('ui.music.018'),
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _remove(_items[i]),
                ),
              ),
            ),
    );
  }
}

/// 歌单 · 合集：用户自建的一组音乐目录（新放进去的歌自动进来）。
class MusicCollectionsPage extends StatefulWidget {
  const MusicCollectionsPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<MusicCollectionsPage> createState() => _MusicCollectionsPageState();
}

class _MusicCollectionsPageState extends State<MusicCollectionsPage> {
  bool _loading = true;
  String? _error;
  List<MusicCollection> _items = const [];

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
      final res = await ApiSession.instance.client.musicCollectionList();
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

  Future<void> _create() async {
    final draft = await _editDialog();
    if (draft == null || !mounted) return;
    try {
      await ApiSession.instance.client.musicCollectionCreate(
        body: MusicCollectionBody(name: draft.name, paths: draft.paths),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.createFailed', {'error': '$e'}));
    }
  }

  Future<void> _edit(MusicCollection collection) async {
    final draft = await _editDialog(existing: collection);
    if (draft == null || !mounted) return;
    try {
      await ApiSession.instance.client.musicCollectionUpdate(
        body: MusicCollectionUpdateBody(
          id: collection.id,
          name: draft.name,
          paths: draft.paths,
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.error'));
    }
  }

  Future<void> _delete(MusicCollection collection) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Text(
          tr('music.collection.deleteConfirm', {'name': collection.name}),
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
    if (ok != true || !mounted) return;
    try {
      await ApiSession.instance.client.musicCollectionRemove(
        body: MusicLibraryRemoveBody(id: collection.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  Future<void> _open(MusicCollection collection) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicCollectionDetailPage(collection: collection),
      ),
    );
    await _load();
  }

  Future<_CollectionDraft?> _editDialog({MusicCollection? existing}) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final paths = <String>[...?existing?.paths];
    return showDialog<_CollectionDraft>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(
            existing == null
                ? tr('music.collection.create')
                : tr('music.collection.edit'),
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: tr('music.collection.name'),
                    hintText: tr('music.collection.nameHint'),
                  ),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                Text(
                  tr('music.collection.paths'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: NasTokens.spaceXs),
                if (paths.isEmpty)
                  Text(
                    tr('music.collection.noPath'),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  for (final p in paths)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            p,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: tr('common.delete'),
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setLocal(() => paths.remove(p)),
                        ),
                      ],
                    ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final picked = await showSyncRemoteDirPicker(ctx);
                      if (picked == null || picked.isEmpty) return;
                      if (!paths.contains(picked)) {
                        setLocal(() => paths.add(picked));
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: Text(tr('music.collection.addPath')),
                  ),
                ),
                const SizedBox(height: NasTokens.spaceXs),
                Text(
                  tr('music.collection.pathsHint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty || paths.isEmpty) return;
                Navigator.pop(
                  ctx,
                  _CollectionDraft(name: name, paths: [...paths]),
                );
              },
              child: Text(tr('common.confirm')),
            ),
          ],
        ),
      ),
    );
  }

  List<NasMenuEntry> _menuFor(MusicCollection c) => [
    NasMenuEntry(
      label: tr('common.open'),
      icon: Icons.collections_bookmark_outlined,
      onSelected: () => _open(c),
    ),
    NasMenuEntry(
      label: tr('music.collection.edit'),
      icon: Icons.edit_outlined,
      onSelected: () => _edit(c),
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('common.delete'),
      icon: Icons.delete_outline,
      danger: true,
      onSelected: () => _delete(c),
    ),
  ];

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('music.collection.empty'),
        message: tr('music.collection.emptyHint'),
        icon: Icons.collections_bookmark_outlined,
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
              final compact = constraints.crossAxisExtent < 750;
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: compact ? 1 : 3,
                  crossAxisSpacing: NasTokens.spaceSm,
                  mainAxisSpacing: NasTokens.spaceSm,
                  childAspectRatio: 1.8,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _CollectionCard(
                    collection: _items[i],
                    menuEntries: _menuFor(_items[i]),
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
    final body = Column(
      children: [
        MusicPaneHeader(
          title: tr('music.collection.title'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('music.collection.create'),
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: _create,
              ),
              NasRefreshButton(onPressed: _load),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('music.collection.title'))),
      body: body,
    );
  }
}

class _CollectionDraft {
  const _CollectionDraft({required this.name, required this.paths});

  final String name;
  final List<String> paths;
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.collection,
    required this.menuEntries,
    required this.onTap,
  });

  final MusicCollection collection;
  final List<NasMenuEntry> menuEntries;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (collection.coverTrackId != null)
            NasCoverImage(
              url: musicCoverUrl(collection.coverTrackId!),
              headers: ApiSession.instance.authHeaders,
              cacheWidth: 480,
              icon: Icons.collections_bookmark_outlined,
              borderRadius: 0,
            )
          else
            ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Icon(
                Icons.collections_bookmark_outlined,
                size: 36,
                color: context.nasTextSecondary,
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
                stops: [0.45, 1],
              ),
            ),
          ),
          Positioned(
            left: NasTokens.spaceSm,
            right: 40,
            bottom: NasTokens.spaceSm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  collection.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('ui.music.039', {'n': '${collection.tracks}'}),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: _CardMenuButton(entries: menuEntries),
          ),
        ],
      ),
    );
    return NasContextMenuRegion(
      entries: menuEntries,
      child: GestureDetector(onTap: onTap, child: card),
    );
  }
}

/// 合集详情：目录里的曲目（整组播放）。
class MusicCollectionDetailPage extends StatefulWidget {
  const MusicCollectionDetailPage({super.key, required this.collection});

  final MusicCollection collection;

  @override
  State<MusicCollectionDetailPage> createState() =>
      _MusicCollectionDetailPageState();
}

class _MusicCollectionDetailPageState extends State<MusicCollectionDetailPage> {
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
      final res = await ApiSession.instance.client.musicCollectionItems(
        id: widget.collection.id,
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
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.collection.name),
        actions: [
          IconButton(
            tooltip: tr('ui.music.024'),
            icon: const Icon(Icons.play_circle_outline),
            onPressed: _items.isEmpty
                ? null
                : () => musicPlayTracks(context, _items, 0),
          ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? NasEmptyState(
              title: tr('music.collection.empty'),
              message: tr('music.collection.emptyHint'),
              icon: Icons.collections_bookmark_outlined,
            )
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => MusicTrackRow(
                track: _items[i],
                onPlay: () => musicPlayTracks(context, _items, i),
              ),
            ),
    );
  }
}
