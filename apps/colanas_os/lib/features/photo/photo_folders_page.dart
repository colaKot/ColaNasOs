import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';
import '../../shell/shell_back.dart';

import '../../core/session.dart';
import 'photo_viewer_page.dart';

/// 文件视图：根 = 当前用户的相册来源目录，逐级进入；
/// 照片只显示「当前目录直接文件」，空目录不铺后代照片。
class PhotoFoldersPage extends StatefulWidget {
  const PhotoFoldersPage({super.key});

  @override
  State<PhotoFoldersPage> createState() => _PhotoFoldersPageState();
}

class _PhotoFoldersPageState extends State<PhotoFoldersPage> {
  bool _loading = true;
  String? _error;
  List<PhotoFolderRoot> _roots = const [];
  PhotoFolderRoot? _source;
  PhotoFolderList? _list;
  String _path = '';
  String _sort = 'time';
  double _extent = 132;
  /// 多选：与时间轴共用同一套选择态（nas_ui/selection.dart）
  final NasSelectionController _selection = NasSelectionController();
  bool get _selecting => _selection.active;
  Set<String> get _selected => _selection.ids;

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  String _thumb(String path, {int size = 320}) => _media.thumbnail(path, size: size);

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
    _loadRoots();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_onSelectionChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _loadRoots() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.photoFolderRoots();
      if (!mounted) return;
      setState(() {
        _roots = res.items;
        _source = null;
        _path = '';
        _list = null;
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

  Future<void> _openSource(PhotoFolderRoot root) async {
    setState(() {
      _source = root;
      _path = root.path;
      _loading = true;
      _error = null;
    });
    await _loadDir(root.path);
  }

  Future<void> _loadDir(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.photoFolders(path: path);
      if (!mounted) return;
      setState(() {
        _list = res;
        _path = path;
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

  void _up() {
    final source = _source;
    if (source == null) return;
    final base = source.path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final current = _path.replaceAll('\\', '/');
    if (current == base) {
      _loadRoots();
      return;
    }
    final i = current.lastIndexOf('/');
    if (i <= base.length) {
      _loadDir(base);
    } else {
      _loadDir(current.substring(0, i));
    }
  }

  String get _relative {
    final source = _source;
    if (source == null) return '';
    final base = source.path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final current = _path.replaceAll('\\', '/');
    if (current == base) return '/';
    return current.startsWith(base) ? current.substring(base.length) : current;
  }

  void _openViewerItems(List<PhotoItem> items, int index) {
    if (items.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(
          items: items,
          initialIndex: index,
          title: _source?.name,
        ),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    return SubPageScope(
      active: _source != null,
      onBack: _up,
      child: _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _loadRoots);
    return Column(
      children: [
        _toolbar(),
        const Divider(height: 1),
        // 多选条紧贴工具栏（与电视剧列表 / 相册时间轴同一落点）
        if (_selecting) _selectBar(),
        Expanded(child: _source == null ? _rootsView() : _dirView()),
      ],
    );
  }

  Widget _toolbar() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: tr('photo.folders.up'),
            onPressed: _source == null ? null : _up,
            icon: const Icon(Icons.arrow_upward, size: 18),
          ),
          Expanded(
            child: Text(
              _source == null ? tr('nav.filesView') : '${_source!.name}  $_relative',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: tr('photo.folders.sortTime'),
            icon: const Icon(Icons.sort, size: 18),
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (ctx) => [
              PopupMenuItem(value: 'time', child: Text(tr('photo.folders.sortTime'))),
              PopupMenuItem(value: 'name', child: Text(tr('photo.folders.sortName'))),
            ],
          ),
          IconButton(
            tooltip: tr('photo.timeline.zoomOut'),
            onPressed: () => setState(() => _extent = (_extent - 32).clamp(80, 240)),
            icon: const Icon(Icons.zoom_out, size: 18),
          ),
          IconButton(
            tooltip: tr('photo.timeline.zoomIn'),
            onPressed: () => setState(() => _extent = (_extent + 32).clamp(80, 240)),
            icon: const Icon(Icons.zoom_in, size: 18),
          ),
          NasSelectionToggleButton(
            active: _selecting,
            enterTooltip: tr('photo.timeline.select'),
            onPressed: () => _selecting ? _selection.exit() : _selection.enter(),
          ),
          NasRefreshButton(onPressed: _source == null ? _loadRoots : () => _loadDir(_path)),
        ],
      ),
    );
  }

  Widget _rootsView() {
    if (_roots.isEmpty) {
      return NasEmptyState(
        title: tr('photo.folders.noSource'),
        message: tr('photo.folders.noSourceHint'),
        icon: Icons.folder_open_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _roots.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final root = _roots[i];
        // 文件夹来源卡走面板材质，不再用深色主题下近黑的 surfaceContainerHigh
        final style = context.nasStyle;
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openSource(root),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: style.panelColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: style.panelBorderColor),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: root.coverPath == null
                        ? ColoredBox(
                            color: style.panelColor,
                            child: const Icon(Icons.folder_outlined),
                          )
                        : NasCoverImage(url: _thumb(root.coverPath!), headers: ApiSession.instance.authHeaders),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(root.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        root.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: context.nasTextSecondary),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        tr('photo.folders.count', {'count': '${root.items}'}),
                        style: TextStyle(fontSize: 11, color: context.nasTextSecondary),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _dirView() {
    final list = _list;
    final dirs = list?.dirs ?? const <PhotoFolderItem>[];
    final files = [...(list?.fileItems ?? const <PhotoItem>[])];
    if (_sort == 'name') {
      files.sort((a, b) => a.path.compareTo(b.path));
    } else {
      files.sort((a, b) => b.takenAt.compareTo(a.takenAt));
    }
    if (dirs.isEmpty && files.isEmpty) {
      return NasEmptyState(
        title: tr('photo.folders.empty'),
        message: tr('photo.folders.emptyHint'),
        icon: Icons.folder_off_outlined,
      );
    }
    return Column(
      children: [
        Expanded(
          // 惰性构建：原来是 `ListView(children: [...])` + `Wrap(children: [for ...])`，
          // 目录和照片会一次性全部实例化 —— 一个几百张的目录首屏就建几百个
          // `Image.network` + 几百次解码请求，滚动直接卡死。
          // 现在目录用 SliverList、照片用 SliverGrid，两者都只构建可见部分。
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final dir = dirs[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(dir.name),
                        subtitle: Text(
                          tr('photo.folders.count', {'count': '${dir.items}'}),
                        ),
                        onTap: () => _loadDir(dir.path),
                      );
                    },
                    childCount: dirs.length,
                  ),
                ),
              ),
              if (files.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Text(
                      tr('photo.folders.here', {'count': '${list?.files ?? files.length}'}),
                      style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
                    ),
                  ),
                ),
              if (files.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: _extent + 4,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                      mainAxisExtent: _extent,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _fileTile(files, i),
                      childCount: files.length,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fileTile(List<PhotoItem> files, int i) {
    final file = files[i];
    final picked = _selected.contains(file.id);
    final tile = ClipRRect(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      child: SizedBox(
        width: _extent,
        height: _extent,
        child: NasCoverImage(
          url: _thumb(file.path),
          headers: ApiSession.instance.authHeaders,
          cacheWidth: 320,
        ),
      ),
    );
    return GestureDetector(
      onTap: () {
        if (!_selecting) {
          _openViewerItems(files, i);
          return;
        }
        _selection.toggle(file.id);
      },
      child: _selecting
          ? NasSelectionCover(selected: picked, child: tile)
          : tile,
    );
  }

  Widget _selectBar() {
    final ids = (_list?.fileItems ?? const <PhotoItem>[]).map((e) => e.id);
    return NasSelectionBar(
      title: tr(
        'photo.timeline.selected',
      ).replaceAll('{n}', '${_selected.length}'),
      allSelected: _selection.allSelected(ids),
      onToggleAll: () => _selection.toggleAll(ids),
      onClose: _selection.exit,
      actions: [
        NasSelectionAction(
          label: tr('common.delete'),
          icon: Icons.delete_outline,
          enabled: _selected.isNotEmpty,
          danger: true,
          onPressed: _deleteSelected,
        ),
      ],
    );
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final ids = _selected.toList();
    var toTrash = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('photo.delete.title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('photo.delete.confirm', {'count': '${ids.length}'})),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('photo.delete.toTrash')),
                subtitle: Text(
                  tr('photo.delete.permanentHint'),
                  style: const TextStyle(fontSize: 11),
                ),
                value: toTrash,
                onChanged: (v) => setLocal(() => toTrash = v ?? false),
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
              child: Text(tr('common.delete')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.photoDelete(
        body: PhotoDeleteBody(ids: ids, toTrash: toTrash),
      );
      if (!mounted) return;
      _selection.exit();
      await _loadDir(_path);
      NasSnack.showOn(messenger, tr('photo.delete.done', {'count': '${res.count}'}));
    } catch (e) {
      NasSnack.showOn(messenger, tr('photo.delete.failed', {'error': '$e'}));
    }
  }
}