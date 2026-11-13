import 'package:flutter/material.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 完整显示一张照片：按原始宽高比自适应容器高度，`BoxFit.contain` 不裁切不拉伸。
///
/// 以前时间轴 / 对照卡都写死高度 + `BoxFit.cover`，竖图会被裁成一条横条、
/// 宽图被压扁，看着比例很怪。现在服务端给宽高时按比例算高度（并夹在
/// [minHeight]..[maxHeight] 之间，避免一张竖图把整页撑爆）；宽高缺失的老照片
/// 退到 4:3，但依旧 `contain` 完整显示。
class PhotoAdaptiveImage extends StatelessWidget {
  const PhotoAdaptiveImage({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.minHeight = 140,
    this.maxHeight = 420,
    this.thumbSize = 640,
    this.borderRadius = 10,
    this.onTap,
    this.onLongPress,
  });

  final String path;

  /// 照片原始宽高（像素）；为空或 0 时按 4:3 兜底
  final double? width;
  final double? height;
  final double minHeight;
  final double maxHeight;
  final int thumbSize;
  final double borderRadius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 320.0;
        final ratio = (width != null && height != null && width! > 0 && height! > 0)
            ? width! / height!
            : 4.0 / 3.0;
        final lo = minHeight > maxHeight ? maxHeight : minHeight;
        final h = (w / ratio).clamp(lo, maxHeight).toDouble();

        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: SizedBox(
            width: double.infinity,
            height: h,
            child: GestureDetector(
              onTap: onTap,
              onLongPress: onLongPress,
              child: Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: path.isEmpty
                    ? const Center(child: Icon(Icons.image_not_supported_outlined))
                    : NasCoverImage(
                        url: MediaUrls(ApiSession.instance.baseUrl)
                            .thumbnail(path, size: thumbSize),
                        headers: ApiSession.instance.authHeaders,
                        cacheWidth: thumbSize,
                        fit: BoxFit.contain,
                        borderRadius: borderRadius,
                        icon: Icons.broken_image_outlined,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
