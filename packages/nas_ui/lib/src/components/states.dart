import 'package:flutter/material.dart';

import '../tokens.dart';

/// 空态：每页「加载 / 空 / 错误 / 无权限」四件套之一（docs/04 §39.3）。
class NasEmptyState extends StatelessWidget {
  const NasEmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NasTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 48, color: const Color(NasTokens.colorTextSecondary)),
            const SizedBox(height: NasTokens.spaceMd),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: NasTokens.fontTitle,
                color: Color(NasTokens.colorTextPrimary),
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: NasTokens.spaceXs),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: Color(NasTokens.colorTextSecondary),
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: NasTokens.spaceMd),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误态：带重试入口。
class NasErrorState extends StatelessWidget {
  const NasErrorState({
    super.key,
    required this.message,
    required this.onRetry,
    this.retryText = '重试',
  });

  final String message;
  final Future<void> Function() onRetry;
  final String retryText;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NasTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 40, color: Color(NasTokens.colorDanger)),
            const SizedBox(height: NasTokens.spaceSm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(NasTokens.colorDanger)),
            ),
            const SizedBox(height: NasTokens.spaceMd),
            FilledButton(onPressed: onRetry, child: Text(retryText)),
          ],
        ),
      ),
    );
  }
}

/// 加载态：可选说明文字（避免空白页无反馈）。
class NasLoading extends StatelessWidget {
  const NasLoading({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: NasTokens.spaceMd),
            Text(
              message!,
              style: const TextStyle(
                fontSize: NasTokens.fontCaption,
                color: Color(NasTokens.colorTextSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
