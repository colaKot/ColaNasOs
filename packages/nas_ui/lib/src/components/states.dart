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

/// 异步取数的四态渲染：**加载中 / 失败可重试 / 空 / 有数据**。
///
/// 为什么要有：44 个页面各写一遍
/// ```dart
/// if (_loading) return const NasLoading();
/// if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
/// if (_items.isEmpty) return NasEmptyState(...);
/// return ListView(...);
/// ```
/// 于是「加载中长什么样」「失败后有没有重试」「要不要空态」每页都不太一样，
/// 改一次判定顺序要翻 40 多个文件。这里只统一**判定**，具体形态仍由调用方给
/// （[empty] / [builder]）——所以不会把各页的布局强行拉平。
///
/// 用法：
/// ```dart
/// return NasAsyncView<List<MusicTrack>>(
///   loading: _loading,
///   error: _error,
///   onRetry: _load,
///   data: _items,
///   isEmpty: (items) => items.isEmpty,
///   empty: NasEmptyState(title: tr('music.nav.empty'), icon: Icons.music_note),
///   builder: (items) => ListView.builder(...),
/// );
/// ```
class NasAsyncView<T> extends StatelessWidget {
  const NasAsyncView({
    super.key,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.data,
    required this.builder,
    this.empty,
    this.isEmpty,
  });

  final bool loading;

  /// 非空即错误态（错误文案直接展示，保持与 [NasErrorState] 一致）
  final String? error;

  /// 错误态「重试」回调（与 [NasErrorState.onRetry] 一致，是异步的）
  final Future<void> Function() onRetry;

  /// 就绪数据；为 null 视为空
  final T? data;

  /// 判空（如 `(items) => items.isEmpty`）。不传则只看 [data] 是否为 null。
  final bool Function(T data)? isEmpty;

  /// 空态视图；不传时给一个极简占位（避免整页空白）
  final Widget? empty;

  /// 有数据时的内容
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) {
    if (loading) return const NasLoading();
    if (error != null) return NasErrorState(message: error!, onRetry: onRetry);
    final value = data;
    if (value == null) return empty ?? const SizedBox.shrink();
    if (isEmpty?.call(value) ?? false) return empty ?? const SizedBox.shrink();
    return builder(value);
  }
}
