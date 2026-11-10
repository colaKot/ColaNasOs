import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../core/session.dart';
import 'photo_annual_export.dart';

MediaUrls _urls() => MediaUrls(ApiSession.instance.baseUrl);

Map<String, String> _headers() {
  final token = ApiSession.instance.token;
  return token == null ? const {} : {'Authorization': 'Bearer $token'};
}

String _thumb(String path, {int size = 480}) =>
    _urls().thumbnail(path, size: size);

/// 年度代表作（服务端已保证：前 5 个命名人物各一张 + 其余按时间分散）
class _Pick {
  const _Pick({
    required this.photoId,
    required this.path,
    required this.takenAt,
    required this.reason,
  });

  final String photoId;
  final String path;
  final int takenAt;
  final String reason;

  factory _Pick.fromJson(Map<String, dynamic> json) => _Pick(
    photoId: '${json['photoId'] ?? ''}',
    path: '${json['path'] ?? ''}',
    takenAt: (json['takenAt'] as num?)?.toInt() ?? 0,
    reason: '${json['reason'] ?? ''}',
  );
}

/// 年度报告：正常滚动、普通页面样式，九段内容紧凑排列。
class PhotoAnnualReport extends StatefulWidget {
  const PhotoAnnualReport({super.key, this.initialYear});

  final int? initialYear;

  @override
  State<PhotoAnnualReport> createState() => _PhotoAnnualReportState();
}

class _ReportData {
  const _ReportData({
    required this.report,
    this.stats,
    this.calendar,
    this.chapters,
    this.home,
  });

  final PhotoYearReport report;
  final PhotoStatsResponse? stats;
  final PhotoCalendarResponse? calendar;
  final PhotoChapterBook? chapters;
  final PhotoHomeSummary? home;
}

class _PhotoAnnualReportState extends State<PhotoAnnualReport> {
  late int _year;
  bool _loading = true;
  bool _exporting = false;
  String? _error;
  _ReportData? _data;
  final _exportKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear ?? DateTime.now().year;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object>([
        ApiSession.instance.client.photoYearReport(year: _year, locale: 'zh-CN'),
        ApiSession.instance.client.photoStats(),
        ApiSession.instance.client.photoCalendar(year: _year),
        ApiSession.instance.client.photoChapterBook(
          year: _year,
          locale: 'zh-CN',
        ),
        ApiSession.instance.client.photoHomeSummary(),
      ]);
      if (!mounted) return;
      setState(() {
        _data = _ReportData(
          report: results[0] as PhotoYearReport,
          stats: results[1] as PhotoStatsResponse,
          calendar: results[2] as PhotoCalendarResponse,
          chapters: results[3] as PhotoChapterBook,
          home: results[4] as PhotoHomeSummary,
        );
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _shiftYear(int delta) {
    final max = DateTime.now().year;
    final next = (_year + delta).clamp(1990, max);
    if (next == _year) return;
    setState(() => _year = next);
    _load();
  }

  Future<void> _export() async {
    if (_exporting || _data == null) return;
    setState(() => _exporting = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final object = _exportKey.currentContext?.findRenderObject();
      if (object is! RenderRepaintBoundary) return;
      final image = await object.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final saved = await saveAnnualReportPng(
        data.buffer.asUint8List(),
        '年度总结_$_year.png',
      );
      if (mounted && saved != null) {
        NasSnack.show(context, '已保存长图：$saved');
      }
    } catch (e) {
      if (mounted) NasSnack.show(context, '$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---------------------------------------------------------------- 小工具

  List<PhotoLabelCount> _top(List<PhotoLabelCount> all, int n) {
    final list = [...all]..sort((a, b) => b.count.compareTo(a.count));
    return list.where((e) => e.count > 0).take(n).toList();
  }

  /// 九张代表作：优先用服务端 picks（前 5 人物 + 时间分散），老服务端回退到章节封面。
  List<_Pick> _picks(_ReportData d) {
    final list = <_Pick>[];
    for (final row in d.report.picks ?? const <Map<String, dynamic>>[]) {
      final pick = _Pick.fromJson(row);
      if (pick.path.trim().isNotEmpty) list.add(pick);
    }
    if (list.isNotEmpty) {
      list.sort((a, b) => a.takenAt.compareTo(b.takenAt));
      return list;
    }
    final seen = <String>{};
    for (final day in d.chapters?.days ?? const <PhotoChapterPage>[]) {
      for (final p in [day.cover, ...day.picks]) {
        if (p.path.trim().isEmpty || !seen.add(p.path)) continue;
        list.add(
          _Pick(photoId: p.id, path: p.path, takenAt: p.takenAt, reason: ''),
        );
        if (list.length >= 9) break;
      }
      if (list.length >= 9) break;
    }
    return list;
  }

  String _stamp(int? seconds) {
    if (seconds == null || seconds <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    return '${d.year}/${d.month}/${d.day}';
  }

  // ---------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final d = _data!;
    return Column(
      children: [
        _yearBar(context),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            child: LayoutBuilder(
              builder: (context, cons) {
                // 超宽屏别把内容拉成一条长带：限宽 820 居中，图片尺度才稳定
                final width = math.min(cons.maxWidth, 820.0);
                return Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: width,
                    child: RepaintBoundary(
                      key: _exportKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _cover(context, d),
                          _tally(context, d),
                          _graph(context, d),
                          _highlight(context, d),
                          _wall(context, d),
                          _footprint(context, d),
                          _busiest(context, d),
                          _seasons(context, d),
                          _ending(context, d),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _yearBar(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: '上一年',
            visualDensity: VisualDensity.compact,
            onPressed: () => _shiftYear(-1),
            icon: const Icon(Icons.chevron_left, size: 20),
          ),
          Text(
            '$_year 年度总结',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          IconButton(
            tooltip: '下一年',
            visualDensity: VisualDensity.compact,
            onPressed: () => _shiftYear(1),
            icon: const Icon(Icons.chevron_right, size: 20),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 17),
            label: Text(_exporting ? '导出中' : '保存长图'),
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, {Widget? trailing, required Widget child}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _card(BuildContext context, {required Widget child, EdgeInsets? padding}) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 指标卡：窄屏 2×2，宽屏一行四个
  Widget _metricGrid(BuildContext context, List<(String, String)> items) {
    return LayoutBuilder(
      builder: (context, cons) {
        final cols = cons.maxWidth >= 420 ? items.length : 2;
        const gap = 8.0;
        final width = (cons.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in items)
              SizedBox(
                width: width,
                child: _metric(context, item.$1, item.$2),
              ),
          ],
        );
      },
    );
  }

  // 1 封面 ---------------------------------------------------------------

  Widget _cover(BuildContext context, _ReportData d) {
    final theme = Theme.of(context);
    final picks = _picks(d);
    final total = d.report.totalPhotos;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$total',
                style: theme.textTheme.displaySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '个瞬间',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '这一年，你用镜头收藏了 $total 个珍贵瞬间。',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          if (picks.isNotEmpty) ...[
            const SizedBox(height: 12),
            _pickStrip(context, picks),
          ],
        ],
      ),
    );
  }

  Widget _pickStrip(BuildContext context, List<_Pick> picks) {
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: picks.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) => ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 100,
            child: NasCoverImage(
              url: _thumb(picks[i].path, size: 400),
              headers: _headers(),
              icon: Icons.image_outlined,
              cacheWidth: 320,
            ),
          ),
        ),
      ),
    );
  }

  // 2 时光账本 -----------------------------------------------------------

  Widget _tally(BuildContext context, _ReportData d) {
    final theme = Theme.of(context);
    final r = d.report;
    final months = List<int>.generate(12, (i) {
      final hit = r.months.where((m) => m.month == i + 1);
      return hit.isEmpty ? 0 : hit.first.count;
    });
    final byDay = <String, int>{};
    for (final row in d.stats?.byDay ?? const <Map<String, dynamic>>[]) {
      final date = '${row['date'] ?? ''}';
      if (date.startsWith('${r.year}-')) {
        byDay[date] = (row['count'] as num?)?.toInt() ?? 0;
      }
    }
    final active = byDay.values.where((n) => n > 0).length;
    final maxMonth = months.fold<int>(1, math.max);
    return _section(
      context,
      '时光账本',
      trailing: Text(
        '$active 天拍过',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      child: Column(
        children: [
          _metricGrid(context, [
            ('照片', '${r.totalPhotos}'),
            ('地点', '${r.placeCount}'),
            ('人物', '${r.people.length}'),
            ('场景', '${r.scenes.length}'),
          ]),
          const SizedBox(height: 10),
          _card(
            context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 72,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < 12; i++) ...[
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                height: 4 + 46 * (months[i] / maxMonth),
                                decoration: BoxDecoration(
                                  color: months[i] == 0
                                      ? theme.colorScheme.outlineVariant
                                      : theme.colorScheme.primary.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${i + 1}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 9,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (i < 11) const SizedBox(width: 2),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 54,
                  child: LayoutBuilder(
                    builder: (context, cons) => CustomPaint(
                      size: Size(cons.maxWidth, 54),
                      painter: _HeatPainter(
                        days: byDay,
                        year: r.year,
                        empty: theme.colorScheme.outlineVariant,
                        accent: theme.colorScheme.primary,
                      ),
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

  // 3 生活图谱 -----------------------------------------------------------

  Widget _graph(BuildContext context, _ReportData d) {
    final theme = Theme.of(context);
    final items = _top([...d.report.scenes, ...d.report.activities], 5);
    final total = items.fold<int>(0, (s, e) => s + e.count);
    final base = theme.colorScheme.primary;
    final colors = [
      base,
      Color.lerp(base, theme.colorScheme.surface, 0.25)!,
      Color.lerp(base, theme.colorScheme.surface, 0.45)!,
      Color.lerp(base, theme.colorScheme.surface, 0.62)!,
      Color.lerp(base, theme.colorScheme.surface, 0.78)!,
    ];
    return _section(
      context,
      '生活图谱',
      child: items.isEmpty
          ? _empty(context, '还没跑过场景 / 活动识别')
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 96,
                  height: 96,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomPaint(
                        size: const Size(96, 96),
                        painter: _DonutPainter(
                          values: [for (final e in items) e.count],
                          colors: colors,
                        ),
                      ),
                      Text(
                        '$total',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: colors[i],
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  items[i].label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              Text(
                                '${items[i].count} · ${(items[i].count * 100 / math.max(1, total)).round()}%',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  // 4 高光时刻 -----------------------------------------------------------

  Widget _highlight(BuildContext context, _ReportData d) {
    final r = d.report;
    final person = _top(r.people, 1);
    final place = r.places.isEmpty ? null : r.places.first;
    return _section(
      context,
      '高光时刻',
      child: Column(
        children: [
          _row(
            context,
            Icons.person_outline,
            '出镜最多的人',
            person.isEmpty ? '—' : person.first.label,
            person.isEmpty ? '还没有命名的人脸' : '${person.first.count} 张照片',
          ),
          const SizedBox(height: 8),
          _row(
            context,
            Icons.place_outlined,
            '打卡最多的地点',
            place == null ? '—' : (place.name.isEmpty ? place.geohash5 : place.name),
            place == null ? '没有带位置的照片' : '${place.count} 张照片',
          ),
          const SizedBox(height: 8),
          _row(
            context,
            Icons.first_page_outlined,
            '年度的第一张',
            _stamp(r.earliest),
            '从这里开始',
          ),
          const SizedBox(height: 8),
          _row(
            context,
            Icons.last_page_outlined,
            '年度的最后一张',
            _stamp(r.latest),
            '到这里收尾',
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String label,
    String value,
    String sub,
  ) {
    final theme = Theme.of(context);
    return _card(
      context,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Text(
            sub,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // 5 照片墙 -------------------------------------------------------------

  Widget _wall(BuildContext context, _ReportData d) {
    final theme = Theme.of(context);
    final picks = _picks(d);
    return _section(
      context,
      '九张代表这一年',
      trailing: Text(
        '含常出现的 5 位人物',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      child: picks.isEmpty
          ? _empty(context, '这一年还没有照片')
          : LayoutBuilder(
              builder: (context, cons) {
                final cols = cons.maxWidth >= 520 ? 4 : 3;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: picks.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    childAspectRatio: 1,
                  ),
                  itemBuilder: (context, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        NasCoverImage(
                          url: _thumb(picks[i].path, size: 640),
                          headers: _headers(),
                          icon: Icons.image_outlined,
                          cacheWidth: 520,
                        ),
                        if (picks[i].reason.isNotEmpty)
                          Positioned(
                            left: 3,
                            bottom: 3,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                picks[i].reason,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  // 6 足迹 ---------------------------------------------------------------

  Widget _footprint(BuildContext context, _ReportData d) {
    final f = d.home?.footprint;
    final places = ([...d.report.places]
          ..sort((a, b) => b.count.compareTo(a.count)))
        .take(6)
        .toList();
    return _section(
      context,
      '步履所至',
      child: Column(
        children: [
          _metricGrid(context, [
            ('城市', '${f?.cities ?? 0}'),
            ('地点', '${f?.places ?? 0}'),
            ('在外', '${f?.days ?? 0}'),
          ]),
          if (places.isNotEmpty) ...[
            const SizedBox(height: 8),
            _card(
              context,
              child: Column(
                children: [
                  for (var i = 0; i < places.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: i == places.length - 1 ? 0 : 6,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 5,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              places[i].name.isEmpty
                                  ? places[i].geohash5
                                  : places[i].name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          Text(
                            '${places[i].count} 张',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 7 最忙的一天 ---------------------------------------------------------

  Widget _busiest(BuildContext context, _ReportData d) {
    final theme = Theme.of(context);
    final busiest = _top(d.report.busiestDays, 1);
    if (busiest.isEmpty) return const SizedBox.shrink();
    final day = busiest.first;
    final date = day.label.length >= 10 ? day.label.substring(0, 10) : day.label;
    final chapters =
        d.chapters?.days.where((e) => e.date == date).toList() ?? [];
    final picks = chapters.isEmpty ? <PhotoMemoryPick>[] : chapters.first.picks;
    return _section(
      context,
      '最忙的一天',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                date,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${day.count} 张',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '全年最密集的一天',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (picks.isNotEmpty) ...[
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, cons) {
                final cols = cons.maxWidth >= 520 ? 5 : 4;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: math.min(picks.length, 9),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    childAspectRatio: 1,
                  ),
                  itemBuilder: (context, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: NasCoverImage(
                      url: _thumb(picks[i].path, size: 440),
                      headers: _headers(),
                      icon: Icons.image_outlined,
                      cacheWidth: 360,
                    ),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  // 8 四季 ---------------------------------------------------------------

  Widget _seasons(BuildContext context, _ReportData d) {
    final theme = Theme.of(context);
    final months = List<int>.generate(12, (i) {
      final hit = d.report.months.where((m) => m.month == i + 1);
      return hit.isEmpty ? 0 : hit.first.count;
    });
    int sum(List<int> idx) => idx.fold<int>(0, (s, i) => s + months[i]);
    final seasons = <(String, String, int)>[
      ('春', '3 — 5 月', sum([2, 3, 4])),
      ('夏', '6 — 8 月', sum([5, 6, 7])),
      ('秋', '9 — 11 月', sum([8, 9, 10])),
      ('冬', '12 — 2 月', sum([11, 0, 1])),
    ];
    return _section(
      context,
      '四时之景',
      child: LayoutBuilder(
        builder: (context, cons) {
          final cols = cons.maxWidth >= 420 ? 4 : 2;
          const gap = 8.0;
          final width = (cons.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final s in seasons)
                SizedBox(
                  width: width,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 8,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.32,
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.$1,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          s.$2,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${s.$3} 个瞬间',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // 9 收尾 ---------------------------------------------------------------

  Widget _ending(BuildContext context, _ReportData d) {
    final theme = Theme.of(context);
    final words = _top([...d.report.scenes, ...d.report.activities], 10);
    return _section(
      context,
      '年度关键词',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (words.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < words.length; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: i == 0
                          ? theme.colorScheme.primary
                          : theme.colorScheme.surfaceContainerHighest.withValues(
                              alpha: 0.5,
                            ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      words[i].label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: i == 0
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: i == 0 ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          _card(
            context,
            child: Text(
              '${d.report.year} 年，你拍了 ${d.report.totalPhotos} 张照片，'
              '走过 ${d.report.placeCount} 个地点，和 ${d.report.people.length} 个人同框。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 全年活跃度小格（周一为一列之始）
class _HeatPainter extends CustomPainter {
  _HeatPainter({
    required this.days,
    required this.year,
    required this.empty,
    required this.accent,
  });

  final Map<String, int> days;
  final int year;
  final Color empty;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final start = DateTime(year, 1, 1);
    final totalDays = DateTime(year, 12, 31).difference(start).inDays + 1;
    final offset = start.weekday - 1;
    final weeks = ((offset + totalDays) / 7).ceil();
    const gap = 2.0;
    final cell = math.min(
      (size.width - (weeks - 1) * gap) / weeks,
      (size.height - 6 * gap) / 7,
    );
    if (cell <= 0) return;
    final maxCount = days.values.fold<int>(1, math.max);
    final paint = Paint();
    for (var d = 0; d < totalDays; d++) {
      final date = start.add(Duration(days: d));
      final key =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final n = days[key] ?? 0;
      final col = (offset + d) ~/ 7;
      final row = date.weekday - 1;
      paint.color = n == 0
          ? empty.withValues(alpha: 0.45)
          : accent.withValues(alpha: (0.25 + 0.75 * (n / maxCount)).clamp(0.2, 1.0));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(col * (cell + gap), row * (cell + gap), cell, cell),
          const Radius.circular(1.2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HeatPainter old) =>
      old.year != year || !identical(old.days, days);
}

/// 环形图
class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.values, required this.colors});

  final List<int> values;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (s, v) => s + v);
    final rect = Rect.fromLTWH(8, 8, size.width - 16, size.height - 16);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14;
    var start = -math.pi / 2;
    if (total <= 0) {
      paint.color = colors.first;
      canvas.drawArc(rect, 0, math.pi * 2, false, paint);
      return;
    }
    for (var i = 0; i < values.length; i++) {
      final sweep = math.pi * 2 * values[i] / total;
      paint.color = colors[i % colors.length];
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      !identical(old.values, values);
}
