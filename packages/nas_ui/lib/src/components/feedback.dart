import 'package:flutter/material.dart';

import '../tokens.dart';

/// 轻反馈：全系统唯一的 SnackBar 出口（别再手写 `ScaffoldMessenger.of(...).showSnackBar(...)`）。
///
/// 两种观感：
/// - 默认 **纯文本**：与历史 270+ 处手写调用逐像素一致（不改字号、不加图标、不清队列），
///   所以是「零观感变化」的机械收敛；
/// - `error: true` **红底 + 状态图标**：失败提示用这个，一眼能分清成功与失败。
///
/// 两个入口的区别只在「拿 messenger 的时机」：
/// - [show]：手上只有 `BuildContext`（同步上下文，或已过 `mounted` 守卫）；
/// - [showOn]：**已经 await 过**的场景 —— 必须在 await 之前把 `ScaffoldMessenger.of(context)`
///   存进局部变量，再传给这里。直接用 [show] 会踩 `use_build_context_synchronously`
///   （debug 下 `State.context` 在 dispose 后使用会断言崩）。
class NasSnack {
  const NasSnack._();

  /// 用 context 现取 messenger（同步场景）。
  static void show(
    BuildContext context,
    String message, {
    bool error = false,
    bool icon = false,
    SnackBarAction? action,
    Duration? duration,
    bool clearQueue = false,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    showOn(
      messenger,
      message,
      error: error,
      icon: icon,
      action: action,
      duration: duration,
      clearQueue: clearQueue,
    );
  }

  /// 用**提前捕获**的 messenger 弹提示（await 之后的安全写法）。
  static void showOn(
    ScaffoldMessengerState messenger,
    String message, {
    bool error = false,
    bool icon = false,
    SnackBarAction? action,
    Duration? duration,
    bool clearQueue = false,
  }) {
    final withIcon = icon || error;
    if (clearQueue) messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: withIcon
            ? Row(
                children: [
                  Icon(
                    error ? Icons.error_outline : Icons.check_circle_outline,
                    size: NasTokens.iconMd,
                    color: Colors.white,
                  ),
                  const SizedBox(width: NasTokens.spaceSm),
                  Expanded(child: Text(message)),
                ],
              )
            : Text(message),
        backgroundColor: error ? const Color(NasTokens.colorDanger) : null,
        action: action,
        duration: duration ?? const Duration(seconds: 4),
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
