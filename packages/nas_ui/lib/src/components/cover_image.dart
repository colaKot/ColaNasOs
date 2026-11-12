import 'package:flutter/material.dart';

import '../tokens.dart';

/// 封面图（网络图）：统一认证头、缓存宽度、圆角与占位/错误态。
///
/// 相册、海报、专辑封面、书封都用它，避免每页各写一份 errorBuilder。
///
/// [fallbackUrl] 是一次性降级地址：首图 404 / 503（服务端缩略图不可用、
/// 这一集没有刮削海报）时自动换它再试一次，仍失败才画占位。
/// 影视卡拿「服务端抽帧」做兜底 —— 整排空白灰块比一张裁过的剧照难看得多。
class NasCoverImage extends StatefulWidget {
  const NasCoverImage({
    super.key,
    required this.url,
    this.fallbackUrl,
    this.headers = const {},
    this.fallbackText,
    this.icon = Icons.image_outlined,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.borderRadius = NasTokens.radiusSm,
  });

  final String? url;

  /// 首图失败后换这一张（只降级一次，不做无限重试）
  final String? fallbackUrl;

  final Map<String, String> headers;
  final String? fallbackText;
  final IconData icon;
  final BoxFit fit;
  final int? cacheWidth;
  final double borderRadius;

  @override
  State<NasCoverImage> createState() => _NasCoverImageState();
}

class _NasCoverImageState extends State<NasCoverImage> {
  /// 已经降级到 fallbackUrl
  bool _fellBack = false;

  @override
  void didUpdateWidget(covariant NasCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表复用同一位置换了条目：重置降级状态，否则新卡会一直显示旧兜底图
    if (oldWidget.url != widget.url) _fellBack = false;
  }

  String? get _src => _fellBack ? (widget.fallbackUrl ?? widget.url) : widget.url;

  @override
  Widget build(BuildContext context) {
    final src = _src;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: src == null || src.isEmpty
          ? _placeholder()
          : Image.network(
              src,
              // 换地址后不能让 Image 复用上一个 URL 的解码结果
              key: ValueKey<String>(src),
              fit: widget.fit,
              cacheWidth: widget.cacheWidth,
              headers: widget.headers,
              errorBuilder: (context, error, stack) {
                final fallback = widget.fallbackUrl;
                if (!_fellBack && fallback != null && fallback.isNotEmpty) {
                  // 下一帧再切：在 build 过程中 setState 会报错
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _fellBack = true);
                  });
                  return const ColoredBox(color: Color(NasTokens.colorSurfaceAlt));
                }
                return _placeholder();
              },
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return const ColoredBox(
                  color: Color(NasTokens.colorSurfaceAlt),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _placeholder() {
    final text = widget.fallbackText?.trim();
    return ColoredBox(
      color: const Color(NasTokens.colorSurfaceAlt),
      child: Center(
        child: text != null && text.isNotEmpty
            ? Text(
                text.substring(0, 1),
                style: const TextStyle(
                  fontSize: NasTokens.fontHeadline,
                  color: Color(NasTokens.colorTextSecondary),
                ),
              )
            : Icon(
                widget.icon,
                size: 36,
                color: const Color(NasTokens.colorTextSecondary),
              ),
      ),
    );
  }
}
