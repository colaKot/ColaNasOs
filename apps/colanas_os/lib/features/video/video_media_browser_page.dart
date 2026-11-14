import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';
import '../../shell/shell_back.dart';

import '../../core/session.dart';
import 'video_page.dart';

/// 媒体浏览：按影视库目录逐级看文件夹 / 图片 / 视频。
///
/// 只列一层，不做递归；视频如果已在索引里会带 `id`，直接开详情与海报；
/// 未索引的视频仍显示文件名并提示先扫描。SMB 源离线时后端直接 503，这里给出明确提示。
class VideoMediaBrowserPage extends StatefulWidget {
  const VideoMediaBrowserPage({super.key, this.initialLibraryId});

  /// 从某个库入口进来时带上库 id
  final String? initialLibraryId;

  @override
  State<VideoMediaBrowserPage> createState() => _VideoMediaBrowserPageState();
}

class _VideoMediaBrowserPageState extends State<VideoMediaBrowserPage> {
  bool _libLoading = true;
  bool _loading = false;
  String? _error;
  List<VideoLibraryItem> _libraries = const [];
  String? _libraryId;
  String _path = '';
  List<VideoBrowseItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _loadLibraries();
  }

  Future<void> _loadLibraries() async {
    setState(() => _libLoading = true);
    try {
      final res = await ApiSession.instance.client.videoLibraryList();
      if (!mounted) return;
      final libs = res.items;
      final wanted = widget.initialLibraryId;
      setState(() {
        _libraries = libs;
        _libraryId = (wanted != null && libs.any((l) => l.id == wanted))
            ? wanted
            : (libs.isEmpty ? null : libs.first.id);
        _libLoading = false;
      });
      if (_libraryId != null) await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _libLoading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _load() async {
    final id = _libraryId;
    if (id == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoBrowse(
        libraryId: id,
        path: _path.isEmpty ? null : _path,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  VideoLibraryItem? get _library {
    for (final lib in _libraries) {
      if (lib.id == _libraryId) return lib;
    }
    return null;
  }

  void _enter(VideoBrowseItem item) {
    setState(() => _path = item.path);
    _load();
  }

  void _up() {
    if (_path.isEmpty) return;
    final parts = _path.split('/');
    parts.removeLast();
    setState(() => _path = parts.join('/'));
    _load();
  }

  Future<void> _openVideo(VideoBrowseItem item) async {
    if (item.id == null) {
      NasSnack.show(context, tr('video.browse.unindexed'));
      return;
    }
    try {
      final detail = await ApiSession.instance.client.videoItem(id: item.id!);
      if (!mounted) return;
      openVideoDetail(context, detail);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  void _openImage(VideoBrowseItem item) {
    final lib = _library;
    if (lib == null) return;
    final fullPath = '${lib.path}/${item.path}'.replaceAll(RegExp(r'^/+'), '');
    final token = ApiSession.instance.token;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(item.name)),
          body: InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: NasCoverImage(
                url:
                    '${ApiSession.instance.baseUrl}/api/v1/files/download?path=${Uri.encodeComponent(fullPath)}&inline=1',
                headers: token == null
                    ? const {}
                    : {'Authorization': 'Bearer $token'},
                cacheWidth: 2000,
                icon: Icons.broken_image_outlined,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 右键菜单：目录只给「打开 / 复制路径」；视频和图片多一条「查看/播放」的
  /// 语义化入口，其余动作（刮削、改匹配）在详情页里做。
  List<NasMenuEntry> _browseMenuEntries(
    VideoBrowseItem item,
    VideoLibraryItem? lib,
  ) {
    final full = _fullPath(item, lib);
    return [
      NasMenuEntry(
        label: tr('common.open'),
        icon: item.dir ? Icons.folder_open_outlined : Icons.play_arrow_outlined,
        onSelected: item.dir
            ? () => _enter(item)
            : item.mediaType == 'video'
                ? () => _openVideo(item)
                : item.mediaType == 'image'
                    ? () => _openImage(item)
                    : null,
      ),
      NasMenuEntry(
        label: tr('video.action.copyPath'),
        icon: Icons.copy_all_outlined,
        onSelected: full == null ? null : () => _copyPath(full),
      ),
    ];
  }

  /// 库根 + 相对路径；没选中库时退回相对路径本身
  String? _fullPath(VideoBrowseItem item, VideoLibraryItem? lib) {
    final rel = item.path;
    if (rel.isEmpty) return null;
    if (lib == null) return rel;
    return '${lib.path}/$rel'.replaceAll(RegExp(r'^/+'), '');
  }

  Future<void> _copyPath(String path) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: path));
    NasSnack.showOn(messenger, tr('common.copied'));
  }

  @override
  Widget build(BuildContext context) {
    return SubPageScope(
      active: _path.isNotEmpty,
      onBack: _up,
      child: _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    if (_libLoading) return const NasLoading();
    if (_libraries.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.browse.noLibrary'),
            icon: Icons.video_library_outlined,
          ),
        ],
      );
    }
    return Column(
      children: [
        _toolbar(),
        if (_error != null)
          Expanded(
            child: NasErrorState(
              message: _error!,
              onRetry: _load,
            ),
          )
        else if (_loading)
          const Expanded(child: NasLoading())
        else if (_items.isEmpty)
          Expanded(
            child: ListView(
              children: [
                NasEmptyState(
                  title: tr('video.browse.empty'),
                  icon: Icons.folder_open_outlined,
                ),
              ],
            ),
          )
        else
          Expanded(child: _grid()),
      ],
    );
  }

  Widget _toolbar() {
    final lib = _library;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: NasDropdown<String>(
              initialValue: _libraryId,
              isDense: true,
              decoration: InputDecoration(
                labelText: tr('video.browse.selectLibrary'),
              ),
              items: [
                for (final l in _libraries)
                  DropdownMenuItem(value: l.id, child: Text(l.name)),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _libraryId = v;
                  _path = '';
                });
                _load();
              },
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          IconButton(
            tooltip: tr('video.browse.up'),
            onPressed: _path.isEmpty ? null : _up,
            icon: const Icon(Icons.arrow_upward),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                // 根节点显示库名，不再叫「库根」；下钻后显示「库名 / 相对路径」
                _path.isEmpty
                    ? '# ${lib?.name ?? tr('video.browse.title')}'
                    : '# ${lib?.name ?? ''} / $_path',
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          ),
          NasRefreshButton(onPressed: _load),
        ],
      ),
    );
  }

  Widget _grid() {
    final base = ApiSession.instance.baseUrl;
    final lib = _library;
    final token = ApiSession.instance.token;
    final headers =
        token == null ? const <String, String>{} : {'Authorization': 'Bearer $token'};
    return LayoutBuilder(
      builder: (context, c) {
        final columns = gridColumns(c.maxWidth);
        return GridView.builder(
          padding: const EdgeInsets.all(NasTokens.spaceSm),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: NasTokens.spaceSm,
            mainAxisSpacing: NasTokens.spaceSm,
            childAspectRatio: 0.82,
          ),
          itemCount: _items.length,
          itemBuilder: (context, i) {
            final item = _items[i];
            return NasContextMenuRegion(
              entries: _browseMenuEntries(item, lib),
              child: InkWell(
                onTap: item.dir
                    ? () => _enter(item)
                    : item.mediaType == 'video'
                        ? () => _openVideo(item)
                        : item.mediaType == 'image'
                            ? () => _openImage(item)
                            : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _thumb(item, base, lib, headers)),
                    const SizedBox(height: NasTokens.spaceXs),
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: NasTokens.fontCaption),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _thumb(
    VideoBrowseItem item,
    String base,
    VideoLibraryItem? lib,
    Map<String, String> headers,
  ) {
    if (item.dir) {
      return Container(
        decoration: BoxDecoration(
          color: context.nasStyle.panelColor,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          border: Border.all(color: context.nasStyle.panelBorderColor),
        ),
        child: const Center(
          child: Icon(Icons.folder_outlined, size: 40),
        ),
      );
    }
    if (item.mediaType == 'video' && item.id != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        child: NasCoverImage(
          url: '$base/api/v1/video/poster?id=${Uri.encodeComponent(item.id!)}',
          headers: headers,
          cacheWidth: 480,
          icon: Icons.movie_outlined,
        ),
      );
    }
    if (item.mediaType == 'image' && lib != null) {
      final fullPath = '${lib.path}/${item.path}'.replaceAll(RegExp(r'^/+'), '');
      return ClipRRect(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        child: NasCoverImage(
          url:
              '$base/api/v1/files/thumb?path=${Uri.encodeComponent(fullPath)}&size=480',
          headers: headers,
          cacheWidth: 480,
          icon: Icons.image_outlined,
        ),
      );
    }
    final icon = item.mediaType == 'video'
        ? Icons.movie_outlined
        : item.mediaType == 'image'
            ? Icons.image_outlined
            : Icons.insert_drive_file_outlined;
    return Container(
      decoration: BoxDecoration(
        color: context.nasStyle.panelColor,
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        border: Border.all(color: context.nasStyle.panelBorderColor),
      ),
      child: Center(
        child: Icon(
          icon,
          size: 36,
          color: context.nasTextSecondary,
        ),
      ),
    );
  }
}
