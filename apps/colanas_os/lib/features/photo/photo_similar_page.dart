import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';

import '../../core/session.dart';
import 'photo_viewer_page.dart';

/// 找相似（全屏页）。
///
/// 服务端 `/photo/similar` 早就有了（CLIP 余弦），但入口只是时间轴多选栏里的一个
/// 720×480 弹窗，且写死 limit=60（服务端上限 50，静默截断）。
/// 这里给出完整页面：阈值可调、分数可见、点开能进查看器翻页。
class PhotoSimilarPage extends StatefulWidget {
  const PhotoSimilarPage({super.key, required this.photoId, this.title});

  final String photoId;
  final String? title;

  @override
  State<PhotoSimilarPage> createState() => _PhotoSimilarPageState();
}

class _PhotoSimilarPageState extends State<PhotoSimilarPage> {
  static const _thresholds = <double?>[null, 0.6, 0.7, 0.8];

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  Map<String, String> get _imageHeaders {
    final token = ApiSession.instance.token;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  bool _loading = true;
  String? _error;
  double? _minScore;
  List<PhotoAiPhotoRef> _items = const [];

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
      final res = await ApiSession.instance.client.photoSimilar(
        id: widget.photoId,
        limit: 100,
        minScore: _minScore,
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

  /// 相似结果只有 id/path/takenAt/score，查看器要 PhotoItem：
  /// 用占位字段补齐（查看器只用到 path / takenAt / id）。
  List<PhotoItem> get _asItems => _items
      .map(
        (r) => PhotoItem(
          id: r.id,
          libraryId: '',
          path: r.path,
          takenAt: r.takenAt,
          size: 0,
          width: null,
          height: null,
          mime: 'image/*',
          favorite: false,
        ),
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? tr('photo.similar.title')),
        actions: [
          NasRefreshButton(onPressed: _loading ? null : _load),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NasTokens.spaceMd,
              vertical: NasTokens.spaceSm,
            ),
            child: Row(
              children: [
                Text(
                  tr('photo.similar.threshold'),
                  style: TextStyle(
                    color: context.nasTextSecondary,
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                for (final t in _thresholds)
                  Padding(
                    padding: const EdgeInsets.only(right: NasTokens.spaceXs),
                    child: NasChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(t == null ? tr('photo.similar.any') : t.toStringAsFixed(1)),
                      selected: _minScore == t,
                      onSelected: (_) {
                        setState(() => _minScore = t);
                        _load();
                      },
                    ),
                  ),
                const Spacer(),
                Text(
                  tr('photo.similar.found', {'count': '${_items.length}'}),
                  style: TextStyle(
                    color: context.nasTextSecondary,
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const NasLoading()
                : _error != null
                ? NasErrorState(message: _error!, onRetry: _load)
                : _items.isEmpty
                ? NasEmptyState(
                    title: tr('photo.similar.empty'),
                    message: tr('photo.similar.emptyHint'),
                    icon: Icons.image_search,
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(NasTokens.spaceSm),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 190,
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                      childAspectRatio: 1,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final r = _items[i];
                      return InkWell(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PhotoViewerPage(
                              items: _asItems,
                              initialIndex: i,
                              title: widget.title ?? tr('photo.similar.title'),
                            ),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              NasCoverImage(
                                url: _media.thumbnail(r.path, size: 320),
                                headers: _imageHeaders,
                                cacheWidth: 320,
                                borderRadius: NasTokens.radiusSm,
                                icon: Icons.broken_image_outlined,
                              ),
                              if (r.score != null)
                                Positioned(
                                  right: 4,
                                  bottom: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      r.score!.toStringAsFixed(2),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
