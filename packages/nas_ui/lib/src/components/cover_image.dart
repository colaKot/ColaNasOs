import 'package:flutter/material.dart';

import '../tokens.dart';

/// 封面图（网络图）：统一认证头、缓存宽度、圆角与占位/错误态。
///
/// 相册、海报、专辑封面、书封都用它，避免每页各写一份 errorBuilder。
class NasCoverImage extends StatelessWidget {
  const NasCoverImage({
    super.key,
    required this.url,
    this.headers = const {},
    this.fallbackText,
    this.icon = Icons.image_outlined,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.borderRadius = NasTokens.radiusSm,
  });

  final String? url;
  final Map<String, String> headers;
  final String? fallbackText;
  final IconData icon;
  final BoxFit fit;
  final int? cacheWidth;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final src = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: src == null || src.isEmpty
          ? _placeholder()
          : Image.network(
              src,
              fit: fit,
              cacheWidth: cacheWidth,
              headers: headers,
              errorBuilder: (context, error, stack) => _placeholder(),
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
    final text = fallbackText?.trim();
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
            : Icon(icon,
                size: 36, color: const Color(NasTokens.colorTextSecondary)),
      ),
    );
  }
}
