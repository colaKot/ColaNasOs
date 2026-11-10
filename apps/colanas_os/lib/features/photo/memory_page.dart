import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'annual/photo_annual_report.dart';
import 'photo_viewer_page.dart';

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
  // 人生章节直接在记忆页内容区展开，不再 push 一个盖住侧栏的全屏路由
  int? _chapterYear;
  String? _chapterDate;

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
    setState(() {
      _chapterYear = year;
      _chapterDate = date;
    });
  }

  void _closeChapter() {
    setState(() {
      _chapterYear = null;
      _chapterDate = null;
    });
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
      body: _chapterYear != null
          ? _ChapterTab(
              initialYear: _chapterYear,
              initialDate: _chapterDate,
              onBack: _closeChapter,
            )
          : _loading
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
                // 列表按 limit 截断过，这里显示服务端给的真实总数
                count: switch (i) {
                  1 => data?.totalCandidates ?? data?.candidates.length ?? 0,
                  2 => data?.totalIgnored ?? data?.ignored.length ?? 0,
                  _ => data?.totalMemories ?? data?.memories.length ?? 0,
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
          GestureDetector(
            onTap: onOpen,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: item.coverPath.isEmpty
                  ? ColoredBox(color: scheme.surfaceContainerHighest)
                  : NasCoverImage(
                      url: _thumb(item.coverPath),
                      headers: _authHeaders(),
                      fit: BoxFit.cover,
                    ),
            ),
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
      body: const PhotoAnnualReport(),
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

/// 章节接口只给 id + path，没有 media_kind；视频按扩展名认，
/// 交给查看器显示播放按钮 / 抽帧封面。
bool _isVideoPath(String path) {
  final p = path.toLowerCase();
  return const <String>[
    '.mp4', '.mov', '.m4v', '.mkv', '.avi', '.webm', '.3gp', '.ts',
  ].any((ext) => p.endsWith(ext));
}

List<ViewerPhoto> _viewerPhotosOf(PhotoChapterPage page) {
  // 封面不一定在 picks 里（两者排序口径不同），放首位再补其余，避免点大图找不到自己
  final all = <PhotoMemoryPick>[
    page.cover,
    ...page.picks.where((p) => p.id != page.cover.id),
  ];
  return [
    for (final p in all)
      ViewerPhoto(
        id: p.id,
        path: p.path,
        takenAt: p.takenAt,
        mediaKind: _isVideoPath(p.path) ? 'video' : 'image',
      ),
  ];
}

/// 点书页大图 / 底部缩略图 → 统一查看器。
/// 左右按钮、键盘左右键、手机滑动、视频播放都在查看器里，这里不重复实现。
void _openPick(BuildContext context, PhotoChapterPage page, String id) {
  final photos = _viewerPhotosOf(page);
  final index = photos.indexWhere((p) => p.id == id);
  openPhotoViewer(
    context,
    photos: photos,
    initialIndex: index < 0 ? 0 : index,
    title: page.date,
  );
}

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
  int _days = 90;

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
  const _ChapterTab({this.initialYear, this.initialDate, this.onBack});

  final int? initialYear;
  final String? initialDate;

  /// 嵌在记忆页里时给一个「返回记忆列表」；独立页为 null
  final VoidCallback? onBack;

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
              if (widget.onBack != null)
                IconButton(
                  tooltip: tr('common.back'),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack,
                ),
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
          child: GestureDetector(
            onTap: () => _openPick(context, page, page.cover.id),
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
              return GestureDetector(
                onTap: () => _openPick(context, page, pick.id),
                child: ClipRRect(
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
  String _kind = 'all';

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

  List<PhotoTicket> get _visible {
    final all = _data?.tickets ?? const <PhotoTicket>[];
    if (_kind == 'all') return all;
    return all.where((t) => t.kind == _kind).toList();
  }

  /// 按「年-月」分组。date 来自 OCR，格式不对时退回拍摄时间。
  Map<String, List<PhotoTicket>> _groups(List<PhotoTicket> list) {
    final map = <String, List<PhotoTicket>>{};
    for (final t in list) {
      var key = t.date.length >= 7 ? t.date.substring(0, 7) : '';
      if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(key) && t.takenAt > 0) {
        final d = DateTime.fromMillisecondsSinceEpoch(t.takenAt * 1000);
        key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      }
      if (key.isEmpty) key = 'unknown';
      map.putIfAbsent(key, () => <PhotoTicket>[]).add(t);
    }
    for (final v in map.values) {
      v.sort((a, b) =>
          '${b.date} ${b.time}'.compareTo('${a.date} ${a.time}'));
    }
    return map;
  }

  String _monthLabel(String key) {
    if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(key)) return tr('common.unknown');
    return tr('photo.ticket.month', {
      'year': key.substring(0, 4),
      'month': '${int.parse(key.substring(5, 7))}',
    });
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

    final tickets = _visible;
    final groups = _groups(tickets);
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _kindTabs(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(NasTokens.spaceMd),
            children: [
              Text(
                tr('photo.memoryScan', {
                  'scanned': '${data.scanned}',
                  'tickets': '${data.tickets.length}',
                  'trips': '${data.trips.length}',
                }),
                style: TextStyle(
                  color: context.nasTextSecondary,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
              const SizedBox(height: NasTokens.spaceMd),
              if (tickets.isEmpty)
                NasEmptyState(
                  title: tr('ui.photo.040'),
                  message: tr('ui.photo.he4d611'),
                  icon: Icons.confirmation_number_outlined,
                ),
              for (final key in keys) ...[
                Padding(
                  padding: const EdgeInsets.only(
                    top: NasTokens.spaceMd,
                    bottom: NasTokens.spaceSm,
                  ),
                  child: Text(
                    _monthLabel(key),
                    style: const TextStyle(
                      fontSize: NasTokens.fontSubtitle,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, cons) {
                    final cols = cons.maxWidth >= 900 ? 2 : 1;
                    const gap = NasTokens.spaceSm;
                    final cardW = (cons.maxWidth - gap * (cols - 1)) / cols;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final t in groups[key]!)
                          SizedBox(width: cardW, child: _TicketCard(ticket: t)),
                      ],
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _kindTabs() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          for (final (value, key) in const [
            ('all', 'photo.ticket.all'),
            ('train', 'photo.ticket.train'),
            ('flight', 'photo.ticket.flight'),
          ])
            InkWell(
              onTap: () => setState(() => _kind = value),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: _kind == value ? scheme.primary : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(
                  tr(key),
                  style: TextStyle(
                    color: _kind == value ? scheme.primary : context.nasTextSecondary,
                    fontWeight: _kind == value ? FontWeight.w700 : null,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单张票卡：缩略图 + 类型 + 起终点 + 车次时间 + 更多（参考主流票夹）
class _TicketCard extends StatelessWidget {
  const _TicketCard({required this.ticket});

  final PhotoTicket ticket;

  @override
  Widget build(BuildContext context) {
    final t = ticket;
    final from = _stationShort(t.fromStation);
    final to = _stationShort(t.toStation);
    final route = from.isEmpty && to.isEmpty
        ? (t.code.isEmpty ? t.date : t.code)
        : '$from → $to';
    // 票面基本信息压成一行：车次 · 席别座位 · 月/日 时间；票价单独放类型行右侧
    final seatText = [t.seatClass ?? '', t.seat ?? '']
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join(' ');
    final when = [
      if (t.date.isNotEmpty) _shortDate(t.date),
      if (t.time.isNotEmpty) t.time,
    ].join(' ');
    final sub = <String>[
      if (t.code.isNotEmpty) t.code,
      if (seatText.isNotEmpty) seatText,
      if (when.isNotEmpty) when,
    ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onTap: () => _openTicketPhoto(context, t.path),
        child: Padding(
          padding: const EdgeInsets.all(NasTokens.spaceSm),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                child: SizedBox(
                  width: 76,
                  height: 62,
                  child: NasCoverImage(
                    url: _thumb(t.path),
                    headers: _authHeaders(),
                    icon: Icons.receipt_long_outlined,
                    cacheWidth: 240,
                  ),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            t.kindLabel,
                            style: TextStyle(
                              fontSize: NasTokens.fontCaption,
                              color: context.nasTextSecondary,
                            ),
                          ),
                        ),
                        if ((t.price ?? '').isNotEmpty)
                          Text(
                            '¥${t.price}',
                            style: TextStyle(
                              fontSize: NasTokens.fontCaption,
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      route,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: NasTokens.fontBody,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz, size: 18),
                padding: EdgeInsets.zero,
                onSelected: (v) {
                  if (v == 'open') _openTicketPhoto(context, t.path);
                  if (v == 'copy') _copyTicketPath(context, t.path);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'open',
                    child: Text(tr('common.open')),
                  ),
                  PopupMenuItem(
                    value: 'copy',
                    child: Text(tr('video.action.copyPath')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 火车票站名去掉末尾「站」更接近票面写法（南宁东站 → 南宁东）；
/// 「机场」保留，机场名去掉后缀会歧义。
String _stationShort(String s) {
  final t = s.trim();
  if (t.length > 2 && t.endsWith('站')) return t.substring(0, t.length - 1);
  return t;
}

String _shortDate(String d) {
  final p = d.split('-');
  if (p.length < 3) return d;
  return '${int.tryParse(p[1]) ?? p[1]}/${p[2]}';
}

void _openTicketPhoto(BuildContext context, String path) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.black87,
      insetPadding: const EdgeInsets.all(NasTokens.spaceLg),
      child: Stack(
        children: [
          Positioned.fill(
            child: NasCoverImage(
              url: _thumb(path, size: 1600),
              headers: _authHeaders(),
              fit: BoxFit.contain,
              icon: Icons.receipt_long_outlined,
            ),
          ),
          Positioned(
            right: 4,
            top: 4,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _copyTicketPath(BuildContext context, String path) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: path));
  NasSnack.showOn(messenger, tr('common.copied'));
}
