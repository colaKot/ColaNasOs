import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 相册「记忆」：人生章节 + 候选记忆（确认 / 忽略）。
///
/// 页面组织：顶部是人生章节横向卡片，下面是「我的记忆 / 待确认 / 已忽略」
/// 三态过滤；点人生章节进入对开书本，翻页支持键盘。
class PhotoMemoryPage extends StatefulWidget {
  const PhotoMemoryPage({super.key, this.embedded = false});

  /// 嵌入相册二级导航内容区时不再显示重复的标题栏
  final bool embedded;

  @override
  State<PhotoMemoryPage> createState() => _PhotoMemoryPageState();
}

class _PhotoMemoryPageState extends State<PhotoMemoryPage> {
  bool _loading = true;
  String? _error;
  PhotoMemoryList? _data;
  int _tab = 0;

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
      final data = await ApiSession.instance.client.photoMemories(
        days: 3650,
        minPhotos: 12,
        limit: 40,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        if (_tab == 0 && data.memories.isEmpty && data.candidates.isNotEmpty) {
          _tab = 1;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<PhotoMemoryItem> get _list {
    final data = _data;
    if (data == null) return const [];
    return switch (_tab) {
      1 => data.candidates,
      2 => data.ignored,
      _ => data.memories,
    };
  }

  Future<void> _save(PhotoMemoryItem item) async {
    try {
      await ApiSession.instance.client.photoMemorySave(
        body: PhotoMemorySaveBody(date: item.date, note: item.note),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _ignore(PhotoMemoryItem item) async {
    try {
      await ApiSession.instance.client.photoMemoryIgnore(
        body: PhotoMemoryTargetBody(date: item.date),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _restore(PhotoMemoryItem item) async {
    try {
      await ApiSession.instance.client.photoMemoryRestore(
        body: PhotoMemoryTargetBody(date: item.date),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _remove(PhotoMemoryItem item) async {
    try {
      await ApiSession.instance.client.photoMemoryRemove(
        body: PhotoMemoryTargetBody(date: item.date),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  void _openChapter(int year, {String? date}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoChapterBookPage(year: year, initialDate: date),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(tr('ui.photo.026')),
              actions: [
                IconButton(
                  tooltip: tr('photo.memory.rediscover'),
                  onPressed: _load,
                  icon: const Icon(Icons.autorenew),
                ),
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
    final data = _data;
    final chapters = data?.chapters ?? const <PhotoMemoryChapter>[];
    final list = _list;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        if (!widget.embedded)
          Text(
            tr('photo.memory.hint'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        if (chapters.isNotEmpty) ...[
          const SizedBox(height: 14),
          _sectionTitle(tr('photo.memory.chapters'), tr('photo.memory.chaptersHint')),
          const SizedBox(height: 10),
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: chapters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) => _ChapterCard(
                chapter: chapters[i],
                onTap: () => _openChapter(chapters[i].year),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            for (var i = 0; i < 3; i += 1) ...[
              _MemoryTab(
                label: switch (i) {
                  1 => tr('photo.memory.tab.pending'),
                  2 => tr('photo.memory.tab.ignored'),
                  _ => tr('photo.memory.tab.mine'),
                },
                count: switch (i) {
                  1 => data?.candidates.length ?? 0,
                  2 => data?.ignored.length ?? 0,
                  _ => data?.memories.length ?? 0,
                },
                selected: _tab == i,
                onTap: () => setState(() => _tab = i),
              ),
              const SizedBox(width: 18),
            ],
          ],
        ),
        const SizedBox(height: 14),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: NasEmptyState(
              title: tr('photo.memory.empty'),
              message: tr('photo.memory.emptyHint'),
              icon: Icons.auto_stories_outlined,
            ),
          )
        else
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final item in list)
                _MemoryCard(
                  item: item,
                  onOpen: () => _openChapter(
                    int.tryParse(item.date.substring(0, 4)) ?? DateTime.now().year,
                    date: item.date,
                  ),
                  onSave: _tab == 1 ? () => _save(item) : null,
                  onIgnore: _tab == 1 ? () => _ignore(item) : null,
                  onRestore: _tab == 2 ? () => _restore(item) : null,
                  onRemove: _tab == 0 ? () => _remove(item) : null,
                ),
            ],
          ),
      ],
    );
  }

  Widget _sectionTitle(String title, String subtitle) {
    return Column(
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
    );
  }
}

class _ChapterCard extends StatelessWidget {
  const _ChapterCard({required this.chapter, required this.onTap});

  final PhotoMemoryChapter chapter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (chapter.coverPath.isNotEmpty)
              NasCoverImage(url: _thumb(chapter.coverPath), headers: _authHeaders(), fit: BoxFit.cover)
            else
              ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.menu_book_outlined, size: 36),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xCC000000)],
                  stops: [0.35, 1],
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
                    '${chapter.start} — ${chapter.end}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  Text(
                    tr('photo.memory.yearBook', {'year': '${chapter.year}'}),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    tr('photo.memory.photoCount', {'count': '${chapter.photoCount}'}),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            Positioned.fill(child: Material(color: Colors.transparent, child: InkWell(onTap: onTap))),
          ],
        ),
      ),
    );
  }
}

class _MemoryTab extends StatelessWidget {
  const _MemoryTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          children: [
            Text(
              '$label  $count',
              style: TextStyle(
                fontSize: NasTokens.fontBody,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? scheme.primary : context.nasTextSecondary,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 2,
              width: selected ? 28 : 0,
              color: scheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.item,
    required this.onOpen,
    this.onSave,
    this.onIgnore,
    this.onRestore,
    this.onRemove,
  });

  final PhotoMemoryItem item;
  final VoidCallback onOpen;
  final VoidCallback? onSave;
  final VoidCallback? onIgnore;
  final VoidCallback? onRestore;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tags = [...item.scenes, ...item.activities, ...item.people];
    return Container(
      width: 360,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: item.coverPath.isEmpty
                ? ColoredBox(color: scheme.surfaceContainerHighest)
                : NasCoverImage(url: _thumb(item.coverPath), headers: _authHeaders(), fit: BoxFit.cover),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.date,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    tr('photo.memory.photoCount', {'count': '${item.photoCount}'}),
                    if (item.place.isNotEmpty) item.place,
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    item.note,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 1.45),
                  ),
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final tag in tags.take(6))
                        Text(
                          '#$tag',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.primary.withValues(alpha: 0.9),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (onSave != null)
                      FilledButton.tonal(
                        onPressed: onSave,
                        child: Text(tr('photo.memory.confirm')),
                      ),
                    if (onIgnore != null) ...[
                      const SizedBox(width: 8),
                      TextButton(onPressed: onIgnore, child: Text(tr('photo.memory.ignore'))),
                    ],
                    if (onRestore != null)
                      FilledButton.tonal(
                        onPressed: onRestore,
                        child: Text(tr('photo.memory.restore')),
                      ),
                    if (onRemove != null)
                      TextButton(onPressed: onRemove, child: Text(tr('photo.memory.remove'))),
                    const Spacer(),
                    TextButton(onPressed: onOpen, child: Text(tr('photo.memory.open'))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 独立页：每日一帧
class PhotoDayFramePage extends StatelessWidget {
  const PhotoDayFramePage({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: embedded ? null : AppBar(title: Text(tr('photo.nav.dayFrame'))),
      body: const _DayFramesTab(),
    );
  }
}

/// 独立页：票夹
class PhotoTicketsPage extends StatelessWidget {
  const PhotoTicketsPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: embedded ? null : AppBar(title: Text(tr('photo.nav.tickets'))),
      body: const _TicketsTab(),
    );
  }
}

/// 独立页：年度总结
class PhotoAnnualPage extends StatelessWidget {
  const PhotoAnnualPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: embedded ? null : AppBar(title: Text(tr('photo.nav.year'))),
      body: const _YearTab(),
    );
  }
}

/// 独立页：人生章节（对开书本）
class PhotoChapterBookPage extends StatelessWidget {
  const PhotoChapterBookPage({super.key, required this.year, this.initialDate});

  final int year;
  final String? initialDate;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('photo.memory.chapters'))),
      body: _ChapterTab(initialYear: year, initialDate: initialDate),
    );
  }
}

MediaUrls _mediaUrls() => MediaUrls(ApiSession.instance.baseUrl);

Map<String, String> _authHeaders() {
  final token = ApiSession.instance.token;
  return token == null ? const {} : {'Authorization': 'Bearer $token'};
}

String _thumb(String path, {int size = 480}) =>
    _mediaUrls().thumbnail(path, size: size);

// ---------------------------------------------------------------- 一日一帧

class _DayFramesTab extends StatefulWidget {
  const _DayFramesTab();

  @override
  State<_DayFramesTab> createState() => _DayFramesTabState();
}

class _DayFramesTabState extends State<_DayFramesTab> {
  bool _loading = true;
  String? _error;
  List<PhotoDayFrame> _items = const [];
  int _days = 30;

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
      final res = await ApiSession.instance.client.photoDayFrames(
        days: _days,
        locale: 'zh-CN',
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
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
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: NasTokens.spaceMd,
            vertical: NasTokens.spaceSm,
          ),
          child: Row(
            children: [
              Text(
                tr('photo.memoryRecent', {'days': '$_days'}),
                style: TextStyle(
                  color: context.nasTextSecondary,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
              Spacer(),
              NasDropdown<int>(
                value: _days,
                underline: SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: 7, child: Text(tr('ui.photo.027'))),
                  DropdownMenuItem(value: 30, child: Text(tr('ui.photo.028'))),
                  DropdownMenuItem(value: 90, child: Text(tr('ui.photo.029'))),
                  DropdownMenuItem(value: 365, child: Text(tr('ui.photo.030'))),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _days = v);
                  _load();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _items.isEmpty
              ? NasEmptyState(
                  title: tr('ui.photo.031'),
                  message: tr('ui.photo.h7f61f2'),
                  icon: Icons.image_outlined,
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(NasTokens.spaceSm),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 280,
                    crossAxisSpacing: NasTokens.spaceSm,
                    mainAxisSpacing: NasTokens.spaceSm,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final item = _items[i];
                    return _DayFrameCard(item: item);
                  },
                ),
        ),
      ],
    );
  }
}

class _DayFrameCard extends StatelessWidget {
  const _DayFrameCard({required this.item});

  final PhotoDayFrame item;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                NasCoverImage(
                  url: _thumb(item.path),
                  headers: _authHeaders(),
                  cacheWidth: 560,
                  icon: Icons.broken_image_outlined,
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      tr('photo.memoryDay', {'date': item.date, 'count': '${item.dayPhotoCount}'}),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: NasTokens.fontCaption,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(NasTokens.spaceSm),
            child: Text(
              item.caption.isEmpty ? tr('ui.photo.ha61879') : item.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: NasTokens.fontCaption),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 人生章节

class _ChapterTab extends StatefulWidget {
  const _ChapterTab({this.initialYear, this.initialDate});

  final int? initialYear;
  final String? initialDate;

  @override
  State<_ChapterTab> createState() => _ChapterTabState();
}

class _ChapterTabState extends State<_ChapterTab> {
  bool _loading = true;
  String? _error;
  PhotoChapterBook? _book;
  int _index = 0;
  late int _year;

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
      _index = 0;
    });
    try {
      final book = await ApiSession.instance.client.photoChapterBook(
        year: _year,
        locale: 'zh-CN',
      );
      if (!mounted) return;
      setState(() {
        _book = book;
        _loading = false;
        final target = widget.initialDate;
        if (target != null) {
          final i = book.days.indexWhere((d) => d.date == target);
          if (i >= 0) _index = i;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _prev() {
    final days = _book?.days ?? const [];
    if (days.isEmpty) return;
    setState(() => _index = (_index - 1).clamp(0, days.length - 1));
  }

  void _next() {
    final days = _book?.days ?? const [];
    if (days.isEmpty) return;
    setState(() => _index = (_index + 1).clamp(0, days.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);

    final book = _book;
    final days = book?.days ?? const <PhotoChapterPage>[];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NasTokens.spaceMd,
            vertical: NasTokens.spaceSm,
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: tr('ui.photo.032'),
                icon: const Icon(Icons.chevron_left),
                onPressed: () {
                  setState(() => _year -= 1);
                  _load();
                },
              ),
              Text(
                tr('photo.memoryYear', {'year': '${book?.year ?? _year}', 'days': '${days.length}', 'count': '${book?.totalPhotos ?? 0}'}),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              IconButton(
                tooltip: tr('ui.photo.033'),
                icon: const Icon(Icons.chevron_right),
                onPressed: () {
                  setState(() => _year += 1);
                  _load();
                },
              ),
              const Spacer(),
              Text(
                days.isEmpty ? '' : '${_index + 1} / ${days.length}',
                style: TextStyle(
                  color: context.nasTextSecondary,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: days.isEmpty
              ? NasEmptyState(
                  title: tr('photo.memoryYearEmpty', {'year': '${book?.year ?? _year}'}),
                  message: tr('ui.photo.h9f80b0'),
                  icon: Icons.menu_book_outlined,
                )
              : CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowLeft): _prev,
                    const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
                    const SingleActivator(LogicalKeyboardKey.pageUp): _prev,
                    const SingleActivator(LogicalKeyboardKey.pageDown): _next,
                    const SingleActivator(LogicalKeyboardKey.space): _next,
                  },
                  child: Focus(
                    autofocus: true,
                    child: _ChapterSpread(page: days[_index]),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NasTokens.spaceMd,
            vertical: NasTokens.spaceSm,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                tooltip: tr('ui.photo.034'),
                onPressed: _index > 0 ? _prev : null,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: NasTokens.spaceLg),
              IconButton.filled(
                tooltip: tr('ui.photo.035'),
                onPressed: _index < days.length - 1 ? _next : null,
                icon: const Icon(Icons.arrow_forward),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 一张书页摊开：左页大图 + 本日精选，右页影像日记 + 地点 + 标签。
class _ChapterSpread extends StatelessWidget {
  const _ChapterSpread({required this.page});

  final PhotoChapterPage page;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 760;
        final left = _LeftPage(page: page);
        final right = _RightPage(page: page);
        if (wide) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: left),
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: right),
              ],
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
          children: [
            SizedBox(height: c.maxHeight * 0.52, child: left),
            const SizedBox(height: NasTokens.spaceMd),
            right,
          ],
        );
      },
    );
  }
}

class _LeftPage extends StatelessWidget {
  const _LeftPage({required this.page});

  final PhotoChapterPage page;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
          child: Row(
            children: [
              Text(page.date, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: NasTokens.spaceSm),
              Text(
                tr('photo.count', {'count': '${page.photoCount}'}),
                style: TextStyle(
                  color: context.nasTextSecondary,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(NasTokens.radiusMd),
            child: NasCoverImage(
              url: _thumb(page.cover.path, size: 1200),
              headers: _authHeaders(),
              cacheWidth: 1200,
              icon: Icons.broken_image_outlined,
            ),
          ),
        ),
        const SizedBox(height: NasTokens.spaceSm),
        SizedBox(
          height: 72,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: page.picks.length,
            separatorBuilder: (_, _) =>
                const SizedBox(width: NasTokens.spaceXs),
            itemBuilder: (context, i) {
              final pick = page.picks[i];
              return ClipRRect(
                borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                child: SizedBox(
                  width: 72,
                  child: NasCoverImage(
                    url: _thumb(pick.path, size: 200),
                    headers: _authHeaders(),
                    cacheWidth: 200,
                    icon: Icons.broken_image_outlined,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RightPage extends StatelessWidget {
  const _RightPage({required this.page});

  final PhotoChapterPage page;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (page.place.isNotEmpty)
            Row(
              children: [
                const Icon(Icons.place_outlined, size: 16),
                const SizedBox(width: 4),
                Text(
                  page.place,
                  style: const TextStyle(fontSize: NasTokens.fontCaption),
                ),
              ],
            ),
          const SizedBox(height: NasTokens.spaceSm),
          Text(page.note, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: NasTokens.spaceMd),
          if (page.scenes.isNotEmpty) ...[
            Text(
              tr('ui.photo.036'),
              style: TextStyle(
                color: context.nasTextSecondary,
                fontSize: NasTokens.fontCaption,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: NasTokens.spaceXs,
              runSpacing: NasTokens.spaceXs,
              children: [for (final s in page.scenes) Chip(label: Text(s))],
            ),
            const SizedBox(height: NasTokens.spaceSm),
          ],
          if (page.activities.isNotEmpty) ...[
            Text(
              tr('ui.photo.037'),
              style: TextStyle(
                color: context.nasTextSecondary,
                fontSize: NasTokens.fontCaption,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: NasTokens.spaceXs,
              runSpacing: NasTokens.spaceXs,
              children: [for (final a in page.activities) Chip(label: Text(a))],
            ),
            const SizedBox(height: NasTokens.spaceSm),
          ],
          if (page.people.isNotEmpty) ...[
            Text(
              tr('ui.photo.038'),
              style: TextStyle(
                color: context.nasTextSecondary,
                fontSize: NasTokens.fontCaption,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: NasTokens.spaceXs,
              runSpacing: NasTokens.spaceXs,
              children: [
                for (final p in page.people)
                  Chip(
                    avatar: const Icon(Icons.person, size: 16),
                    label: Text(p),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 票夹

class _TicketsTab extends StatefulWidget {
  const _TicketsTab();

  @override
  State<_TicketsTab> createState() => _TicketsTabState();
}

class _TicketsTabState extends State<_TicketsTab> {
  bool _loading = true;
  String? _error;
  PhotoTicketResponse? _data;

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
      final data = await ApiSession.instance.client.photoTickets(limit: 300);
      if (!mounted) return;
      setState(() {
        _data = data;
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
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final data = _data;
    if (data == null) return const SizedBox.shrink();

    if (data.degraded) {
      return NasEmptyState(
        title: tr('ui.photo.039'),
        message: data.reason.isEmpty ? tr('ui.photo.h1fbca6') : data.reason,
        icon: Icons.confirmation_number_outlined,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      children: [
        Text(
          tr('photo.memoryScan', {'scanned': '${data.scanned}', 'tickets': '${data.tickets.length}', 'trips': '${data.trips.length}'}),
          style: TextStyle(
            color: context.nasTextSecondary,
            fontSize: NasTokens.fontCaption,
          ),
        ),
        const SizedBox(height: NasTokens.spaceMd),
        for (final trip in data.trips)
          _TripCard(trip: trip, tickets: data.tickets),
        if (data.trips.isEmpty)
          NasEmptyState(
            title: tr('ui.photo.040'),
            message: tr('ui.photo.he4d611'),
            icon: Icons.confirmation_number_outlined,
          ),
      ],
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip, required this.tickets});

  final PhotoTrip trip;
  final List<PhotoTicket> tickets;

  @override
  Widget build(BuildContext context) {
    final related = tickets.where(
      (t) =>
          t.date.compareTo(trip.start) >= 0 && t.date.compareTo(trip.end) <= 0,
    );
    return Card(
      margin: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: Padding(
        padding: const EdgeInsets.all(NasTokens.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    trip.title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  '${trip.start}${trip.start == trip.end ? '' : ' → ${trip.end}'}',
                  style: TextStyle(
                    color: context.nasTextSecondary,
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              tr('photo.memoryTrip', {'count': '${trip.ticketCount}', 'kinds': trip.kinds.join(' / ')}),
              style: TextStyle(
                color: context.nasTextSecondary,
                fontSize: NasTokens.fontCaption,
              ),
            ),
            const Divider(height: NasTokens.spaceLg),
            for (final t in related.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: NasTokens.spaceXs),
                child: Row(
                  children: [
                    Icon(
                      t.kind == 'flight'
                          ? Icons.flight_takeoff
                          : Icons.train_outlined,
                      size: 18,
                    ),
                    const SizedBox(width: NasTokens.spaceXs),
                    Expanded(
                      child: Text(
                        '${t.kindLabel}${t.code.isEmpty ? '' : ' ${t.code}'}'
                        '${t.fromStation.isEmpty ? '' : ' · ${t.fromStation} → ${t.toStation}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: NasTokens.fontCaption),
                      ),
                    ),
                    Text(
                      t.time,
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
    );
  }
}

// ---------------------------------------------------------------- 年度

class _YearTab extends StatefulWidget {
  const _YearTab();

  @override
  State<_YearTab> createState() => _YearTabState();
}

class _YearTabState extends State<_YearTab> {
  bool _loading = true;
  String? _error;
  PhotoYearReport? _report;
  late int _year;

  @override
  void initState() {
    super.initState();
    _year = DateTime.now().year;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.photoYearReport(
        year: _year,
        locale: 'zh-CN',
      );
      if (!mounted) return;
      setState(() {
        _report = res;
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
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final r = _report;
    if (r == null) return const SizedBox.shrink();

    final maxMonth = r.months.fold<int>(1, (m, e) => e.count > m ? e.count : m);

    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                setState(() => _year -= 1);
                _load();
              },
            ),
            Text(
              tr('photo.memoryYearRecord', {'year': '${r.year}'}),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () {
                setState(() => _year += 1);
                _load();
              },
            ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceSm),
        Wrap(
          spacing: NasTokens.spaceSm,
          runSpacing: NasTokens.spaceSm,
          children: [
            _StatCard(label: tr('ui.photo.041'), value: '${r.totalPhotos}'),
            _StatCard(label: tr('ui.photo.042'), value: '${r.placeCount}'),
            _StatCard(label: tr('ui.photo.043'), value: '${r.people.length}'),
            _StatCard(label: tr('ui.photo.044'), value: '${r.scenes.length}'),
          ],
        ),
        const SizedBox(height: NasTokens.spaceLg),
        Text(tr('ui.photo.045'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: NasTokens.spaceSm),
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final m in r.months)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          m.count == 0 ? '' : '${m.count}',
                          style: TextStyle(
                            color: context.nasTextSecondary,
                            fontSize: 10,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          height:
                              (m.count / maxMonth) * 80 +
                              (m.count == 0 ? 0 : 4),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary
                                .withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${m.month}',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: NasTokens.spaceLg),
        _LabelSection(title: tr('ui.photo.044'), items: r.scenes),
        _LabelSection(title: tr('ui.photo.037'), items: r.activities),
        _LabelSection(title: tr('ui.photo.038'), items: r.people),
        _LabelSection(title: tr('ui.photo.046'), items: r.cameras),
        const SizedBox(height: NasTokens.spaceMd),
        Text(tr('ui.photo.047'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: NasTokens.spaceSm),
        for (final p in r.places)
          Padding(
            padding: const EdgeInsets.only(bottom: NasTokens.spaceXs),
            child: Row(
              children: [
                const Icon(Icons.place_outlined, size: 16),
                const SizedBox(width: 4),
                SizedBox(
                  width: 120,
                  child: Text(
                    p.name.isEmpty ? p.geohash5 : p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: Text(
                    p.years.map((y) => '${y.year}: ${y.count}').join('   '),
                    style: TextStyle(
                      color: context.nasTextSecondary,
                      fontSize: NasTokens.fontCaption,
                    ),
                  ),
                ),
                Text(
                  tr('photo.count', {'count': '${p.count}'}),
                  style: const TextStyle(fontSize: NasTokens.fontCaption),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      padding: const EdgeInsets.all(NasTokens.spaceSm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.headlineSmall),
          Text(
            label,
            style: TextStyle(
              color: context.nasTextSecondary,
              fontSize: NasTokens.fontCaption,
            ),
          ),
        ],
      ),
    );
  }
}

class _LabelSection extends StatelessWidget {
  const _LabelSection({required this.title, required this.items});

  final String title;
  final List<PhotoLabelCount> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: NasTokens.spaceXs,
            runSpacing: NasTokens.spaceXs,
            children: [
              for (final item in items)
                Chip(label: Text('${item.label} · ${item.count}')),
            ],
          ),
        ],
      ),
    );
  }
}
