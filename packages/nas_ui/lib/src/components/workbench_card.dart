import 'package:flutter/material.dart';

import '../tokens.dart';
import 'panel.dart';

/// 工作台「应用卡」：渐变图标块 + 标题 + 一句话说明 + 右上箭头。
///
/// 图标块的渐变由调用方按 App 类型给出（见 `AppVisuals`），保证同一 App 全站同色。
class NasAppCard extends StatelessWidget {
  const NasAppCard({
    super.key,
    required this.icon,
    required this.title,
    required this.accent,
    this.subtitle,
    this.onTap,
    this.tag,
    this.height = 112,
  });

  final IconData icon;
  final String title;
  final List<Color> accent;
  final String? subtitle;

  /// 右上角小标签（如「即将推出」）
  final String? tag;
  final VoidCallback? onTap;
  /// 卡片最小高度：内容（图标 + 标题 + 说明）更高时自动撑高。
  ///
  /// 不能写成固定高度 —— 中文回退字体的行高比 Roboto 大，两行文字加图标会顶破
  /// 112，debug 下卡片底部就出现一条黄黑溢出条（release 下表现为文字被裁）。
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NasCard(
      onTap: onTap,
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: accent,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: accent.last.withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Icon(icon, size: 22, color: Colors.white),
              ),
              const Spacer(),
              if (tag != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    tag!,
                    style: TextStyle(
                        fontSize: NasTokens.fontMicro, color: scheme.primary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceMd),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontSubtitle,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// 工作台「指标卡」：标题 + 大字数值 + 细进度条 + 说明（磁盘/内存/CPU 共用）。
class NasMetricCard extends StatelessWidget {
  const NasMetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    this.caption,
    this.ratio,
    this.onTap,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final String? caption;

  /// 0..1；null 不画进度条
  final double? ratio;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NasCard(
      onTap: onTap,
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: NasTokens.iconSm, color: color),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (onTap != null)
                Icon(Icons.chevron_right,
                    size: NasTokens.iconSm, color: scheme.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: NasTokens.spaceXs + 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontTitle,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          if (caption != null)
            Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: NasTokens.fontMicro,
                  color: scheme.onSurfaceVariant),
            ),
          if (ratio != null) ...[
            const SizedBox(height: NasTokens.spaceSm),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio!.clamp(0, 1),
                minHeight: 4,
                backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
