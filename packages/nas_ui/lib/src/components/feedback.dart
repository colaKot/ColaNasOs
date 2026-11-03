import 'package:flutter/material.dart';

import '../tokens.dart';

/// 轻反馈：统一 Snackbar 文案样式与错误色，避免每页各写一份。
class NasSnack {
  const NasSnack._();

  static void show(BuildContext context, String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                error ? Icons.error_outline : Icons.check_circle_outline,
                size: NasTokens.iconMd,
                color: Colors.white,
              ),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: error ? const Color(NasTokens.colorDanger) : null,
        ),
      );
  }
}

/// 二次确认：危险操作统一走这里（避免模态套模态）。
class NasConfirmDialog {
  const NasConfirmDialog._();

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = '确定',
    String cancelText = '取消',
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(cancelText)),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: const Color(NasTokens.colorDanger))
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
