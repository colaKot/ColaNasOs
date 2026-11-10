import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'photo_download.dart';
import 'photo_similar_page.dart';
import 'photo_video_page.dart';

/// 大图查看器的输入单元：**只要 id + 路径**（其余字段都是可选的展示用）。
///
/// 为什么不直接用 `PhotoItem`：人脸簇 / 智能规则 / 全景检索这些列表的接口只给
/// `id + path`，逼调用方去补 libraryId/size/mime 只会造出一堆假值，
/// 一旦有人真的读这些字段就会踩到假数据。查看器本身只用 path + takenAt。
@immutable
class ViewerPhoto {
  const ViewerPhoto({
    required this.id,
    required this.path,
    this.takenAt = 0,
    this.width,
    this.height,
    this.mediaKind = 'image',
    this.durationMs,
    this.liveKind = '',
  });

  final String id;
  final String path;
  final int takenAt;
  final int? width;
  final int? height;

  /// image / video（后端 `photo_items.media_kind`）
  final String mediaKind;
  final int? durationMs;

  /// '' / motion / apple
  final String liveKind;

  bool get isVideo => mediaKind == 'video';
  bool get isLive => liveKind.isNotEmpty;

  /// 视频封面的抽帧位置（秒）；图片为 null
  double? get posterAt {
    if (!isVideo) return null;
    final ms = durationMs ?? 0;
    if (ms <= 0) return 0.5;
    return (ms / 1000 * 0.1).clamp(0.5, 3.0);
  }

  static ViewerPhoto ofItem(PhotoItem item) => ViewerPhoto(
    id: item.id,
    path: item.path,
    takenAt: item.takenAt,
    width: item.width,
    height: item.height,
    mediaKind: item.mediaKind,
    durationMs: item.durationMs,
    liveKind: item.liveKind,
  );
}

/// 统一的大图查看器：左右翻页、键盘、双击缩放、1600 预览 + 手动原图。
///
/// **一个模块，谁的列表谁自己接**：只渲染传进来的这一份列表，
/// 不读全局状态、不跨页取数据 —— 从人脸簇打开就只在人脸簇的照片里翻页。
///
/// 打开时只加载 1600 长边缩略图（服务端 JPEG），避免 Web 端直接解码手机原图；
/// 需要原图时点右上角「原图」。预加载前后各一张，关闭后不触发调用方刷新。
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    this.items = const [],
    this.photos,
    required this.initialIndex,
    this.title,
  });

  /// 完整照片项（相册时间轴 / 相册集 / 地图等用这个）
  final List<PhotoItem> items;

  /// 轻量输入（只有 id + path 的列表用这个）；与 [items] 二选一，优先本项
  final List<ViewerPhoto>? photos;

  final int initialIndex;
  final String? title;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

/// 打开查看器（任意只拿到 id + path 的列表都可以直接用）
void openPhotoViewer(
  BuildContext context, {
  required List<ViewerPhoto> photos,
  required int initialIndex,
  String? title,
}) {
  if (photos.isEmpty) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PhotoViewerPage(
        photos: photos,
        initialIndex: initialIndex,
        title: title,
      ),
    ),
  );
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _controller;
  late final List<ViewerPhoto> _items;
  late int _index;
  final Set<int> _original = <int>{};
  bool _zoomed = false;

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  @override
  void initState() {
    super.initState();
    _items =
        widget.photos ??
        [for (final item in widget.items) ViewerPhoto.ofItem(item)];
    _index = widget.initialIndex.clamp(0, _items.length - 1);
    _controller = PageController(initialPage: _index);
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheNeighbors());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _previewUrl(ViewerPhoto item) =>
      _media.thumbnail(item.path, size: 1600, at: item.posterAt);

  String _originalUrl(ViewerPhoto item) => _media.file(item.path);

  /// 播放：视频放原文件，动态照片放服务端从 JPEG 尾部取出的那段视频
  void _play(ViewerPhoto item) {
    if (!item.isVideo && !item.isLive) return;
    final url = item.isVideo ? _media.file(item.path) : _media.livePhoto(item.id);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoVideoPage(
          url: url,
          title: item.path.split('/').last,
          subtitle: item.isVideo
              ? '${formatDurationMs(item.durationMs ?? 0)}  ·  ${item.width ?? '?'}×${item.height ?? '?'}'
              : tr('photo.media.live'),
        ),
      ),
    );
  }

  void _precacheNeighbors() {
    for (final i in [_index - 1, _index + 1]) {
      if (i < 0 || i >= _items.length) continue;
      final url = _previewUrl(_items[i]);
      // ignore: discarded_futures
      precacheImage(NetworkImage(url, headers: ApiSession.instance.authHeaders), context);
    }
  }

  void _go(int next) {
    if (next < 0 || next >= _items.length) return;
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _close() => Navigator.of(context).maybePop();

  /// 另存原图（桌面）；Web 端没有保存入口，改用复制链接
  Future<void> _save(ViewerPhoto item, String filename) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await PhotoDownload.save(
        url: _media.file(item.path),
        headers: ApiSession.instance.authHeaders,
        suggestedName: filename,
      );
      if (!mounted || path == null) return;
      NasSnack.showOn(messenger, tr('photo.longPress.saved', {'path': path}));
    } catch (e) {
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('photo.longPress.saveFailed', {'error': '$e'}));
    }
  }

  Future<void> _copyLink(ViewerPhoto item) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _media.file(item.path)));
    if (!mounted) return;
    NasSnack.showOn(messenger, tr('photo.longPress.linkCopied'));
  }

  /// 属性 / EXIF 面板：按需向后端读文件头，不阻塞图片加载
  Future<void> _showInfo(ViewerPhoto item) async {
    Map<String, dynamic>? data;
    String? error;
    try {
      data = await ApiSession.instance.client.photoExif(id: item.id);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(NasTokens.spaceLg),
          child: data == null
              ? Text(
                  tr('photo.info.loadFailed', {'error': error ?? ''}),
                  style: const TextStyle(color: Colors.white70),
                )
              : _infoSheet(data),
        ),
      ),
    );
  }

  String? _text(dynamic value) {
    if (value == null) return null;
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }

  String _shutter(double seconds) {
    if (seconds >= 1) return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)} s';
    final denom = (1 / seconds).round();
    return '1/$denom s';
  }

  Widget _infoSheet(Map<String, dynamic> d) {
    final rows = <(String, String)>[];
    void add(String label, String? value) {
      if (value != null && value.isNotEmpty) rows.add((label, value));
    }

    add(tr('photo.info.file'), _text(d['path']));
    final size = (d['size'] as num?)?.toInt() ?? 0;
    add(tr('photo.info.size'), formatBytes(size));
    final w = (d['width'] as num?)?.toInt();
    final h = (d['height'] as num?)?.toInt();
    if (w != null && h != null) add(tr('photo.info.dimensions'), '$w × $h');
    final taken = (d['takenAt'] as num?)?.toInt();
    if (taken != null && taken > 0) add(tr('photo.info.takenAt'), _formatTime(taken));

    final make = _text(d['make']);
    final model = _text(d['camera']);
    add(
      tr('photo.info.camera'),
      make != null && model != null && !model.startsWith(make)
          ? '$make $model'
          : (model ?? make),
    );
    add(tr('photo.info.lens'), _text(d['lens']));
    final iso = (d['iso'] as num?)?.toInt();
    if (iso != null && iso > 0) add(tr('photo.info.iso'), 'ISO $iso');
    final aperture = (d['fNumber'] as num?)?.toDouble();
    if (aperture != null && aperture > 0) {
      add(tr('photo.info.aperture'), 'f/${aperture.toStringAsFixed(1)}');
    }
    final shutter = (d['exposureTimeSec'] as num?)?.toDouble();
    if (shutter != null && shutter > 0) add(tr('photo.info.shutter'), _shutter(shutter));
    final focal = (d['focalLengthMm'] as num?)?.toDouble();
    if (focal != null && focal > 0) add(tr('photo.info.focal'), '${focal.toStringAsFixed(0)} mm');
    add(tr('photo.info.software'), _text(d['software']));

    final lat = (d['latitude'] as num?)?.toDouble();
    final lng = (d['longitude'] as num?)?.toDouble();
    if (lat != null && lng != null) {
      add(tr('photo.info.gps'), '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}');
    }
    final orientation = (d['orientation'] as num?)?.toInt();
    if (orientation != null && orientation != 1) {
      add(tr('photo.info.orientation'), '$orientation');
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.65),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('photo.info.title'),
            style: const TextStyle(color: Colors.white, fontSize: 17),
          ),
          const SizedBox(height: NasTokens.spaceMd),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 88,
                            child: Text(
                              row.$1,
                              style: const TextStyle(color: Colors.white54, fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SelectableText(
                              row.$2,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = _items[_index];
    final filename = item.path.split('/').last;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title ?? filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
            Text(
              '${_index + 1} / ${_items.length}',
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          if (item.isVideo || item.isLive)
            IconButton(
              tooltip: item.isVideo ? tr('photo.media.playVideo') : tr('photo.media.playLive'),
              icon: Icon(item.isVideo ? Icons.play_circle_outline : Icons.motion_photos_on),
              onPressed: () => _play(item),
            ),
          IconButton(
            tooltip: tr('photo.info.title'),
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showInfo(item),
          ),
          // 查看器里也要能下载：长按菜单那条入口在浏览大图时够不着
          if (PhotoDownload.supported)
            IconButton(
              tooltip: tr('photo.longPress.save'),
              icon: const Icon(Icons.download_outlined),
              onPressed: () => _save(item, filename),
            )
          else
            IconButton(
              tooltip: tr('photo.longPress.copyLink'),
              icon: const Icon(Icons.link),
              onPressed: () => _copyLink(item),
            ),
          TextButton.icon(
            onPressed: () {
              setState(() {
                if (_original.contains(_index)) {
                  _original.remove(_index);
                } else {
                  _original.add(_index);
                }
              });
            },
            icon: const Icon(Icons.hd_outlined, size: 18),
            label: Text(_original.contains(_index) ? tr('photo.preview') : tr('photo.original')),
          ),
          IconButton(
            tooltip: tr('photo.similar.title'),
            icon: const Icon(Icons.image_search),
            onPressed: () {
              final item = _items[_index];
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PhotoSimilarPage(
                    photoId: item.id,
                    title: item.path.split('/').last,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: tr('common.close'),
            onPressed: _close,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(_index - 1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(_index + 1),
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          const SingleActivator(LogicalKeyboardKey.home): () => _go(0),
          const SingleActivator(LogicalKeyboardKey.end): () =>
              _go(_items.length - 1),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: _items.length,
                onPageChanged: (i) {
                  setState(() {
                    _index = i;
                    _zoomed = false;
                  });
                  _precacheNeighbors();
                },
                itemBuilder: (context, i) {
                  final current = _items[i];
                  final useOriginal = _original.contains(i);
                  final url = useOriginal ? _originalUrl(current) : _previewUrl(current);
                  final image = Image.network(
                    url,
                    headers: ApiSession.instance.authHeaders,
                    fit: BoxFit.contain,
                    cacheWidth: useOriginal ? null : 1600,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      final total = progress.expectedTotalBytes;
                      final value = total == null
                          ? null
                          : progress.cumulativeBytesLoaded / total;
                      return Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(value: value, strokeWidth: 2),
                        ),
                      );
                    },
                    errorBuilder: (context, error, stack) => const Center(
                      child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 40),
                    ),
                  );
                  final zoomed = i == _index && _zoomed;
                  // 视频 / 动态照片：缩略图当海报，中间给一个明确的播放入口。
                  // 视频不能靠双击缩放看，直接盖按钮更符合预期。
                  final playable = current.isVideo || current.isLive;
                  return GestureDetector(
                    onDoubleTap: playable ? null : () => setState(() => _zoomed = !_zoomed),
                    child: Center(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          zoomed && !playable
                              ? InteractiveViewer(
                                  minScale: 1,
                                  maxScale: 5,
                                  child: image,
                                )
                              : image,
                          if (playable)
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => _play(current),
                                child: Container(
                                  width: 72,
                                  height: 72,
                                  decoration: const BoxDecoration(
                                    color: Colors.black45,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    current.isVideo ? Icons.play_arrow : Icons.motion_photos_on,
                                    color: Colors.white,
                                    size: 38,
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
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _ArrowButton(
                  icon: Icons.chevron_left,
                  enabled: _index > 0,
                  onTap: () => _go(_index - 1),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _ArrowButton(
                  icon: Icons.chevron_right,
                  enabled: _index < _items.length - 1,
                  onTap: () => _go(_index + 1),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 12,
                child: IgnorePointer(
                  child: Text(
                    [
                      item.path,
                      if (item.width != null && item.height != null)
                        '${item.width}×${item.height}',
                      if (item.isVideo && formatDurationMs(item.durationMs ?? 0).isNotEmpty)
                        formatDurationMs(item.durationMs ?? 0),
                      if (item.isLive) tr('photo.media.live'),
                      _formatTime(item.takenAt),
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !enabled,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 64,
          alignment: Alignment.center,
          color: Colors.transparent,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: enabled ? 0.7 : 0,
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
          ),
        ),
      ),
    );
  }
}