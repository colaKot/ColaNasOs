import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 年视图：年份卡片 → 该年的 12 个月。
///
/// 此前右侧年份刻度点一下就"从该年 1 月 1 日往后拉全部"（没有上界，会串到今年），
/// 而"年度回顾"是另一套独立的年度报告页。这里补的是**浏览用的时间刻度**：
/// 先看哪年有东西，再看哪个月有东西，点下去时间轴就缩到那个区间。
class PhotoYearViewPage extends StatefulWidget {
  const PhotoYearViewPage({super.key, required this.onPick});

  /// 选中后回调；month 为 null 表示整年
  final void Function(int year, int? month) onPick;

  @override
  State<PhotoYearViewPage> createState() => _PhotoYearViewPageState();
}

class _PhotoYearViewPageState extends State<PhotoYearViewPage> {
  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  Map<String, String> get _imageHeaders {
    final token = ApiSession.instance.token;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  bool _loading = true;
  String? _error;
  List<({int year, int count})> _years = const [];
  int? _selectedYear;
  PhotoCalendarResponse? _calendar;
  bool _loadingCalendar = false;

  @override
  void initState() {
    super.initState();
    _loadYears();
  }

  Future<void> _loadYears() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.photoStats();
      final maxYear = DateTime.now().year + 1;
      final years = <({int year, int count})>[];
      for (final e in res.byYear) {
        final y = (e['year'] as num?)?.toInt() ?? 0;
        final c = (e['count'] as num?)?.toInt() ?? 0;
        if (y >= 1970 && y <= maxYear && c > 0) years.add((year: y, count: c));
      }
      years.sort((a, b) => b.year.compareTo(a.year));
      if (!mounted) return;
      setState(() {
        _years = years;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _openYear(int year) async {
    setState(() {
      _selectedYear = year;
      _calendar = null;
      _loadingCalendar = true;
    });
    try {
      final res = await ApiSession.instance.client.photoCalendar(year: year);
      if (!mounted) return;
      setState(() {
        _calendar = res;
        _loadingCalendar = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingCalendar = false;
      });
    }
  }

  void _pick(int year, int? month) {
    widget.onPick(year, month);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final year = _selectedYear;
    return Scaffold(
      appBar: AppBar(
        title: Text(year == null ? tr('photo.yearView.title') : '$year'),
        leading: year == null
            ? null
            : IconButton(
                tooltip: tr('photo.yearView.title'),
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _selectedYear = null),
              ),
        actions: [
          if (year != null)
            TextButton(
              onPressed: () => _pick(year, null),
              child: Text(tr('photo.yearView.wholeYear')),
            ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _loadYears)
          : year == null
          ? _yearGrid()
          : _monthGrid(year),
    );
  }

  Widget _yearGrid() {
    if (_years.isEmpty) {
      return NasEmptyState(
        title: tr('photo.yearView.empty'),
        message: tr('photo.yearView.emptyHint'),
        icon: Icons.calendar_view_month,
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        crossAxisSpacing: NasTokens.spaceSm,
        mainAxisSpacing: NasTokens.spaceSm,
        childAspectRatio: 1.6,
      ),
      itemCount: _years.length,
      itemBuilder: (context, i) {
        final y = _years[i];
        return InkWell(
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          onTap: () => _openYear(y.year),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.45),
                ],
              ),
            ),
            padding: const EdgeInsets.all(NasTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${y.year}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  tr('photo.yearView.count', {'count': '${y.count}'}),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _monthGrid(int year) {
    if (_loadingCalendar) return const NasLoading();
    final months = _calendar?.months ?? const [];
    return GridView.builder(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        crossAxisSpacing: NasTokens.spaceSm,
        mainAxisSpacing: NasTokens.spaceSm,
        childAspectRatio: 0.86,
      ),
      itemCount: 12,
      itemBuilder: (context, i) {
        final m = i < months.length ? months[i] : null;
        final count = m?.count ?? 0;
        final cover = m?.coverPath;
        final disabled = count == 0;
        return InkWell(
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          onTap: disabled ? null : () => _pick(year, i + 1),
          child: Opacity(
            opacity: disabled ? 0.45 : 1,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                color: context.nas.surfaceContainerHighest,
                border: Border.all(color: context.nas.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: cover == null
                        ? Icon(
                            Icons.photo_outlined,
                            color: context.nasTextSecondary,
                            size: 28,
                          )
                        : NasCoverImage(
                            url: _media.thumbnail(cover, size: 320),
                            headers: _imageHeaders,
                            cacheWidth: 320,
                            borderRadius: 0,
                            icon: Icons.broken_image_outlined,
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NasTokens.spaceSm,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Text(
                          tr('photo.yearView.month', {'month': '${i + 1}'}),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '$count',
                          style: TextStyle(
                            color: context.nasTextSecondary,
                            fontSize: NasTokens.fontCaption,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
