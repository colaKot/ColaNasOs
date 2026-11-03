import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

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

  void _open(FilesListItem item) {
    if (!item.dir) return;
    _path = _path.endsWith('/') ? '$_path${item.name}' : '$_path/${item.name}';
    _load();
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
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failed.isEmpty ? tr('files.deletedToTrash') : failed.first.error,
          ),
        ),
      );
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// 行内「⋯」菜单：重命名 / 删除
  Widget _itemMenu(FilesListItem item) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      tooltip: '',
      onSelected: (v) {
        if (v == 'rename') _rename(item);
        if (v == 'delete') _delete(item);
      },
      itemBuilder: (_) => [
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
      messenger.showSnackBar(
        SnackBar(content: Text('${tr('common.error')}：$e')),
      );
    }
  }

  /// 触发索引（后台任务；完成后搜索才有结果）
  Future<void> _index() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.filesIndex();
      final taskId = res['taskId']?.toString() ?? '';
      final reused = res['reused'] == true;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            reused
                ? tr('ui.files.h439f15')
                : '${tr('home.quick.index')}：$taskId',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('${tr('common.error')}：$e')),
      );
    }
  }

  List<String> get _segments =>
      _path.split('/').where((s) => s.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = layoutFor(constraints.maxWidth) == LayoutMode.compact;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(compact),
            const SizedBox(height: NasTokens.spaceSm),
            Expanded(child: _content(constraints.maxWidth)),
          ],
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
          return GestureDetector(
            onLongPress: () => _gridMenu(item),
            child: NasFileTile(
              name: item.name,
              subtitle: _kindLabel(nasFileKindOf(item.name, isDir: item.dir)),
              kind: nasFileKindOf(item.name, isDir: item.dir),
              grid: true,
              onTap: () => _open(item),
              onDoubleTap: () => _open(item),
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
          return NasFileTile(
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
          );
        },
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
