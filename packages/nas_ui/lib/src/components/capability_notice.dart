import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';

import '../i18n.dart';
import '../tokens.dart';
import 'panel.dart';

/// 端能力矩阵提示条（docs/04 §64）：
///
/// **受限项必须在 UI 上明确告知**，不允许「看起来能用但点了没反应」。
/// 由外壳按「当前 App × 当前端」的档位渲染：[CapabilityLevel.limited] 用提示色，
/// [CapabilityLevel.none] 用错误色（入口本身也不可见时不出现）。
class NasCapabilityNotice extends StatelessWidget {
  const NasCapabilityNotice({
    super.key,
    required this.capabilityName,
    required this.level,
    this.hint,
  });

  /// 能力名（已本地化，如「文件管理」）
  final String capabilityName;

  /// 档位：仅 [CapabilityLevel.limited] / [CapabilityLevel.none] 有意义
  final CapabilityLevel level;

  /// 补充说明（如 Web 端沙箱原因），可为空
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final none = level == CapabilityLevel.none;
    final accent = none ? scheme.error : scheme.tertiary;
    final text = tr(
      none ? I18nKeys.capabilityNone : I18nKeys.capabilityLimited,
      {'name': capabilityName},
    );

    return NasPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceMd,
        vertical: NasTokens.spaceSm,
      ),
      border: Border.all(color: accent.withValues(alpha: 0.55)),
      child: Row(
        children: [
          Icon(
            none ? Icons.block_rounded : Icons.info_outline_rounded,
            size: 18,
            color: accent,
          ),
          const SizedBox(width: NasTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: NasTokens.fontBody,
                    color: scheme.onSurface,
                  ),
                ),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      hint!,
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}