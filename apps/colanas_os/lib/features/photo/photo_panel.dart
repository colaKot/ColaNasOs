import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

/// 相册 AI 洞察类页面共用的轻卡片：统一圆角、描边与标题排版。
class PhotoPanel extends StatelessWidget {
  const PhotoPanel({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // 用 NasStyle 的面板材质（半透明 + 风格描边），不要 surfaceContainerHigh ——
    // 深色主题下那是近黑实色，和极光背景割裂（2026-11-14 反馈）。
    final style = context.nasStyle;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: style.panelColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: style.panelBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              trailing ?? const SizedBox.shrink(),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
