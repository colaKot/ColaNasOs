import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'video_page.dart';

/// 智能合集（预设规则）：最近添加 / 未看 / 继续观看 / 4K / HDR / 全景声 / 长片。
///
/// 计数与条目由后端同一份 SQL 条件算出（`/video/smart-albums` + `/items`），
/// 不做「前端拉全库再过滤」，避免大库卡顿与计数不一致。
class VideoSmartAlbumsPage extends StatefulWidget {
  const VideoSmartAlbumsPage({super.key});

  @override
  State<VideoSmartAlbumsPage> createState() => _VideoSmartAlbumsPageState();
}

class _VideoSmartAlbumsPageState extends State<VideoSmartAlbumsPage> {
  static const _defs = <(String, String, IconData)>[
    ('recent30', 'video.smart.recent30', Icons.fiber_new_outlined),
    ('continue', 'video.smart.continue', Icons.play_circle_outline),
    ('unwatched', 'video.smart.unwatched', Icons.visibility_off_outlined),
    ('4k', 'video.smart.4k', Icons.hd_outlined),
    ('hdr', 'video.smart.hdr', Icons.hdr_on),
    ('atmos', 'video.smart.atmos', Icons.surround_sound_outlined),
    ('long', 'video.smart.long', Icons.timelapse_outlined),
  ];

  bool _loading = true;
  String? _error;
  Map<String, int> _counts = const {};

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
      final res = await ApiSession.instance.client.videoSmartAlbums();
      if (!mounted) return;
      setState(() {
        _counts = {for (final s in res.items) s.key: s.count};
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

  void _open(String key, String labelKey) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SmartAlbumItemsPage(albumKey: key, title: tr(labelKey)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('video.smart.hint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
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
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(NasTokens.spaceMd),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 260,
              mainAxisSpacing: NasTokens.spaceSm,
              crossAxisSpacing: NasTokens.spaceSm,
              childAspectRatio: 1.6,
            ),
            itemCount: _defs.length,
            itemBuilder: (context, i) {
              final (key, labelKey, icon) = _defs[i];
              final count = _counts[key] ?? 0;
              return NasCard(
                onTap: count == 0 ? null : () => _open(key, labelKey),
                padding: const EdgeInsets.all(NasTokens.spaceMd),
                child: Row(
                  children: [
                    Icon(icon, size: NasTokens.iconXl),
                    const SizedBox(width: NasTokens.spaceSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            tr(labelKey),
                            style: const TextStyle(
                              fontSize: NasTokens.fontSubtitle,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: NasTokens.spaceXs),
                          Text(
                            tr('video.smart.count', {'count': count}),
                            style: TextStyle(
                              fontSize: NasTokens.fontCaption,
                              color: count == 0
                                  ? context.nasTextSecondary
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 智能合集里的条目：海报墙，点开详情。
class _SmartAlbumItemsPage extends StatefulWidget {
  const _SmartAlbumItemsPage({required this.albumKey, required this.title});

  final String albumKey;
  final String title;

  @override
  State<_SmartAlbumItemsPage> createState() => _SmartAlbumItemsPageState();
}

class _SmartAlbumItemsPageState extends State<_SmartAlbumItemsPage> {
  bool _loading = true;
  String? _error;
  List<VideoItem> _items = const [];

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
      final res = await ApiSession.instance.client.videoSmartAlbumItems(
        key: widget.albumKey,
        limit: 120,
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
    final base = ApiSession.instance.baseUrl;
    final token = ApiSession.instance.token;
    final headers =
        token == null ? const <String, String>{} : {'Authorization': 'Bearer $token'};
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: tr('common.refresh'),
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
              ? NasErrorState(message: _error!, onRetry: _load)
              : _items.isEmpty
                  ? ListView(
                      children: [
                        NasEmptyState(
                          title: tr('video.smart.empty'),
                          icon: Icons.movie_outlined,
                        ),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (context, c) {
                        final columns = gridColumns(c.maxWidth);
                        return GridView.builder(
                          padding: const EdgeInsets.all(NasTokens.spaceSm),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: NasTokens.spaceSm,
                            mainAxisSpacing: NasTokens.spaceSm,
                            childAspectRatio: 0.72,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final item = _items[i];
                            return InkWell(
                              onTap: () => openVideoDetail(context, item),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                        NasTokens.radiusSm,
                                      ),
                                      child: NasCoverImage(
                                        url:
                                            '$base/api/v1/video/poster?id=${Uri.encodeComponent(item.id)}',
                                        headers: headers,
                                        cacheWidth: 480,
                                        icon: Icons.movie_outlined,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: NasTokens.spaceXs),
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: NasTokens.fontBody,
                                    ),
                                  ),
                                  MediaFlagsRow(item: item, compact: true),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
    );
  }
}
