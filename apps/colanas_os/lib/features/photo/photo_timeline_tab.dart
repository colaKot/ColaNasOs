import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../shell/mobile_frame.dart';
import 'photo_on_this_day_page.dart';
import 'photo_page.dart';
import 'photo_year_view_page.dart';

/// 相册「照片」tab 的手机形态：内容 + 底部浮动胶囊（全部 / 年份 / 今天 / 收藏）。
///
/// 为什么这四个视图不各占一个底部 tab：它们是**同一份数据的四种看法**
/// （时间轴 → 年份刻度 → 只看今天 → 只看收藏），切来切去不换上下文。
/// 移动端基线也是这么做的：浮动胶囊只在「照片」tab 出现，切到别的 tab 就消失。
///
/// 为什么用 [IndexedStack] + 懒实例化：切回「全部」不能丢滚动位置，
/// 但四个视图一次全建会同时发四次首屏请求（相册是最重的页面之一）。
class PhotoTimelineTab extends StatefulWidget {
  const PhotoTimelineTab({super.key});

  @override
  State<PhotoTimelineTab> createState() => _PhotoTimelineTabState();
}

enum _TimelineMode { all, year, today, favorite }

class _PhotoTimelineTabState extends State<PhotoTimelineTab> {
  _TimelineMode _mode = _TimelineMode.all;

  /// 已经打开过的视图（key → widget），IndexedStack 保活但不预建
  final Map<_TimelineMode, Widget> _built = {};

  Widget _contentOf(_TimelineMode mode) {
    switch (mode) {
      case _TimelineMode.all:
        return const PhotoPage();
      case _TimelineMode.year:
        return PhotoYearViewPage(embedded: true, onPick: _drillIntoRange);
      case _TimelineMode.today:
        // 「今天」不是「只看今天」—— 用户要的是**往年的今天**（那年今日），
        // 只看今天通常只有几张甚至零张，信息量为零。
        return const PhotoOnThisDayPage(embedded: true);
      case _TimelineMode.favorite:
        return const PhotoPage(favoriteOnly: true);
    }
  }

  /// 年视图里点了某年/某月：回到「全部」并把时间轴缩到那个区间。
  ///
  /// 用新的 key 重建 PhotoPage（而不是 mutating 旧实例）：区间是构造参数、
  /// 首帧就要生效，否则会先拉一遍全量再覆盖。代价是丢了「全部」的滚动位置，
  /// 但这是用户主动下钻，跳回顶部反而符合预期。
  void _drillIntoRange(int year, int? month) {
    setState(() {
      _mode = _TimelineMode.all;
      _built[_TimelineMode.all] = PhotoPage(
        key: ValueKey('all:$year:${month ?? 0}'),
        initialYear: year,
        initialMonth: month,
      );
    });
  }

  void _select(int index) {
    final next = _TimelineMode.values[index];
    if (next == _mode) return;
    setState(() {
      _mode = next;
      _built.putIfAbsent(next, () => _contentOf(next));
    });
  }

  @override
  Widget build(BuildContext context) {
    // 桌面形态没有「浮动胶囊」这种东西：菜单项本身就是「照片 / 年份 / 今天 / 收藏」，
    // 再叠一层胶囊等于两套入口。所以宽屏直接退回原来的单页。
    if (!isCompactWidth(context)) return const PhotoPage();

    _built.putIfAbsent(_mode, () => _contentOf(_mode));
    final pages = <Widget>[
      for (final mode in _TimelineMode.values)
        _built.containsKey(mode) ? _built[mode]! : const SizedBox.shrink(),
    ];
    final body = Padding(
      // 底部留出胶囊的高度：内容最后一行不被浮动条压住
      padding: const EdgeInsets.only(bottom: 56),
      child: IndexedStack(index: _mode.index, children: pages),
    );

    // 多选态：底部已经换成操作工具条了，胶囊必须让位（否则两个条叠在一起）
    final bulk = NasBulkScope.maybeOf(context);
    if (bulk == null) return _withChips(body);
    return AnimatedBuilder(
      animation: bulk,
      builder: (context, _) =>
          bulk.spec != null ? body : _withChips(body),
    );
  }

  Widget _withChips(Widget body) {
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(
          left: NasTokens.spaceMd,
          right: NasTokens.spaceMd,
          bottom: 8,
          child: NasFloatingChips(
            labels: [
              tr('photo.timeline.all'),
              tr('photo.timeline.year'),
              // 「那年今日」比「今天」说得准：这一栏列的是往年同一天
              tr('photo.onThisDay.title'),
              tr('nav.favorites'),
            ],
            selectedIndex: _mode.index,
            onSelect: _select,
          ),
        ),
      ],
    );
  }
}
