/// 分页列表的通用骨架：Footer 三态、首屏状态机、卡片网格、触底加载、遮罩宿主。
library;

import 'package:flutter/material.dart';

import '../compat/getx.dart';
import '../compat/paged_list.dart';
import '../compat/ui_kit.dart';

/// 列表底部「加载中 / 没有更多 / 加载更多」三态。
class MusicPagedListFooter extends StatelessWidget {
  const MusicPagedListFooter({
    super.key,
    required this.isLoading,
    required this.hasMore,
    required this.onLoadMore,
    required this.noMoreText,
    required this.loadMoreText,
    this.autoLoadFailed,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
    this.textStyle,
  });

  final RxBool isLoading;
  final RxBool hasMore;
  final RxBool? autoLoadFailed;
  final VoidCallback onLoadMore;
  final String noMoreText;
  final String loadMoreText;
  final EdgeInsets padding;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) => Obx(() {
    if (isLoading.value) return _busy();
    if (!hasMore.value) return _message(noMoreText);
    final failed = autoLoadFailed;
    if (failed != null && !failed.value) return const SizedBox.shrink();
    return Center(
      child: OutlinedButton(onPressed: onLoadMore, child: Text(loadMoreText)),
    );
  });

  Widget _busy() => const Center(
    child: SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );

  Widget _message(String text) => Center(child: Text(text, style: textStyle));

  Widget get padded => Padding(padding: padding, child: this);
}

/// 首屏「加载中 / 空状态 / 正常内容」三态，可选空态叠加层与自定义空态。
class MusicAsyncListState extends StatelessWidget {
  const MusicAsyncListState({
    super.key,
    required this.loading,
    required this.isEmpty,
    required this.child,
    this.empty = const MusicEmptyState(),
    this.overlayOnEmpty,
    this.emptyBuilder,
  });

  final RxBool loading;
  final bool Function() isEmpty;
  final Widget child;
  final Widget empty;
  final Widget? overlayOnEmpty;
  final WidgetBuilder? emptyBuilder;

  @override
  Widget build(BuildContext context) => Obx(() {
    if (loading.value && isEmpty()) {
      return const Center(child: CircularProgressIndicator());
    }
    if (isEmpty()) {
      final builder = emptyBuilder;
      if (builder != null) return builder(context);
      final overlay = overlayOnEmpty;
      if (overlay == null) return Center(child: empty);
      return Stack(
        children: <Widget>[
          Center(child: empty),
          overlay,
        ],
      );
    }
    return child;
  });
}

/// 卡片网格：把 SliverPadding + SliverLayoutBuilder + 双 delegate + Footer 收口。
class MusicCardGrid<T> extends StatelessWidget {
  const MusicCardGrid({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.compact,
    this.maxCrossAxisExtent = 380,
    this.childAspectRatio = 1.8,
    this.spacing = 12,
    this.narrowBreakpoint = 750,
    this.padding = const EdgeInsets.fromLTRB(12, 6, 12, 6),
    this.footer,
    this.scrollController,
  });

  final RxList<T> items;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final bool compact;
  final double maxCrossAxisExtent;
  final double childAspectRatio;
  final double spacing;
  final double narrowBreakpoint;
  final EdgeInsets padding;
  final Widget? footer;
  final ScrollController? scrollController;

  List<Widget> slivers(BuildContext context) {
    // 先取一次长度：`RxList.length` 会走 `value` getter，是这一层**唯一的订阅点**
    // —— 列表为空时 `SliverChildBuilderDelegate` 不会调 itemBuilder，也就没有
    // `items[i]` 可读。不先订阅的话，包在外面的 Obx 重建时会因为「一个 observable
    // 都没有」直接抛 improper use（2026-11-09 空歌单页必现）。
    final count = items.length;
    return <Widget>[
      SliverPadding(
        padding: padding,
        sliver: SliverLayoutBuilder(
          builder: (context, constraints) {
            final narrow =
                compact && constraints.crossAxisExtent < narrowBreakpoint;
            return SliverGrid(
              gridDelegate: narrow
                  ? SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 1,
                      mainAxisSpacing: spacing,
                      crossAxisSpacing: spacing,
                      childAspectRatio: childAspectRatio,
                    )
                  : SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: maxCrossAxisExtent,
                      mainAxisSpacing: spacing,
                      crossAxisSpacing: spacing,
                      childAspectRatio: childAspectRatio,
                    ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => itemBuilder(context, items[index], index),
                childCount: count,
              ),
            );
          },
        ),
      ),
      if (footer != null) SliverToBoxAdapter(child: footer),
    ];
  }

  @override
  Widget build(BuildContext context) => Obx(
    () => CustomScrollView(
      controller: scrollController,
      slivers: slivers(context),
    ),
  );
}

/// 触底加载：在既有 triggerLoadMoreOnScroll 上补「滚动中标记」与统一阈值。
void attachPagedScroll(
  ScrollController controller, {
  required VoidCallback loadMore,
  VoidCallback? onScrolling,
  double threshold = 360,
}) {
  if (!controller.hasClients) return;
  onScrolling?.call();
  triggerLoadMoreOnScroll(controller, loadMore, threshold: threshold);
}

/// 列表页外层的「内容 + 子列表遮罩」宿主，ValueKey 仍由调用方决定。
class MusicOverlayHost<T> extends StatelessWidget {
  const MusicOverlayHost({
    super.key,
    required this.child,
    required this.active,
    required this.overlayBuilder,
    this.backgroundColor,
  });

  final Widget child;
  final Rxn<T> active;
  final Widget Function(T payload) overlayBuilder;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final overlay = Obx(() {
      final payload = active.value;
      if (payload == null) return const SizedBox.shrink();
      return overlayBuilder(payload);
    });
    final stack = Stack(
      children: <Widget>[
        Positioned.fill(child: child),
        Positioned.fill(child: overlay),
      ],
    );
    final color = backgroundColor;
    return color == null ? stack : ColoredBox(color: color, child: stack);
  }
}
