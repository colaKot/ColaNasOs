import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../photo/photo_download.dart';
import 'video_card.dart';
import 'video_media_viewer_page.dart';

/// 图片库 / 混合库的专用浏览页。
///
/// 两个互相独立的开关：
///   * 文件夹 / 整库平铺：按目录逐级下钻，首页是 4:3 文件夹卡片；
///   * 瀑布流 / 普通网格：瀑布流按每张图自己的宽高比排，网格统一 4:3。
class VideoImageLibraryPage extends StatefulWidget {
  const VideoImageLibraryPage({
    super.key,
    required this.libraryId,
    required this.libType,
    this.title = '',
    this.embedded = false,
  });

  final String libraryId;
  final String libType;
  final String title;
  final bool embedded;

  @override
  State<VideoImageLibraryPage> createState() => _VideoImageLibraryPageState();
}

class _VideoImageLibraryPageState extends State<VideoImageLibraryPage> {
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  List<VideoItem> _items = const [];
  String? _cursor;
  int _total = 0;

  bool _folderMode = true;
  bool _waterfall = false;
  bool _showName = true;
  String _folderPath = '';
  String? _parentPath;
  List<VideoImageFolderSegment> _segments = const [];
  List<VideoImageFolderNode> _folders = const [];
  bool _foldersLoading = false;

  String _sortBy = 'name';
  String _sortOrder = 'asc';
  String _query = '';
  String _letter = '';

  /// 每个库独立记：文件夹/整库、网格/瀑布流、名称开关、排序、首字母、当前目录
  String _k(String name) => 'video.image.${widget.libraryId}.$name';

  @override
  void initState() {
    super.initState();
    _folderMode = SettingsStore.instance.getBool(_k('folderMode')) ?? true;
    _waterfall = SettingsStore.instance.getBool(_k('waterfall')) ?? false;
    _showName = SettingsStore.instance.getBool(_k('showName')) ?? true;
    _folderPath = SettingsStore.instance.getString(_k('folderPath')) ?? '';
    _sortBy = SettingsStore.instance.getString(_k('sortBy')) ?? 'name';
    _sortOrder = SettingsStore.instance.getString(_k('sortOrder')) ?? 'asc';
    _letter = SettingsStore.instance.getString(_k('letter')) ?? '';
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  bool get _isSearching => _query.trim().isNotEmpty;

  void _onScroll() {
    if (_loadingMore || _cursor == null || !_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 420) {
      _load(more: true);
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
      _load(reset: true);
    });
  }

  Future<void> _load({bool reset = false, bool more = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _cursor = null;
      });
    } else if (more) {
      setState(() => _loadingMore = true);
    }
    try {
      final c = ApiSession.instance.client;
      final folderPath = _folderPath.isEmpty ? null : _folderPath;
      final folderMode = _folderMode || _isSearching
          ? (_isSearching ? 'subtree' : 'exact')
          : null;
      final res = await c.videoList(
        libraryId: widget.libraryId,
        q: _isSearching ? _query : null,
        sortBy: _sortBy,
        sortOrder: _sortOrder,
        letter: _letter.isEmpty ? null : _letter,
        folderPath: folderPath,
        folderMode: folderMode,
        cursor: more ? _cursor : null,
        limit: 60,
      );
      if (!mounted) return;
      setState(() {
        _items = more ? [..._items, ...res.items] : res.items;
        _cursor = res.nextCursor;
        _loading = false;
        _loadingMore = false;
      });
      if (!more) {
        unawaited(_loadCount());
        unawaited(_loadFolders());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadCount() async {
    try {
      final res = await ApiSession.instance.client.videoListCount(
        libraryId: widget.libraryId,
        q: _isSearching ? _query : null,
        letter: _letter.isEmpty ? null : _letter,
        folderPath: _folderPath.isEmpty ? null : _folderPath,
        folderMode: _folderMode || _isSearching
            ? (_isSearching ? 'subtree' : 'exact')
            : null,
      );
      if (!mounted) return;
      setState(() => _total = res.total);
    } catch (_) {
      /* 计数失败不影响内容 */
    }
  }

  Future<void> _loadFolders() async {
    if (!_folderMode || _isSearching) {
      if (mounted) {
        setState(() {
          _folders = const [];
          _foldersLoading = false;
        });
      }
      return;
    }
    setState(() => _foldersLoading = true);
    try {
      final res = await ApiSession.instance.client.videoImageFolders(
        libraryId: widget.libraryId,
        folderPath: _folderPath.isEmpty ? null : _folderPath,
      );
      if (!mounted) return;
      setState(() {
        _folderPath = res.path;
        _parentPath = res.parentPath;
        _segments = res.segments;
        _folders = res.folders;
        _foldersLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _foldersLoading = false);
    }
  }

  Future<void> _enterFolder(String path) async {
    setState(() => _folderPath = path);
    await SettingsStore.instance.setString(_k('folderPath'), path);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _load(reset: true);
  }

  Future<void> _goUp() async {
    final parent = _parentPath;
    if (parent == null) return;
    await _enterFolder(parent);
  }

  void _setSort(String by, String order) {
    setState(() {
      _sortBy = by;
      _sortOrder = order;
    });
    SettingsStore.instance.setString(_k('sortBy'), by);
    SettingsStore.instance.setString(_k('sortOrder'), order);
    _load(reset: true);
  }

  Future<void> _showSortSheet() async {
    final picked = await showModalBottomSheet<(String, String)>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final (by, order, label) in const [
              ('name', 'asc', 'video.media.sortNameAsc'),
              ('name', 'desc', 'video.media.sortNameDesc'),
              ('takenTime', 'desc', 'video.media.sortTakenDesc'),
              ('takenTime', 'asc', 'video.media.sortTakenAsc'),
              ('createTime', 'desc', 'video.media.sortCreateDesc'),
              ('createTime', 'asc', 'video.media.sortCreateAsc'),
              ('viewTime', 'desc', 'video.media.sortViewDesc'),
              ('viewTime', 'asc', 'video.media.sortViewAsc'),
            ])
              ListTile(
                dense: true,
                leading: _sortBy == by && _sortOrder == order
                    ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                    : const SizedBox(width: 24),
                title: Text(tr(label)),
                onTap: () => Navigator.pop(ctx, (by, order)),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    _setSort(picked.$1, picked.$2);
  }

  Future<void> _openItem(VideoItem item, int index) async {
    if (item.mediaType == 'image') {
      await openMediaViewer(context, items: _items, initialIndex: index);
      return;
    }
    openVideoDetail(context, item);
  }

  Future<void> _deleteItem(VideoItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.media.delete')),
        content: Text(tr('video.dup.deleteConfirm', {'count': '1'})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ApiSession.instance.client.videoItemsDelete(
        body: VideoDeleteItemsBody(ids: [item.id]),
      );
      await _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _deleteFolder(VideoImageFolderNode folder) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.media.delete')),
        content: Text(folder.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ApiSession.instance.client.videoImageFolderDelete(
        body: VideoImageFolderDeleteBody(
          libraryId: widget.libraryId,
          path: folder.path,
        ),
      );
      await _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _downloadItem(VideoItem item) async {
    final url =
        '${ApiSession.instance.baseUrl}/api/v1/files/download?path=${Uri.encodeComponent(item.path)}';
    final headers = videoArtHeaders;
    final name = item.fileTitle.isEmpty ? item.title : item.fileTitle;
    if (PhotoDownload.supported) {
      try {
        await PhotoDownload.save(url: url, headers: headers, suggestedName: name);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('video.media.copyLink'))),
      );
    }
  }

  Future<void> _showItemMenu(VideoItem item, int index, Offset pos) async {
    final v = await showMenu<String>(
      context: context,
      position: _relative(pos),
      items: [
        PopupMenuItem(value: 'open', child: Text(tr('video.media.open'))),
        if (item.mediaType == 'image' || item.mediaType == 'video')
          PopupMenuItem(value: 'download', child: Text(tr('video.media.download'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: Text(tr('video.media.delete'))),
      ],
    );
    if (!mounted || v == null) return;
    if (v == 'open') await _openItem(item, index);
    if (v == 'download') await _downloadItem(item);
    if (v == 'delete') await _deleteItem(item);
  }

  Future<void> _showFolderMenu(VideoImageFolderNode folder, Offset pos) async {
    final v = await showMenu<String>(
      context: context,
      position: _relative(pos),
      items: [
        PopupMenuItem(value: 'open', child: Text(tr('video.media.open'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: Text(tr('video.media.delete'))),
      ],
    );
    if (!mounted || v == null) return;
    if (v == 'open') await _enterFolder(folder.path);
    if (v == 'delete') await _deleteFolder(folder);
  }

  RelativeRect _relative(Offset pos) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? MediaQuery.of(context).size;
    return RelativeRect.fromRect(Rect.fromPoints(pos, pos), Offset.zero & size);
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        _toolbar(context),
        Expanded(
          child: _loading
              ? const NasLoading()
              : _error != null
                  ? NasErrorState(message: _error!, onRetry: () => _load(reset: true))
                  : _content(context),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title.isEmpty ? tr('app.video') : widget.title)),
      body: body,
    );
  }

  Widget _toolbar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceSm,
        NasTokens.spaceSm,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
      ),
      child: Column(
        children: [
          Row(
            children: [
              if (_folderMode)
                IconButton(
                  tooltip: tr('video.browse.up'),
                  onPressed: _parentPath == null ? null : _goUp,
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(child: _breadcrumb(context)),
              Text(
                '$_total',
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
              const SizedBox(width: NasTokens.spaceXs),
              IconButton(
                tooltip: _folderMode ? tr('video.media.all') : tr('video.media.folder'),
                onPressed: () {
                  setState(() {
                    _folderMode = !_folderMode;
                    if (!_folderMode) _folderPath = '';
                  });
                  SettingsStore.instance.setBool(_k('folderMode'), _folderMode);
                  if (!_folderMode) SettingsStore.instance.setString(_k('folderPath'), '');
                  _load(reset: true);
                },
                icon: Icon(
                  _folderMode ? Icons.grid_view_rounded : Icons.folder_rounded,
                  color: _folderMode ? null : scheme.primary,
                ),
              ),
              IconButton(
                tooltip: tr('common.refresh'),
                onPressed: () => _load(reset: true),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr('video.media.searchHint'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                              _load(reset: true);
                            },
                          ),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: NasTokens.spaceXs),
              IconButton(
                tooltip: tr('video.media.sort'),
                onPressed: _showSortSheet,
                icon: const Icon(Icons.sort_by_alpha),
              ),
              IconButton(
                tooltip: _waterfall ? tr('video.media.grid') : tr('video.media.waterfall'),
                onPressed: () {
                  setState(() => _waterfall = !_waterfall);
                  SettingsStore.instance.setBool(_k('waterfall'), _waterfall);
                },
                icon: Icon(_waterfall ? Icons.grid_view_rounded : Icons.view_quilt_rounded),
              ),
              IconButton(
                tooltip: _showName ? tr('video.media.hideName') : tr('video.media.showName'),
                onPressed: () {
                  setState(() => _showName = !_showName);
                  SettingsStore.instance.setBool(_k('showName'), _showName);
                },
                icon: Icon(_showName ? Icons.title_rounded : Icons.hide_image_outlined),
              ),
            ],
          ),
          if (_sortBy == 'name') _letterBar(context),
        ],
      ),
    );
  }

  Widget _letterBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final letters = ['', ...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''), '#'];
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: letters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (ctx, i) {
          final l = letters[i];
          final active = _letter == l;
          return InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              setState(() => _letter = l);
              SettingsStore.instance.setString(_k('letter'), l);
              _load(reset: true);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: active ? scheme.primary.withValues(alpha: 0.16) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                l.isEmpty ? tr('video.list.filter.all') : l,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: active ? scheme.primary : null,
                  fontWeight: active ? FontWeight.w700 : null,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _breadcrumb(BuildContext context) {
    final items = <Widget>[];
    items.add(InkWell(
      onTap: () => _enterFolder(''),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(tr('video.browse.root')),
      ),
    ));
    for (final s in _segments) {
      items.add(const Text(' / '));
      items.add(InkWell(
        onTap: () => _enterFolder(s.path),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(s.name),
        ),
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: items),
    );
  }

  Widget _content(BuildContext context) {
    final hasFolders = _folderMode && !_isSearching && _folders.isNotEmpty;
    if (_items.isEmpty && !hasFolders) {
      return NasEmptyState(
        title: tr('video.media.empty'),
        icon: Icons.photo_library_outlined,
      );
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceSm,
        NasTokens.spaceXs,
        NasTokens.spaceSm,
        80,
      ),
      children: [
        if (hasFolders) ...[
          _sectionTitle(tr('video.media.folder'), _folders.length),
          _folderGrid(context),
          const SizedBox(height: NasTokens.spaceSm),
        ],
        if (_foldersLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_items.isNotEmpty && hasFolders)
          _sectionTitle(tr('video.list.filter.all'), _items.length),
        if (_items.isEmpty)
          const SizedBox(height: 40)
        else if (_waterfall)
          _waterfallLayout(context)
        else
          _grid(context),
        if (_loadingMore)
          const Padding(
            padding: EdgeInsets.all(NasTokens.spaceSm),
            child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
      ],
    );
  }

  Widget _sectionTitle(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
      child: Row(
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Text('$count', style: TextStyle(fontSize: NasTokens.fontCaption, color: const Color(0x88000000))),
        ],
      ),
    );
  }

  Widget _folderGrid(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        const spacing = 10.0;
        final maxW = c.maxWidth;
        final desired = maxW < 520 ? 150.0 : 220.0;
        final cols = ((maxW + spacing) / (desired + spacing)).floor().clamp(2, 8);
        final w = (maxW - spacing * (cols - 1)) / cols;
        final h = w * 3 / 4;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final f in _folders)
              SizedBox(
                width: w,
                height: h,
                child: _folderCard(context, f, w),
              ),
          ],
        );
      },
    );
  }

  Widget _folderCard(BuildContext context, VideoImageFolderNode folder, double width) {
    final theme = Theme.of(context);
    final cover = folder.cover is Map
        ? VideoItem.fromJson(Map<String, dynamic>.from(folder.cover as Map))
        : null;
    final url = cover == null ? null : videoPosterUrl(cover);
    final card = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _enterFolder(folder.path),
      onLongPress: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero));
        _showFolderMenu(folder, pos);
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url == null)
              ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.folder_outlined, size: 40)),
              )
            else
              NasCoverImage(
                url: url,
                headers: videoArtHeaders,
                fit: BoxFit.cover,
                icon: Icons.folder_outlined,
                cacheWidth: (width * 2).round(),
              ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withValues(alpha: 0.78)],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.folder_rounded, size: 15, color: Colors.white),
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    tr('video.media.folderCount', {'count': '${folder.count}'}),
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return GestureDetector(
      onSecondaryTapDown: (d) => _showFolderMenu(folder, d.globalPosition),
      child: card,
    );
  }

  Widget _grid(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        const spacing = 12.0;
        final maxW = c.maxWidth;
        final target = maxW < 520 ? 120.0 : 176.0;
        final cols = (maxW / (target + spacing)).floor().clamp(2, 12);
        final w = (maxW - spacing * (cols - 1)) / cols;
        final imageH = w * 3 / 4;
        final tileH = imageH + (_showName ? 22 : 0);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: w / tileH,
          ),
          itemBuilder: (ctx, i) {
            final item = _items[i];
            return _mediaCell(context, item, i, w, imageH, 4 / 3);
          },
        );
      },
    );
  }

  Widget _waterfallLayout(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        const spacing = 12.0;
        final maxW = c.maxWidth;
        final cols = (maxW / 240).floor().clamp(2, 6);
        final w = (maxW - spacing * (cols - 1)) / cols;
        final buckets = List.generate(cols, (_) => <Widget>[]);
        final heights = List<double>.filled(cols, 0);
        for (var i = 0; i < _items.length; i++) {
          final item = _items[i];
          final ratio = _aspectOf(item);
          final imageH = w / ratio;
          final tileH = imageH + (_showName ? 22 : 0);
          var target = 0;
          for (var j = 1; j < cols; j++) {
            if (heights[j] < heights[target]) target = j;
          }
          buckets[target].add(_mediaCell(context, item, i, w, imageH, ratio));
          heights[target] += tileH + spacing;
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < cols; j++) ...[
              if (j > 0) const SizedBox(width: spacing),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final wgt in buckets[j])
                      Padding(
                        padding: const EdgeInsets.only(bottom: spacing),
                        child: wgt,
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  double _aspectOf(VideoItem item) {
    final w = item.width ?? 0;
    final h = item.height ?? 0;
    if (w > 0 && h > 0) return w / h;
    return item.mediaType == 'image' ? 4 / 3 : 16 / 9;
  }

  Widget _mediaCell(
    BuildContext context,
    VideoItem item,
    int index,
    double width,
    double imageHeight,
    double aspect,
  ) {
    final theme = Theme.of(context);
    final url = item.mediaType == 'image'
        ? '${ApiSession.instance.baseUrl}/api/v1/files/thumb?path=${Uri.encodeComponent(item.path)}&size=${(width * 2).round()}'
        : videoPosterUrl(item);
    final isImage = item.mediaType == 'image';
    final cell = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _openItem(item, index),
      onLongPress: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero));
        _showItemMenu(item, index, pos);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: imageHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NasCoverImage(
                    url: url,
                    headers: videoArtHeaders,
                    fit: BoxFit.cover,
                    fallbackText: item.title,
                    icon: isImage ? Icons.image_outlined : Icons.movie_outlined,
                    cacheWidth: (width * 2).round(),
                  ),
                  if (!isImage)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow, size: 16, color: Colors.white),
                      ),
                    ),
                  if (!isImage && item.watched)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: VideoWatchedBadge(watched: true, compact: true),
                    ),
                ],
              ),
            ),
          ),
          if (_showName)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.15, color: theme.colorScheme.onSurface.withValues(alpha: 0.88)),
              ),
            ),
        ],
      ),
    );
    return GestureDetector(
      onSecondaryTapDown: (d) => _showItemMenu(item, index, d.globalPosition),
      child: cell,
    );
  }
}
