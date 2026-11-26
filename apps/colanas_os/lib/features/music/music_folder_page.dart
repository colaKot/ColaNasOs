import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/mobile_frame.dart';
import '../../shell/shell_back.dart';
import 'music_track_view.dart';

/// 音乐 · 文件夹。
///
/// 全程在音乐壳的内容区里逐层下钻（**不开整页窗口**）：左侧一二级栏、
/// 底部播放条都还在，返回按钮由 `SubPageScope` 注册到顶栏（桌面右上 / 手机左上），
/// 和「专辑 → 详情」是同一套三级形态。
///
/// 层级：音乐来源 → 子目录 → … → 当前层曲目。面包屑随时可以跳回任意一层。
/// 列表 / 网格随时切换（网格按封面认歌，列表看曲号与专辑）。
class MusicFolderPage extends StatefulWidget {
  const MusicFolderPage({super.key});

  @override
  State<MusicFolderPage> createState() => _MusicFolderPageState();
}

/// 下钻的一层。`dir` 是库内相对目录，空串表示库根。
class _FolderLevel {
  const _FolderLevel({
    required this.libraryId,
    required this.libraryName,
    required this.dir,
  });

  final String libraryId;
  final String libraryName;
  final String dir;

  /// 走完 `<库名>/<dir 各段>` 之后这一层显示的名字
  String get title {
    final segs = dir.split('/').where((s) => s.isNotEmpty).toList();
    return segs.isEmpty ? libraryName : segs.last;
  }
}

class _MusicFolderPageState extends State<MusicFolderPage> {
  /// 空 = 还在第一层（来源列表）
  final List<_FolderLevel> _stack = <_FolderLevel>[];

  /// `list` / `grid`
  String _view = 'list';

  bool _loading = true;
  String? _error;

  List<MusicLibraryItem> _libraries = const [];
  List<MusicFolderEntry> _dirs = const [];
  List<MusicTrack> _files = const [];

  bool _selecting = false;
  final Set<String> _selected = <String>{};

  _FolderLevel? get _level => _stack.isEmpty ? null : _stack.last;

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
    final level = _level;
    try {
      if (level == null) {
        final res = await ApiSession.instance.client.musicLibraryList();
        if (!mounted) return;
        setState(() {
          _libraries = res.items;
          _dirs = const [];
          _files = const [];
          _loading = false;
        });
        return;
      }
      final res = await ApiSession.instance.client.musicFolders(
        libraryId: level.libraryId,
        dir: level.dir,
      );
      if (!mounted) return;
      setState(() {
        _dirs = res.items;
        _files = res.files;
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

  void _open(_FolderLevel level) {
    setState(() {
      _stack.add(level);
      _dirs = const [];
      _files = const [];
      _selecting = false;
      _selected.clear();
    });
    _load();
  }

  /// 面包屑跳转到第 [index] 层（0 = 来源列表）
  void _jumpTo(int index) {
    if (index >= _stack.length) return;
    setState(() {
      _stack.removeRange(index, _stack.length);
      _dirs = const [];
      _files = const [];
      _selecting = false;
      _selected.clear();
    });
    _load();
  }

  /// 顶栏返回：退一层。多选状态下先退出多选 —— 顶栏只有一个返回，
  /// 从多选直接跳回上一层会让人以为刚勾的东西没了。
  void _back() {
    if (_selecting) {
      setState(() {
        _selecting = false;
        _selected.clear();
      });
      return;
    }
    if (_stack.isEmpty) return;
    _jumpTo(_stack.length - 1);
  }

  void _toggleSelectMode() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  void _toggleOne(MusicTrack track) {
    setState(() {
      if (!_selected.remove(track.id)) _selected.add(track.id);
    });
  }

  void _selectAll() {
    setState(() {
      if (_selected.length == _files.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_files.map((t) => t.id));
      }
    });
  }

  Future<void> _addToPlaylist() async {
    if (_selected.isEmpty) return;
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
        title: Text(tr('music.folder.addToPlaylist')),
        children: [
          for (final p in playlists.items)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text(p.name),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    try {
      await ApiSession.instance.client.musicPlaylistAdd(
        body: MusicPlaylistMembersBody(
          playlistId: target.id,
          trackIds: _selected.toList(),
        ),
      );
      NasSnack.showOn(messenger, tr('music.addedTo', {'name': target.name}));
      if (mounted) {
        setState(() {
          _selecting = false;
          _selected.clear();
        });
      }
    } catch (e) {
      NasSnack.showOn(messenger, tr('music.joinFailed', {'error': '$e'}));
    }
  }

  /// 封面走带令牌的兼容口：内嵌封面抽不到时会去在线源兜底，
  /// 与列表页、搜索结果口径一致（直连的封面接口要 Authorization，系统取图不带）。
  String _coverUrl(MusicTrack track) {
    final path = track.path.trim();
    if (path.isEmpty) return '';
    return '${ApiSession.instance.baseUrl}/api/v1/music/compat/cover'
        '?path=${Uri.encodeQueryComponent(path)}&size=320';
  }

  @override
  Widget build(BuildContext context) {
    return SubPageScope(
      active: _stack.isNotEmpty,
      onBack: _back,
      child: NasSelectionOverlay(
        bar: _selecting && _selected.isNotEmpty ? _selectBar() : null,
        child: Column(
          children: [
            _toolbar(context),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = isCompactWidth(context);
    final level = _level;

    // 面包屑：来源 / 库名 / 各层目录
    final crumbs = <Widget>[
      _crumb(context, tr('music.nav.sources'), _stack.isEmpty, () => _jumpTo(0)),
      if (level != null) ...[
        const _CrumbSep(),
        _crumb(
          context,
          level.libraryName,
          _stack.length == 1,
          () => _jumpTo(1),
        ),
        for (var i = 0; i < _stack.length; i++)
          if (_stack[i].dir.isNotEmpty) ...[
            const _CrumbSep(),
            _crumb(
              context,
              _stack[i].title,
              i == _stack.length - 1,
              () => _jumpTo(i + 1),
            ),
          ],
      ],
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceXs,
        NasTokens.spaceSm,
        0,
      ),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: crumbs,
              ),
            ),
            if (!compact && !_loading && _files.isNotEmpty) ...[
              Text(
                tr('music.folder.tracks', {'count': '${_files.length}'}),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
            ],
            if (!_loading && _level != null && _files.isNotEmpty)
              NasIconAction(
                icon: _selecting ? Icons.close : Icons.checklist,
                tooltip: _selecting
                    ? tr('common.close')
                    : tr('music.folder.select'),
                onPressed: _toggleSelectMode,
              ),
            NasIconAction(
              icon: Icons.refresh,
              tooltip: tr('common.refresh'),
              onPressed: _load,
            ),
            const SizedBox(width: NasTokens.spaceXs),
            // 网格 / 列表：窄屏只给一个切换图标，宽屏给分段控件
            if (compact)
              NasIconAction(
                icon: _view == 'list'
                    ? Icons.grid_view_rounded
                    : Icons.view_list_rounded,
                tooltip: _view == 'list'
                    ? tr('files.view.grid')
                    : tr('files.view.list'),
                onPressed: () =>
                    setState(() => _view = _view == 'list' ? 'grid' : 'list'),
              )
            else
              SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  ButtonSegment(
                    value: 'list',
                    icon: const Icon(Icons.view_list_rounded, size: 18),
                    label: Text(tr('files.view.list')),
                  ),
                  ButtonSegment(
                    value: 'grid',
                    icon: const Icon(Icons.grid_view_rounded, size: 18),
                    label: Text(tr('files.view.grid')),
                  ),
                ],
                selected: {_view},
                onSelectionChanged: (s) => setState(() => _view = s.first),
              ),
          ],
        ),
      ),
    );
  }

  Widget _crumb(
    BuildContext context,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: active ? null : onTap,
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NasTokens.spaceSm,
          vertical: 6,
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontBody,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectBar() {
    return NasSelectionFloatingBar(
      title: tr('music.folder.selected', {'count': '${_selected.length}'}),
      allSelected: _files.isNotEmpty && _selected.length == _files.length,
      onToggleAll: _selectAll,
      onClose: _toggleSelectMode,
      actions: [
        NasSelectionAction(
          label: tr('music.folder.addToPlaylist'),
          icon: Icons.playlist_add,
          onPressed: _addToPlaylist,
        ),
      ],
    );
  }

  /// 播放条是壳里的覆盖层，列表底部留够高度，最后一行才不会被压住
  EdgeInsets get _contentPadding => const EdgeInsets.only(
    left: NasTokens.spaceXs,
    right: NasTokens.spaceXs,
    bottom: NasTokens.spaceXl + 72,
  );

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_level == null) {
      if (_libraries.isEmpty) {
        return NasEmptyState(
          title: tr('music.folder.noSource'),
          message: tr('music.folder.noSourceHint'),
          icon: Icons.folder_open,
        );
      }
      return _libraryList();
    }
    if (_dirs.isEmpty && _files.isEmpty) {
      return NasEmptyState(
        title: tr('music.folder.empty'),
        icon: Icons.folder_open,
      );
    }
    return _view == 'grid' ? _grid() : _list();
  }

  Widget _libraryList() {
    return ListView.separated(
      padding: _contentPadding,
      itemCount: _libraries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final lib = _libraries[i];
        return ListTile(
          leading: Icon(
            Icons.folder_special_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(lib.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${lib.path} · ${tr('music.folder.tracks', {'count': '${lib.items}'})}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(
            _FolderLevel(libraryId: lib.id, libraryName: lib.name, dir: ''),
          ),
        );
      },
    );
  }

  Widget _list() {
    return ListView(
      padding: _contentPadding,
      children: [
        for (final d in _dirs)
          ListTile(
            leading: Icon(
              Icons.folder,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(tr('music.folder.tracks', {'count': '${d.tracks}'})),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(
              _FolderLevel(
                libraryId: _level!.libraryId,
                libraryName: _level!.libraryName,
                dir: d.path,
              ),
            ),
          ),
        if (_dirs.isNotEmpty && _files.isNotEmpty) const Divider(height: 1),
        for (var i = 0; i < _files.length; i++)
          MusicTrackRow(
            track: _files[i],
            leading: _selecting
                ? Checkbox(
                    value: _selected.contains(_files[i].id),
                    onChanged: (_) => _toggleOne(_files[i]),
                  )
                : null,
            onPlay: () {
              if (_selecting) {
                _toggleOne(_files[i]);
              } else {
                musicPlayTracks(context, _files, i);
              }
            },
          ),
      ],
    );
  }

  Widget _grid() {
    final dirCount = _dirs.length;
    return GridView.builder(
      padding: _contentPadding,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: NasTokens.spaceSm,
        crossAxisSpacing: NasTokens.spaceSm,
        childAspectRatio: 0.74,
      ),
      itemCount: dirCount + _files.length,
      itemBuilder: (context, index) {
        if (index < dirCount) return _dirCard(_dirs[index]);
        final i = index - dirCount;
        return _trackCard(_files[i], i);
      },
    );
  }

  Widget _dirCard(MusicFolderEntry d) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      onTap: () => _open(
        _FolderLevel(
          libraryId: _level!.libraryId,
          libraryName: _level!.libraryName,
          dir: d.path,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: context.nasStyle.panelColor,
                borderRadius: BorderRadius.circular(NasTokens.radiusMd),
              ),
              child: Icon(
                Icons.folder_rounded,
                size: 44,
                color: scheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            d.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: NasTokens.fontBody,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            tr('music.folder.tracks', {'count': '${d.tracks}'}),
            maxLines: 1,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _trackCard(MusicTrack track, int index) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected.contains(track.id);
    final cover = _coverUrl(track);
    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      onTap: () {
        if (_selecting) {
          _toggleOne(track);
        } else {
          musicPlayTracks(context, _files, index);
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(NasTokens.radiusMd),
                  child: cover.isEmpty
                      ? Container(
                          color: context.nasStyle.panelColor,
                          child: const Icon(Icons.music_note, size: 32),
                        )
                      : NasCoverImage(
                          url: cover,
                          headers: ApiSession.instance.authHeaders,
                          borderRadius: NasTokens.radiusMd,
                          cacheWidth: 320,
                          fallbackText: track.title,
                        ),
                ),
                if (_selecting)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surface.withValues(alpha: 0.86),
                        shape: BoxShape.circle,
                      ),
                      child: Checkbox(
                        value: selected,
                        visualDensity: VisualDensity.compact,
                        onChanged: (_) => _toggleOne(track),
                      ),
                    ),
                  ),
                if (_selecting && selected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            NasTokens.radiusMd,
                          ),
                          border: Border.all(color: scheme.primary, width: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: NasTokens.fontBody,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            (track.artist ?? '').trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _CrumbSep extends StatelessWidget {
  const _CrumbSep();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.chevron_right,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
