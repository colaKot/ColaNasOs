import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/file_shortcuts.dart';
import '../../core/session.dart';
import '../../shell/app_nav_shell.dart';

/// 文件浏览：面包屑下钻 / 返回上级，列表与网格两种视图（同一份数据）。
///
/// 视觉层用 [NasFileTile]（按扩展名给类型色），不再是裸 [ListTile] + 分割线，
/// 这样与侧栏/工作台是同一套材质，切换风格时自动跟随。
class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  String _path = '/';
  bool _loading = true;
  String? _error;
  List<FilesListItem> _items = const [];

  /// 视图：`list` / `grid`
  String _view = 'list';

  /// 手机端底部 tab：`browse`（文件夹）/ `favorites` / `recent`。
  /// 桌面端不用它 —— 桌面有侧栏与面包屑，一屏就能看完。
  String _mobileTab = 'browse';

  final _shortcuts = FileShortcuts.instance;

  @override
  void initState() {
    super.initState();
    _shortcuts.ensureLoaded();
    _shortcuts.addListener(_onShortcutsChanged);
    _load();
  }

  @override
  void dispose() {
    _shortcuts.removeListener(_onShortcutsChanged);
    super.dispose();
  }

  void _onShortcutsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.filesList(path: _path);
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _path = res.path.isEmpty ? _path : res.path;
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

  /// 当前目录 + 条目名 → 完整路径（收藏/最近都用它当 key）
  String _fullPathOf(FilesListItem item) {
    final base = _path == '/' ? '' : _path.replaceFirst(RegExp(r'/+$'), '');
    return '$base/${item.name}';
  }

  void _open(FilesListItem item) {
    if (!item.dir) return;
    final target = _fullPathOf(item);
    // 进目录才记「最近」——根视图（_path == '/'）不进列表，否则一打开就占一条
    _shortcuts.recordRecent(FileShortcut(path: target, name: item.name));
    _path = target;
    _load();
  }

  /// 收藏 / 取消收藏（只有目录能收藏：文件在这个页面没有预览入口，
  /// 收藏了也点不开，等于给用户一个死链）
  Future<void> _toggleFavorite(FilesListItem item) async {
    if (!item.dir) return;
    final messenger = ScaffoldMessenger.of(context);
    final added = await _shortcuts.toggleFavorite(
      FileShortcut(path: _fullPathOf(item), name: item.name),
    );
    if (!mounted) return;
    NasSnack.showOn(
      messenger,
      tr(added ? 'files.favorite.added' : 'files.favorite.removed'),
    );
  }

  void _up() {
    if (_path == '/' || _path.isEmpty) return;
    final idx = _path.lastIndexOf('/');
    _path = idx <= 0 ? '/' : _path.substring(0, idx);
    _load();
  }

  void _jumpTo(String path) {
    _path = path.isEmpty ? '/' : path;
    _load();
  }

  // ---------------------------------------------------------------- 写操作
  // 文件域此前只能看 / 传 / 下载。写操作全部走 files:write 接口，
  // 删除默认进回收站（服务端 `permanent` 缺省为 false），不直接抹盘。

  /// 当前目录 + 条目名 → 相对 files 根的路径
  String _relOf(FilesListItem item) {
    final base = _path == '/' ? '' : _path.replaceFirst(RegExp(r'^/+'), '');
    return base.isEmpty ? item.name : '$base/${item.name}';
  }

  /// 当前目录下的新条目相对路径
  String _relInCurrent(String name) {
    final base = _path == '/' ? '' : _path.replaceFirst(RegExp(r'^/+'), '');
    return base.isEmpty ? name : '$base/$name';
  }

  Future<String?> _promptName({required String title, required String initial}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('files.nameHint')),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('common.confirm')),
          ),
        ],
      ),
    );
  }

  Future<void> _mkdir() async {
    final name = await _promptName(title: tr('files.newFolder'), initial: '');
    if (name == null || name.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.filesMkdir(body: FilesOpPathBody(path: _relInCurrent(name)));
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  Future<void> _rename(FilesListItem item) async {
    final name = await _promptName(title: tr('files.rename'), initial: item.name);
    if (name == null || name.isEmpty || name == item.name || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.filesRename(
        body: FilesRenameBody(path: _relOf(item), name: name),
      );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  Future<void> _delete(FilesListItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('files.delete')),
        content: Text(tr('files.deleteConfirm', {'name': item.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('files.delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.filesDelete(
        body: FilesDeleteBody(paths: [_relOf(item)]),
      );
      if (!mounted) return;
      final failed = res.failed;
      NasSnack.showOn(messenger, 
            failed.isEmpty ? tr('files.deletedToTrash') : failed.first.error,
          );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  /// 行内「⋯」菜单：重命名 / 删除
  /// 右键菜单（桌面 / Web）：与条目菜单 / 网格长按同一批动作。
  List<NasMenuEntry> _fileMenuEntries(FilesListItem item) {
    final fav = _shortcuts.isFavorite(_fullPathOf(item));
    return [
      if (item.dir)
        NasMenuEntry(
          label: tr('common.open'),
          icon: Icons.folder_open_outlined,
          onSelected: () => _open(item),
        ),
      if (item.dir)
        NasMenuEntry(
          label: tr(fav ? 'files.favorite.remove' : 'files.favorite.add'),
          icon: fav ? Icons.star : Icons.star_outline,
          onSelected: () => _toggleFavorite(item),
        ),
      NasMenuEntry(
        label: tr('files.rename'),
        icon: Icons.drive_file_rename_outline,
        onSelected: () => _rename(item),
      ),
      const NasMenuEntry.divider(),
      NasMenuEntry(
        label: tr('files.delete'),
        icon: Icons.delete_outline,
        danger: true,
        onSelected: () => _delete(item),
      ),
    ];
  }

  Widget _itemMenu(FilesListItem item) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      tooltip: '',
      onSelected: (v) {
        if (v == 'favorite') _toggleFavorite(item);
        if (v == 'rename') _rename(item);
        if (v == 'delete') _delete(item);
      },
      itemBuilder: (_) => [
        if (item.dir)
          PopupMenuItem(
            value: 'favorite',
            child: Text(
              tr(
                _shortcuts.isFavorite(_fullPathOf(item))
                    ? 'files.favorite.remove'
                    : 'files.favorite.add',
              ),
            ),
          ),
        PopupMenuItem(value: 'rename', child: Text(tr('files.rename'))),
        PopupMenuItem(value: 'delete', child: Text(tr('files.delete'))),
      ],
    );
  }

  /// 网格视图没有 trailing，用长按出菜单
  Future<void> _gridMenu(FilesListItem item) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.dir)
              ListTile(
                leading: Icon(
                  _shortcuts.isFavorite(_fullPathOf(item))
                      ? Icons.star
                      : Icons.star_outline,
                ),
                title: Text(
                  tr(
                    _shortcuts.isFavorite(_fullPathOf(item))
                        ? 'files.favorite.remove'
                        : 'files.favorite.add',
                  ),
                ),
                onTap: () => Navigator.pop(ctx, 'favorite'),
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: Text(tr('files.rename')),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(tr('files.delete')),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (picked == 'favorite') await _toggleFavorite(item);
    if (picked == 'rename') await _rename(item);
    if (picked == 'delete') await _delete(item);
  }

  /// 按路径关键词搜索**已索引**的文件（先点「索引」；索引走后台任务）。
  Future<void> _search() async {
    final ctrl = TextEditingController();
    final keyword = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.search')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('files.path')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('common.search')),
          ),
        ],
      ),
    );
    if (keyword == null || keyword.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.filesSearch(q: keyword);
      final items = ((res['items'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (m) => (
              path: '${m['path'] ?? ''}',
              size: (m['size'] as num?)?.toInt() ?? 0,
            ),
          )
          .toList();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(keyword),
          content: SizedBox(
            width: 520,
            height: 360,
            child: items.isEmpty
                ? Center(child: Text(tr('common.empty')))
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final item = items[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text(item.path),
                        subtitle: Text(formatBytes(item.size)),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.close')),
            ),
          ],
        ),
      );
    } catch (e) {
      NasSnack.showOn(messenger, '${tr('common.error')}：$e');
    }
  }

  /// 触发索引（后台任务；完成后搜索才有结果）
  Future<void> _index() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.filesIndex();
      final taskId = res['taskId']?.toString() ?? '';
      final reused = res['reused'] == true;
      NasSnack.showOn(messenger, 
            reused
                ? tr('ui.files.h439f15')
                : '${tr('home.quick.index')}：$taskId',
          );
    } catch (e) {
      NasSnack.showOn(messenger, '${tr('common.error')}：$e');
    }
  }

  List<String> get _segments =>
      _path.split('/').where((s) => s.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = layoutFor(constraints.maxWidth) == LayoutMode.compact;
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(compact),
            const SizedBox(height: NasTokens.spaceSm),
            Expanded(child: _content(constraints.maxWidth)),
          ],
        );
        // 手机端：文件页是单页模块，需要自己的 56 顶栏（房子 + 标题）。
        // 桌面由 AppShell 的 NasTopBar 提供标题，这里不再叠一层。
        if (!compact) return content;
        // 手机端底部三个 tab 与参考实现一致：文件夹 / 收藏 / 最近。
        // 收藏与最近**只存本机**（见 core/file_shortcuts.dart）
        return NasAppScaffold(
          title: tr('app.files'),
          onHome: AppNavShell.onExitToHome,
          homeTooltip: tr('nav.home'),
          items: [
            NasTabItem(
              id: 'browse',
              label: tr('nav.filesView'),
              icon: Icons.folder_open_outlined,
            ),
            NasTabItem(
              id: 'favorites',
              label: tr('nav.favorites'),
              icon: Icons.star_outline,
            ),
            NasTabItem(
              id: 'recent',
              label: tr('files.recent.title'),
              icon: Icons.history,
            ),
          ],
          selectedId: _mobileTab,
          onSelect: (id) => setState(() => _mobileTab = id),
          actions: [
            if (_mobileTab == 'recent' && _shortcuts.hasRecent)
              NasMobileAction(
                icon: Icons.delete_sweep_outlined,
                tooltip: tr('files.recent.clear'),
                onPressed: _shortcuts.clearRecent,
              ),
          ],
          body: switch (_mobileTab) {
            'favorites' => _shortcutList(favorites: true),
            'recent' => _shortcutList(favorites: false),
            _ => content,
          },
        );
      },
    );
  }

  Widget _toolbar(bool compact) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (_path != '/' && _path.isNotEmpty)
          NasIconAction(
            icon: Icons.arrow_upward_rounded,
            tooltip: tr('ui.files.001'),
            onPressed: _up,
          ),
        const SizedBox(width: NasTokens.spaceXs),
        Expanded(
          child: SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _crumb(tr('files.root'), '/', _segments.isEmpty),
                for (var i = 0; i < _segments.length; i++) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  _crumb(
                    _segments[i],
                    '/${_segments.take(i + 1).join('/')}',
                    i == _segments.length - 1,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: NasTokens.spaceSm),
          Text(
            '${_items.length} ${tr('files.items')}',
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
        ],
        NasIconAction(
          icon: Icons.create_new_folder_outlined,
          tooltip: tr('files.newFolder'),
          onPressed: _mkdir,
        ),
        NasIconAction(
          icon: Icons.search,
          tooltip: tr('common.search'),
          onPressed: _search,
        ),
        NasIconAction(
          icon: Icons.manage_search,
          tooltip: tr('home.quick.index'),
          onPressed: _index,
        ),
        NasIconAction(
          icon: Icons.refresh,
          tooltip: tr('common.refresh'),
          onPressed: _load,
        ),
        const SizedBox(width: NasTokens.spaceXs),
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
    );
  }

  Widget _crumb(String label, String path, bool active) {
    final scheme = Theme.of(context).colorScheme;
    return NasHoverBuilder(
      onTap: active ? null : () => _jumpTo(path),
      builder: (hovered) => Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceSm),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hovered && !active
              ? scheme.onSurface.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: NasTokens.fontBody,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _content(double width) {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(
        message: _error!,
        onRetry: _load,
        retryText: tr('common.retry'),
      );
    }
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('common.empty'),
        message: tr('ui.files.002'),
        icon: Icons.folder_open,
      );
    }

    if (_view == 'grid') {
      final cols = gridColumns(width);
      return GridView.builder(
        padding: const EdgeInsets.only(bottom: NasTokens.spaceLg),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: NasTokens.spaceSm,
          mainAxisSpacing: NasTokens.spaceSm,
          childAspectRatio: 0.92,
        ),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final item = _items[i];
          return NasContextMenuRegion(
            entries: _fileMenuEntries(item),
            child: GestureDetector(
            onLongPress: () => _gridMenu(item),
            child: NasFileTile(
              name: item.name,
              subtitle: _kindLabel(nasFileKindOf(item.name, isDir: item.dir)),
              kind: nasFileKindOf(item.name, isDir: item.dir),
              grid: true,
              onTap: () => _open(item),
              onDoubleTap: () => _open(item),
            ),
            ),
          );
        },
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceLg),
      itemCount: _items.length,
        itemBuilder: (context, i) {
          final item = _items[i];
          final kind = nasFileKindOf(item.name, isDir: item.dir);
          return NasContextMenuRegion(
            entries: _fileMenuEntries(item),
            child: NasFileTile(
            name: item.name,
            subtitle: _kindLabel(kind),
            kind: kind,
            onTap: () => _open(item),
            onDoubleTap: () => _open(item),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.dir)
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                _itemMenu(item),
              ],
            ),
            ),
          );
        },
    );
  }

  /// 收藏 / 最近：都是「目录清单」，点一条就切回文件夹 tab 并跳过去。
  Widget _shortcutList({required bool favorites}) {
    final items = favorites ? _shortcuts.favorites : _shortcuts.recent;
    if (items.isEmpty) {
      return NasEmptyState(
        title: tr('common.empty'),
        message: tr(favorites ? 'files.favorite.empty' : 'files.recent.empty'),
        icon: favorites ? Icons.star_outline : Icons.history,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceLg),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = items[i];
        return ListTile(
          leading: Icon(
            favorites ? Icons.star : Icons.folder_outlined,
            size: NasTokens.iconMd,
            color: favorites ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            s.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: scheme.onSurfaceVariant,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (favorites)
                IconButton(
                  tooltip: tr('files.favorite.remove'),
                  icon: const Icon(Icons.star, size: 18),
                  onPressed: () => _shortcuts.toggleFavorite(s),
                ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
          onTap: () => _openShortcut(s),
        );
      },
    );
  }

  Future<void> _openShortcut(FileShortcut shortcut) async {
    setState(() {
      _mobileTab = 'browse';
      _path = shortcut.path;
    });
    await _load();
    if (!mounted || _error == null) return;
    // 目录已被删/改名：忘掉它，别让用户反复点到打不开的条目
    await _shortcuts.forget(shortcut.path);
    if (!mounted) return;
    NasSnack.showOn(
      ScaffoldMessenger.of(context),
      '${tr('common.error')}：$_error',
    );
  }

  String _kindLabel(NasFileKind kind) => switch (kind) {
    NasFileKind.folder => tr('files.kind.folder'),
    NasFileKind.image => tr('files.kind.image'),
    NasFileKind.video => tr('files.kind.video'),
    NasFileKind.audio => tr('files.kind.audio'),
    NasFileKind.doc => tr('files.kind.doc'),
    NasFileKind.archive => tr('files.kind.archive'),
    NasFileKind.code => tr('files.kind.code'),
    NasFileKind.other => tr('files.kind.other'),
  };
}
