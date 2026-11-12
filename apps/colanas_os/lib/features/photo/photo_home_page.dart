import 'dart:math' as math;
import 'dart:ui' as ui;
import '../../shell/app_widgets.dart';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 相册首页看板。
///
/// 一块看板回答「这一整库照片长什么样」：那年今日、发现新的记忆、几个常用入口、
/// 总量统计、拍摄时光（环形图 + 热力图）、足迹与人物。
class PhotoHomePage extends StatefulWidget {
  const PhotoHomePage({
    super.key,
    this.embedded = false,
    required this.onNavigate,
  });

  final bool embedded;
  final ValueChanged<String> onNavigate;

  @override
  State<PhotoHomePage> createState() => _PhotoHomePageState();
}

class _PhotoHomePageState extends State<PhotoHomePage> {
  bool _loading = true;
  String? _error;
  PhotoHomeSummary? _summary;
  List<PhotoChapterPage> _newMemories = const [];
  List<PhotoItem> _recent = const [];

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  String _thumb(String path, {int size = 480}) => _media.thumbnail(path, size: size);

Map<String, String> get _imageHeaders {
  final token = ApiSession.instance.token;
  return token == null ? const {} : {'Authorization': 'Bearer $token'};
}

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await ApiSession.instance.client.photoHomeSummary();
      final recent = await ApiSession.instance.client.photoTimeline(limit: 8);
      final year = DateTime.now().year;
      final books = await Future.wait([
        ApiSession.instance.client.photoChapterBook(year: year, locale: 'zh-CN'),
        ApiSession.instance.client.photoChapterBook(year: year - 1, locale: 'zh-CN'),
      ]);
      // 先收齐符合要求的日子；服务端按日期升序返回，以前提前截 3 条＝常年同样三张。
      // 现在按封面质量分档，优先「横屏 + 前 5 人脸」，同档内每次打开随机轮换。
      final candidates = <PhotoChapterPage>[];
      for (final book in books) {
        for (final day in book.days) {
          if (day.photoCount >= 6 && day.place.isNotEmpty) {
            candidates.add(day);
          }
        }
      }
      final rnd = math.Random(DateTime.now().microsecondsSinceEpoch);
      final groups = <int, List<PhotoChapterPage>>{};
      for (final day in candidates) {
        // coverScore：6 横+top5人脸 / 5 竖+top5 / 4 横+有人 / 3 竖+有人 /
        //             2 横无人 / 1 竖无人。横屏整体压过竖屏，内部再按人脸档。
        final rank = switch (day.coverScore ?? 0) {
          6 => 0,
          4 => 1,
          2 => 2,
          5 => 3,
          3 => 4,
          _ => 5,
        };
        groups.putIfAbsent(rank, () => <PhotoChapterPage>[]).add(day);
      }
      final picks = <PhotoChapterPage>[];
      for (var rank = 0; rank < 6 && picks.length < 4; rank += 1) {
        final pool = groups[rank];
        if (pool == null || pool.isEmpty) continue;
        pool.shuffle(rnd);
        for (final day in pool) {
          if (picks.length >= 4) break;
          picks.add(day);
        }
      }
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _newMemories = picks;
        _recent = recent.items;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(tr('photo.home.title')),
              actions: [
                NasRefreshButton(onPressed: _load),
              ],
            ),
      body: _loading
          ? const NasLoading()
          : _error != null
              ? NasErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    final s = _summary!;
    final empty = s.library.photos == 0;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
      children: [
        if (!widget.embedded) _header(),
        const SizedBox(height: 14),
        _searchBar(),
        if (empty) ...[
          const SizedBox(height: 24),
          _emptyCard(),
        ] else ...[
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionHeader(
              tr('photo.home.recent'),
              tr('photo.home.recentSub'),
              onMore: () => widget.onNavigate('timeline'),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _recent.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final item = _recent[i];
                  return SizedBox(
                    width: 176,
                    child: NasCoverImage(
                      url: _thumb(item.path, size: 360),
                      headers: _imageHeaders,
                      cacheWidth: 360,
                      fit: BoxFit.cover,
                      borderRadius: 12,
                    ),
                  );
                },
              ),
            ),
          ],
          if (s.onThisDay.isNotEmpty) ...[
            const SizedBox(height: 24),
            _sectionHeader(
              tr('photo.home.onThisDay'),
              tr('photo.home.onThisDaySub'),
              onMore: () => widget.onNavigate('onThisDay'),
            ),
            const SizedBox(height: 10),
            _onThisDay(s.onThisDay),
          ],
          if (_newMemories.isNotEmpty) ...[
            const SizedBox(height: 22),
            _sectionHeader(
              tr('photo.home.newMemories'),
              tr('photo.home.newMemoriesSub'),
              onMore: () => widget.onNavigate('memory'),
            ),
            const SizedBox(height: 10),
            _newMemoryRow(),
          ],
          const SizedBox(height: 22),
          _promptBar(
            icon: Icons.event_outlined,
            title: tr('photo.home.keepMoment'),
            subtitle: tr('photo.home.keepMomentSub'),
            color: const Color(0xFF2FB6A8),
            onTap: () => widget.onNavigate('timeline'),
          ),
          const SizedBox(height: 10),
          _promptBar(
            icon: Icons.insights_outlined,
            title: tr('photo.home.yearRecap'),
            subtitle: tr('photo.home.yearRecapSub', {'year': '${DateTime.now().year}'}),
            color: Theme.of(context).colorScheme.primary,
            onTap: () => widget.onNavigate('year'),
          ),
          const SizedBox(height: 10),
          _promptBar(
            icon: Icons.place_outlined,
            title: tr('photo.home.mapTime'),
            subtitle: tr('photo.home.mapTimeSub'),
            color: const Color(0xFFE08A3C),
            onTap: () => widget.onNavigate('footprint'),
          ),
          const SizedBox(height: 22),
          _libraryCard(s),
          const SizedBox(height: 14),
          _shotTimeCard(s),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, c) {
              final cards = [_footprintCard(s), _peopleCard(s)];
              if (c.maxWidth < 860) {
                return Column(
                  children: [
                    for (final card in cards) ...[card, const SizedBox(height: 14)],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 14),
                  Expanded(child: cards[1]),
                ],
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('photo.home.title'), style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          tr('photo.home.subtitle'),
          style: TextStyle(
            fontSize: NasTokens.fontBody,
            color: context.nasTextSecondary,
          ),
        ),
      ],
    );
  }

  Widget _searchBar() {
    final scheme = Theme.of(context).colorScheme;
    // 与时间轴搜索框同一套材质：极光风格的半透明面板色 + 面板描边。
    // 之前用 surfaceContainerHigh（不透明合成色），深色下就是一块纯黑，
    // 和整页极光背景割裂；换成 panelColor 后背景光晕能透上来。
    final style = context.nasStyle;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => widget.onNavigate('timeline'),
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: style.panelColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: style.panelBorderColor),
        ),
        child: Row(
          children: [
            Icon(Icons.search, color: context.nasTextSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr('photo.home.searchHint'),
                style: TextStyle(color: context.nasTextSecondary),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'AI',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyCard() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(Icons.add_photo_alternate_outlined, size: 42, color: context.nasTextSecondary),
          const SizedBox(height: 12),
          Text(tr('photo.home.empty'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            tr('photo.home.emptyHint'),
            textAlign: TextAlign.center,
            style: TextStyle(color: context.nasTextSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton.tonal(
            onPressed: () => widget.onNavigate('source'),
            child: Text(tr('photo.source.add')),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, String subtitle, {VoidCallback? onMore}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ],
          ),
        ),
        if (onMore != null)
          TextButton(onPressed: onMore, child: Text(tr('photo.home.viewAll'))),
      ],
    );
  }

  Widget _onThisDay(List<PhotoHomeOnThisDay> days) {
    // 只画真实存在的年份，不拿「查看全部年份」占位块去补格子：
    // 往年的今天没照片就空着，全部年份走标题栏右上角那个「查看全部」。
    final shown = days.take(4).toList(growable: false);
    return _fourColumnRow([
      for (final d in shown)
        _memoryTile(
          height: 240,
          path: d.items.isEmpty ? '' : d.items.first.path,
          title: tr('photo.home.yearPhotos', {
            'year': '${d.year}',
            'count': '${d.photoCount}',
          }),
          subtitle: d.date,
          onTap: () => widget.onNavigate('onThisDay'),
        ),
    ]);
  }

  Widget _newMemoryRow() {
    return _fourColumnRow([
      for (final d in _newMemories)
        _memoryTile(
          path: d.cover.path,
          title: d.date,
          subtitle: tr('photo.home.memorySub', {
            'count': '${d.photoCount}',
            'place': d.place,
          }),
          onTap: () => widget.onNavigate('memory'),
        ),
    ]);
  }

  /// 固定 4 列：不足 4 个右侧留空，不拉伸单个卡片
  /// （用 Expanded 会把只有 1 张的卡片撑成整行大图）。
  Widget _fourColumnRow(List<Widget> cards) {
    return LayoutBuilder(
      builder: (context, c) {
        // 4 列 + 3 道 12 间距，正好铺满可用宽度，不会横向溢出
        final w = math.max(0.0, (c.maxWidth - 36) / 4);
        final shown = cards.take(4).toList(growable: false);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 4; i += 1) ...[
              SizedBox(width: w, child: i < shown.length ? shown[i] : null),
              if (i < 3) const SizedBox(width: 12),
            ],
          ],
        );
      },
    );
  }

  Widget _memoryTile({
    required String path,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    double height = 176,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (path.isNotEmpty) ...[
              // 背景：同一张图 cover + 模糊，填满卡片（contain 两侧会留白）
              Positioned.fill(
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                  child: NasCoverImage(
                    url: _thumb(path, size: 240),
                    headers: _imageHeaders,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              // 前景：完整等比显示。原来只有 cover，竖图被裁掉一大半，
              // 用户看到的就是「只看到一小部分」（2026-11-04）。
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: NasCoverImage(
                    url: _thumb(path, size: 720),
                    headers: _imageHeaders,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ] else
              ColoredBox(color: scheme.surfaceContainerHighest),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xC8000000)],
                  stops: [0.4, 1],
                ),
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _promptBar({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: context.nasTextSecondary),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.25)),
      ),
      child: child,
    );
  }

  Widget _libraryCard(PhotoHomeSummary s) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('photo.home.library'), style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      tr('photo.home.librarySub'),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => widget.onNavigate('folders'),
                child: Text(tr('photo.home.viewStorage')),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 26,
            runSpacing: 10,
            children: [
              _stat(tr('photo.home.stats.photos', {'count': '${s.library.photos}'})),
              _stat(tr('photo.home.stats.today', {'count': '${s.library.todayNew}'})),
              _stat(tr('photo.home.stats.bytes', {'bytes': formatBytes(s.library.bytes)})),
              _stat(tr('photo.home.stats.videos', {'count': '${s.library.videos}'})),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String text) => Text(text, style: const TextStyle(fontWeight: FontWeight.w600));

  Widget _shotTimeCard(PhotoHomeSummary s) {
    final years = s.heat.byYear;
    final topYears = years.take(4).toList();
    final rest = years.skip(4).fold<int>(0, (sum, y) => sum + (y['count'] as int));
    final peak = s.heat.peakMonth;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('photo.home.shotTime'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(
            tr('photo.home.shotTimeSub', {
              'count': '${s.heat.total}',
              'days': '${s.heat.activeDays}',
            }),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, c) {
              final donut = SizedBox(
                width: 168,
                height: 168,
                child: CustomPaint(
                  painter: _DonutPainter(
                    segments: [
                      for (final y in topYears)
                        (y['count'] as int) / math.max(1, s.heat.total),
                      if (rest > 0) rest / math.max(1, s.heat.total),
                    ],
                    centerText: '${s.heat.total}',
                    centerHint: tr('photo.home.photos'),
                    colors: Theme.of(context).colorScheme,
                  ),
                ),
              );
              final legend = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < topYears.length; i += 1)
                    _legendRow(
                      '${topYears[i]['year']}',
                      _pct(topYears[i]['count'] as int, s.heat.total),
                      i,
                    ),
                  if (rest > 0)
                    _legendRow(tr('photo.home.otherYears'), _pct(rest, s.heat.total), topYears.length),
                  if (peak != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      tr('photo.home.peakMonth', {
                        'year': '${peak['year']}',
                        'month': '${peak['month']}',
                        'count': '${peak['count']}',
                      }),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ],
              );
              if (c.maxWidth < 560) {
                return Column(
                  children: [donut, const SizedBox(height: 12), legend],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  donut,
                  const SizedBox(width: 20),
                  Expanded(child: legend),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          _HeatMatrix(days: s.heat.byDay),
        ],
      ),
    );
  }

  String _pct(int count, int total) =>
      total <= 0 ? '0%' : '${(count / total * 100).round()}%';

  Widget _legendRow(String label, String pct, int index) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.primary.withValues(alpha: (1 - index * 0.18).clamp(0.35, 1.0).toDouble());
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
          Text(
            pct,
            style: TextStyle(
              fontSize: 12,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _footprintCard(PhotoHomeSummary s) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('photo.home.footprint'), style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      tr('photo.home.footprintSub'),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => widget.onNavigate('footprint'),
                child: Text(tr('photo.home.viewFootprint')),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _foot(s.footprint.cities, tr('photo.home.cities')),
              _foot(s.footprint.places, tr('photo.home.places')),
              _foot(s.footprint.days, tr('photo.home.days')),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            tr('photo.home.footprintHint'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _foot(int value, String label) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _peopleCard(PhotoHomeSummary s) {
    final people = s.people.items;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('photo.home.people'), style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      tr('photo.home.peopleSub'),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => widget.onNavigate('faces'),
                child: Text(tr('photo.home.allPeople')),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (people.isEmpty)
            Text(
              tr('photo.home.noPeople'),
              style: TextStyle(color: context.nasTextSecondary),
            )
          else
            Wrap(
              spacing: 18,
              runSpacing: 12,
              children: [
                for (final p in people.take(5))
                  SizedBox(
                    width: 82,
                    child: Column(
                      children: [
                        ClipOval(
                          child: SizedBox(
                            width: 52,
                            height: 52,
                            child: p.coverPath == null
                                ? ColoredBox(
                                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.person_outline),
                                  )
                                : NasCoverImage(url: _thumb(p.coverPath!), headers: _imageHeaders, cacheWidth: 52),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          p.name ?? tr('photo.home.unnamed'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          tr('photo.home.photoCount', {'count': '${p.size}'}),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          if (s.people.pending > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('photo.home.pendingFaces', {'count': '${s.people.pending}'}),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => widget.onNavigate('faces'),
                  child: Text(tr('photo.home.confirmNow')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.segments,
    required this.centerText,
    required this.centerHint,
    required this.colors,
  });

  final List<double> segments;
  final String centerText;
  final String centerHint;
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = colors.surfaceContainerHighest);
    var start = -math.pi / 2;
    for (var i = 0; i < segments.length; i += 1) {
      final sweep = segments[i] * math.pi * 2;
      if (sweep <= 0) continue;
      paint.color = colors.primary.withValues(alpha: (1 - i * 0.18).clamp(0.35, 1.0).toDouble());
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
    final tp = TextPainter(
      text: TextSpan(
        text: centerText,
        style: TextStyle(
          color: colors.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, size.height / 2 - tp.height));
    final bp = TextPainter(
      text: TextSpan(
        text: centerHint,
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    bp.paint(canvas, Offset((size.width - bp.width) / 2, size.height / 2 + 2));
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.segments != segments || old.centerText != centerText;
}

class _HeatMatrix extends StatelessWidget {
  const _HeatMatrix({required this.days});

  final List<Map<String, dynamic>> days;

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final d in days) {
      counts['${d['date']}'] = (d['count'] as num?)?.toInt() ?? 0;
    }
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();
    final cells = <Widget>[];
    for (var i = 364; i >= 0; i -= 1) {
      final d = today.subtract(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final count = counts[key] ?? 0;
      final alpha = count == 0 ? 0.06 : (0.25 + math.min(0.75, count / 20)).clamp(0.25, 1.0);
      cells.add(
        Tooltip(
          message: '$key · ${count > 0 ? count : 0}',
          waitDuration: const Duration(milliseconds: 400),
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: count == 0
                  ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                  : scheme.primary.withValues(alpha: alpha.toDouble()),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('photo.home.heatHint'),
          style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 2, runSpacing: 2, children: cells),
      ],
    );
  }
}