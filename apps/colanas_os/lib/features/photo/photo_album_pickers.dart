import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

// ============================================================ 头像
//
// 只列「已命名」的人脸聚类。
//
// 为什么必须过滤：`photoFaceClusters` 返回的是全部聚类，其中大量是没名字的
// 「未命名 · 12 张」。做相册规则时按无名聚类收照片毫无意义 —— 用户根本不知道
// 那一坨是谁，而且聚类 id 会随重建漂移，规则过几天就失效了。
//
// 封面与人脸页保持同一套 URL（`/photo/face/image?id=<coverFaceId>`），
// 这样同一个人的头像在两处看到的是同一张。

/// 选一个人脸聚类；取消返回 null
Future<PhotoFaceClusterItem?> showFacePickDialog(
  BuildContext context, {
  required List<PhotoFaceClusterItem> items,
}) {
  final named = items
      .where((c) => (c.name?.trim().isNotEmpty ?? false) && c.coverFaceId != null)
      .toList()
    ..sort((a, b) => b.size.compareTo(a.size));
  return showDialog<PhotoFaceClusterItem>(
    context: context,
    builder: (_) => _FacePickDialog(items: named),
  );
}

class _FacePickDialog extends StatelessWidget {
  const _FacePickDialog({required this.items});

  final List<PhotoFaceClusterItem> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(tr('photo.album.pickFace')),
      content: SizedBox(
        width: 560,
        height: 420,
        child: items.isEmpty
            ? Center(
                child: Text(
                  tr('photo.album.noNamedFace'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.nasTextSecondary),
                ),
              )
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 104,
                  mainAxisExtent: 128,
                  crossAxisSpacing: NasTokens.spaceSm,
                  mainAxisSpacing: NasTokens.spaceSm,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final c = items[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(NasTokens.radiusMd),
                    onTap: () => Navigator.pop(context, c),
                    child: Column(
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: scheme.primary.withValues(alpha: 0.5)),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.network(
                              '${ApiSession.instance.baseUrl}/api/v1/photo/face/image'
                              '?id=${Uri.encodeComponent(c.coverFaceId!)}&size=200',
                              headers: ApiSession.instance.authHeaders,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Icon(
                                Icons.face_outlined,
                                color: context.nasTextSecondary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: NasTokens.spaceXs),
                        Text(
                          c.name!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: NasTokens.fontCaption),
                        ),
                        Text(
                          tr('photo.album.photoCount', {'n': '${c.size}'}),
                          style: TextStyle(
                            fontSize: NasTokens.fontMicro,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
      ],
    );
  }
}

// ============================================================ 场景 / 活动
//
// 网格 + 封面 + 按张数倒序，只取前 30。
//
// 场景标签动辄上百个（Places365 全量 365 类），做成扁平列表要滚很久才能看到
// 常用的那几个；按张数取前 30 之后，一屏就能看完「我库里真正有的场景」。
// 活动（SigLIP2 标签）与场景同构，共用同一个选择器，只是标题 / 空态文案不同。

/// 选一个场景标签；取消返回 null
Future<String?> showScenePickDialog(
  BuildContext context, {
  required List<PhotoSceneTagSummaryItem> items,
}) {
  final top = [...items]..sort((a, b) => b.count.compareTo(a.count));
  return showDialog<String>(
    context: context,
    builder: (_) => _TagPickDialog(
      items: [
        for (final s in top.take(30))
          (label: s.label, count: s.count, coverPath: s.coverPath),
      ],
      title: tr('photo.album.pickScene'),
      emptyText: tr('photo.album.noScene'),
      icon: Icons.landscape_outlined,
    ),
  );
}

/// 选一个活动标签；取消返回 null
Future<String?> showActivityPickDialog(
  BuildContext context, {
  required List<PhotoSceneSummaryItem> items,
}) {
  final top = [...items]..sort((a, b) => b.count.compareTo(a.count));
  return showDialog<String>(
    context: context,
    builder: (_) => _TagPickDialog(
      items: [
        for (final s in top.take(30))
          (label: s.label, count: s.count, coverPath: s.coverPath),
      ],
      title: tr('photo.album.pickActivity'),
      emptyText: tr('photo.album.noActivity'),
      icon: Icons.sports_handball_outlined,
    ),
  );
}

class _TagPickDialog extends StatelessWidget {
  const _TagPickDialog({
    required this.items,
    required this.title,
    required this.emptyText,
    required this.icon,
  });

  final List<({String label, int count, String? coverPath})> items;
  final String title;
  final String emptyText;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final media = MediaUrls(ApiSession.instance.baseUrl);
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 600,
        height: 440,
        child: items.isEmpty
            ? Center(
                child: Text(
                  emptyText,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.nasTextSecondary),
                ),
              )
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 128,
                  mainAxisExtent: 150,
                  crossAxisSpacing: NasTokens.spaceSm,
                  mainAxisSpacing: NasTokens.spaceSm,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final s = items[i];
                  final path = s.coverPath ?? '';
                  return InkWell(
                    borderRadius: BorderRadius.circular(NasTokens.radiusMd),
                    onTap: () => Navigator.pop(context, s.label),
                    child: Column(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(NasTokens.radiusMd),
                            child: path.isEmpty
                                ? Container(
                                    // 相册封面兜底：面板材质
                                    color: context.nasStyle.panelColor,
                                    child: Icon(
                                      icon,
                                      color: context.nasTextSecondary,
                                    ),
                                  )
                                : Image.network(
                                    media.thumbnail(path, size: 256),
                                    headers: ApiSession.instance.authHeaders,
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                    errorBuilder: (_, _, _) => Container(
                                      color: context.nasStyle.panelColor,
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: context.nasTextSecondary,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: NasTokens.spaceXs),
                        Text(
                          s.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: NasTokens.fontCaption),
                        ),
                        Text(
                          tr('photo.album.photoCount', {'n': '${s.count}'}),
                          style: TextStyle(
                            fontSize: NasTokens.fontMicro,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
      ],
    );
  }
}

// ============================================================ 日期区间
//
// 自绘的翻页日历，替代 `showDateRangePicker`。
//
// 系统那个是「滚动式 Material DateRangePicker」：需要先在月历里滚，再点两次
// 日期，最后还要点一次「确定」，而且月份只能一个月一个月地滑 —— 想选 2019 年
// 的区间要滑几十下。这里改成：
//   · 顶部「年 / 月」两个下拉，任意跳转；
//   · 左右箭头逐月翻；
//   · 宽屏并排两个月（跨月选择不用来回翻）；
//   · 快捷预设（今天 / 近 7 天 / 本月 / 上年 …）一键落区间；
//   · 区间底纹：起点终点实心、中间浅色，hover 前也能看清选了多大范围。

/// 打开日期区间选择器；取消返回 null
Future<DateTimeRange?> showPhotoDateRangeDialog(
  BuildContext context, {
  DateTimeRange? initial,
}) {
  return showDialog<DateTimeRange>(
    context: context,
    builder: (_) => _DateRangeDialog(initial: initial),
  );
}

class _DateRangeDialog extends StatefulWidget {
  const _DateRangeDialog({this.initial});

  final DateTimeRange? initial;

  @override
  State<_DateRangeDialog> createState() => _DateRangeDialogState();
}

class _DateRangeDialogState extends State<_DateRangeDialog> {
  late DateTime _leftMonth; // 只有年月有意义
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _start = widget.initial?.start;
    _end = widget.initial?.end;
    final base = _start ?? now;
    _leftMonth = DateTime(base.year, base.month);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _leftMonth = DateTime(_leftMonth.year, _leftMonth.month + delta);
    });
  }

  void _pickDay(DateTime day) {
    setState(() {
      if (_start == null || (_start != null && _end != null)) {
        // 空状态 / 上一轮已选完：这一下重新开始
        _start = day;
        _end = null;
        return;
      }
      // 已有起点、没有终点
      if (day.isBefore(_start!)) {
        // 点到了起点之前：当成「换个起点」，不清空全部（比直接重置更符合直觉）
        _start = day;
        return;
      }
      _end = day;
    });
  }

  void _applyPreset(int preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime start;
    DateTime end = today;
    switch (preset) {
      case 0: // 今天
        start = today;
      case 1: // 昨天
        start = today.subtract(const Duration(days: 1));
        end = start;
      case 2: // 近 7 天（含今天）
        start = today.subtract(const Duration(days: 6));
      case 3: // 近 30 天
        start = today.subtract(const Duration(days: 29));
      case 4: // 本月
        start = DateTime(today.year, today.month, 1);
      case 5: // 上月
        start = DateTime(today.year, today.month - 1, 1);
        end = DateTime(today.year, today.month, 0);
      case 6: // 今年
        start = DateTime(today.year, 1, 1);
      default: // 去年
        start = DateTime(today.year - 1, 1, 1);
        end = DateTime(today.year, 0, 0);
    }
    setState(() {
      _start = start;
      _end = end;
      _leftMonth = DateTime(start.year, start.month);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final today = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);

    final left = _leftMonth;
    final right = DateTime(left.year, left.month + 1);

    final calendar = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _monthGrid(context, left, todayDay)),
        if (wide) ...[
          const SizedBox(width: NasTokens.spaceMd),
          Expanded(child: _monthGrid(context, right, todayDay)),
        ],
      ],
    );

    final presets = <(String, int)>[
      (tr('photo.date.today'), 0),
      (tr('photo.date.yesterday'), 1),
      (tr('photo.date.last7'), 2),
      (tr('photo.date.last30'), 3),
      (tr('photo.date.thisMonth'), 4),
      (tr('photo.date.lastMonth'), 5),
      (tr('photo.date.thisYear'), 6),
      (tr('photo.date.lastYear'), 7),
    ];

    return AlertDialog(
      title: Text(tr('photo.album.pickDate')),
      content: SizedBox(
        width: wide ? 720 : 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 快捷预设：宽屏放上面一行也能接受，比侧栏省空间
            Wrap(
              spacing: NasTokens.spaceXs,
              runSpacing: NasTokens.spaceXs,
              children: [
                for (final (label, key) in presets)
                  ActionChip(
                    label: Text(label, style: const TextStyle(fontSize: NasTokens.fontCaption)),
                    onPressed: () => _applyPreset(key),
                    // 日期预设胶囊走面板材质，别用默认近黑底
                    backgroundColor: context.nasStyle.panelColor,
                    side: BorderSide(color: context.nasStyle.panelBorderColor),
                  ),
                ActionChip(
                  label: Text(
                    tr('photo.date.clear'),
                    style: const TextStyle(fontSize: NasTokens.fontCaption),
                  ),
                  onPressed: () => setState(() {
                    _start = null;
                    _end = null;
                  }),
                  backgroundColor: context.nasStyle.panelColor,
                  side: BorderSide(color: context.nasStyle.panelBorderColor),
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceSm),
            // 月份头：年 / 月 两个下拉 + 逐月箭头
            Row(
              children: [
                IconButton(
                  onPressed: () => _shiftMonth(-1),
                  icon: const Icon(Icons.chevron_left),
                  visualDensity: VisualDensity.compact,
                ),
                DropdownButton<int>(
                  value: left.year,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (var y = today.year + 1; y >= 1970; y -= 1)
                      DropdownMenuItem(value: y, child: Text('$y')),
                  ],
                  onChanged: (y) {
                    if (y == null) return;
                    setState(() => _leftMonth = DateTime(y, _leftMonth.month));
                  },
                ),
                const SizedBox(width: NasTokens.spaceXs),
                DropdownButton<int>(
                  value: left.month,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (var m = 1; m <= 12; m += 1)
                      DropdownMenuItem(value: m, child: Text('$m 月')),
                  ],
                  onChanged: (m) {
                    if (m == null) return;
                    setState(() => _leftMonth = DateTime(_leftMonth.year, m));
                  },
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => _shiftMonth(1),
                  icon: const Icon(Icons.chevron_right),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceXs),
            calendar,
            const SizedBox(height: NasTokens.spaceSm),
            Text(
              _rangeLabel(),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          // 只选了起点时按单日区间处理：比禁用按钮更少一次点击
          onPressed: _start == null
              ? null
              : () => Navigator.pop(
                  context,
                  DateTimeRange(start: _start!, end: _end ?? _start!),
                ),
          child: Text(tr('common.ok')),
        ),
      ],
    );
  }

  String _rangeLabel() {
    String f(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    if (_start == null) return tr('photo.date.none');
    if (_end == null) return '${f(_start!)} ~ …';
    final days = _end!.difference(_start!).inDays + 1;
    return '${f(_start!)} ~ ${f(_end!)}（${tr('photo.date.days', {'n': '$days'})}）';
  }

  Widget _monthGrid(BuildContext context, DateTime month, DateTime today) {
    final scheme = Theme.of(context).colorScheme;
    final first = DateTime(month.year, month.month, 1);
    // Dart 的 weekday：周一 = 1 … 周日 = 7；表头从周一起排，所以减 1
    final lead = first.weekday - 1;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final cells = <DateTime?>[
      for (var i = 0; i < lead; i += 1) null,
      for (var d = 1; d <= days; d += 1) DateTime(month.year, month.month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: NasTokens.spaceXs),
          child: Text(
            '${month.year} 年 ${month.month} 月',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Row(
          children: [
            for (final w in ['一', '二', '三', '四', '五', '六', '日'])
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        for (var r = 0; r < cells.length ~/ 7; r += 1)
          Row(
            children: [
              for (var c = 0; c < 7; c += 1)
                Expanded(child: _dayCell(context, cells[r * 7 + c], today, scheme)),
            ],
          ),
      ],
    );
  }

  Widget _dayCell(
    BuildContext context,
    DateTime? day,
    DateTime today,
    ColorScheme scheme,
  ) {
    if (day == null) return const SizedBox(height: 34);
    final isStart = _start != null && _sameDay(day, _start!);
    final isEnd = _end != null && _sameDay(day, _end!);
    final inRange =
        _start != null && _end != null && day.isAfter(_start!) && day.isBefore(_end!);
    final isEdge = isStart || isEnd;
    final isToday = _sameDay(day, today);

    return SizedBox(
      height: 34,
      child: InkWell(
        onTap: () => _pickDay(day),
        child: Container(
          margin: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            color: isEdge
                ? scheme.primary
                : inRange
                    ? scheme.primary.withValues(alpha: 0.14)
                    : null,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  fontWeight: isEdge ? FontWeight.w700 : FontWeight.w400,
                  color: isEdge
                      ? scheme.onPrimary
                      : day.weekday >= 6
                          ? scheme.primary.withValues(alpha: 0.75)
                          : scheme.onSurface,
                ),
              ),
              // 今天：右下角一个小点，不抢区间的视觉
              if (isToday)
                Positioned(
                  bottom: 2,
                  child: Container(
                    width: 3,
                    height: 3,
                    decoration: BoxDecoration(
                      color: isEdge ? scheme.onPrimary : scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
