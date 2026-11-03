import 'package:flutter/material.dart';

import '../style.dart';
import '../tokens.dart';
import 'panel.dart';

/// 文件类型（决定图标与配色；所有端共用一套映射）。
enum NasFileKind { folder, image, video, audio, doc, archive, code, other }

/// 按扩展名判定类型；`isDir` 优先。
NasFileKind nasFileKindOf(String name, {bool isDir = false}) {
  if (isDir) return NasFileKind.folder;
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'heic' ||
    'svg' =>
      NasFileKind.image,
    'mp4' ||
    'mkv' ||
    'mov' ||
    'avi' ||
    'webm' ||
    'ts' ||
    'flv' =>
      NasFileKind.video,
    'mp3' || 'flac' || 'wav' || 'aac' || 'm4a' || 'ogg' => NasFileKind.audio,
    'pdf' ||
    'doc' ||
    'docx' ||
    'txt' ||
    'md' ||
    'epub' ||
    'ppt' ||
    'xlsx' ||
    'csv' =>
      NasFileKind.doc,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' || 'iso' => NasFileKind.archive,
    'js' ||
    'ts' ||
    'dart' ||
    'py' ||
    'go' ||
    'rs' ||
    'java' ||
    'json' ||
    'yml' ||
    'yaml' ||
    'sh' =>
      NasFileKind.code,
    _ => NasFileKind.other,
  };
}

/// 类型 → (图标, 强调色)
({IconData icon, Color color}) nasFileVisual(NasFileKind kind) =>
    switch (kind) {
      NasFileKind.folder => (
          icon: Icons.folder_rounded,
          color: const Color(0xFFF59E0B)
        ),
      NasFileKind.image => (
          icon: Icons.image_rounded,
          color: const Color(0xFFEC4899)
        ),
      NasFileKind.video => (
          icon: Icons.movie_rounded,
          color: const Color(0xFF6366F1)
        ),
      NasFileKind.audio => (
          icon: Icons.graphic_eq_rounded,
          color: const Color(0xFF06B6D4)
        ),
      NasFileKind.doc => (
          icon: Icons.description_rounded,
          color: const Color(0xFF10B981)
        ),
      NasFileKind.archive => (
          icon: Icons.inventory_2_rounded,
          color: const Color(0xFFF97316)
        ),
      NasFileKind.code => (
          icon: Icons.code_rounded,
          color: const Color(0xFF8B5CF6)
        ),
      NasFileKind.other => (
          icon: Icons.insert_drive_file_rounded,
          color: const Color(0xFF94A3B8)
        ),
    };

/// 文件瓦片：列表（默认）与网格两种形态，用同一份数据。
class NasFileTile extends StatelessWidget {
  const NasFileTile({
    super.key,
    required this.name,
    this.subtitle,
    this.kind = NasFileKind.other,
    this.selected = false,
    this.grid = false,
    this.onTap,
    this.onDoubleTap,
    this.trailing,
  });

  final String name;
  final String? subtitle;
  final NasFileKind kind;
  final bool selected;
  final bool grid;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = context.nasStyle;
    final visual = nasFileVisual(kind);
    final radius = BorderRadius.circular(spec.cardRadius * 0.8);

    final iconBlock = Container(
      width: grid ? 64 : 36,
      height: grid ? 64 : 36,
      decoration: BoxDecoration(
        color: visual.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(grid ? 16 : 10),
      ),
      child: Icon(visual.icon, size: grid ? 32 : 20, color: visual.color),
    );

    return NasHoverBuilder(
      onTap: onTap,
      builder: (hovered) => GestureDetector(
        onDoubleTap: onDoubleTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: NasTokens.durationFast),
          padding: grid
              ? const EdgeInsets.all(NasTokens.spaceSm)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.14)
                : hovered
                    ? scheme.onSurface.withValues(alpha: 0.05)
                    : Colors.transparent,
            borderRadius: radius,
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          child: grid
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    iconBlock,
                    const SizedBox(height: NasTokens.spaceXs + 2),
                    Text(
                      name,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: NasTokens.fontMicro,
                            color: scheme.onSurfaceVariant),
                      ),
                  ],
                )
              : Row(
                  children: [
                    iconBlock,
                    const SizedBox(width: NasTokens.spaceSm + 2),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: NasTokens.fontBody,
                              fontWeight: FontWeight.w500,
                              color: scheme.onSurface,
                            ),
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: NasTokens.fontMicro,
                                  color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                    if (trailing != null) trailing!,
                  ],
                ),
        ),
      ),
    );
  }
}
