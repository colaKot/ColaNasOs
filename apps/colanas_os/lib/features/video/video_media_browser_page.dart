import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('video.browse.unindexed'))),
      );
      return;
    }
    try {
      final detail = await ApiSession.instance.client.videoItem(id: item.id!);
      if (!mounted) return;
      openVideoDetail(context, detail);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
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

  @override
  Widget build(BuildContext context) {
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
            child: DropdownButtonFormField<String>(
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
                '# ${lib?.name ?? ''} / ${_path.isEmpty ? tr('video.browse.root') : _path}',
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: tr('common.refresh'),
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
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
            return InkWell(
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
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
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
