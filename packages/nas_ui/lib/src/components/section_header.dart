import 'package:flutter/material.dart';

import '../tokens.dart';

/// 页内区块标题：标题 + 可选副标题 + 右侧动作（统计、筛选等）。
class NasSectionHeader extends StatelessWidget {
  const NasSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceMd,
        vertical: NasTokens.spaceSm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w600,
                    color: Color(NasTokens.colorTextPrimary),
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: Color(NasTokens.colorTextSecondary),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
