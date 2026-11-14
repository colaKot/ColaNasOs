import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/settings_store.dart';
import '../../core/session.dart';
import 'photo_adaptive_image.dart';
import 'photo_viewer_page.dart';

/// 成长轨迹（相册 > 记忆）。
///
/// 服务端把某个人的人脸照片按「地点 × 时间窗」预计算成 Stage 并落库，这里只做展示：
/// 顶部人脸条 + 一句话看板 + 时间轴分段列表（游标分页）+ 阶段二级页 + 换封面纠错。
/// 所有 UI 文案走 i18n；服务端只给结构化数据（地点、时间、里程碑枚举）。
class PhotoGrowthTrackPage extends StatefulWidget {
  const PhotoGrowthTrackPage({super.key});

  @override
  State<PhotoGrowthTrackPage> createState() => _PhotoGrowthTrackPageState();
}

class _PhotoGrowthTrackPageState extends State<PhotoGrowthTrackPage> {
  static const _personKey = 'photo.growth.person';
  static const _orderKey = 'photo.growth.order';
  static const _granularityKey = 'photo.growth.granularity';
  static const _barKey = 'photo.growth.personBar';
  static const _pageSize = 20;

  /// 顶部人物条不参与滚动的那一屏最多放几个（其余靠「+」自己挑）。
  static const _barLimit = 5;

  bool _loading = true;
  String? _error;
  List<PhotoGrowthPerson> _persons = const [];
  String? _personId;
  List<PhotoGrowthStage> _stages = const [];
  PhotoGrowthSummary? _summary;
  String? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _asc = false;
  String _granularity = 'auto';
  final ScrollController _scroll = ScrollController();

  /// 每段的多张照片：批量接口按 10 段一批取回，卡片内最多展示 8 张。
  ///
  /// 列表页一屏 20 段，逐段请求会打出一串接口调用；失败或还没回来时回落到
  /// stage 自带的封面 / 次图 / 补充图（不足 5 张就有几张显示几张，不补空位）。
  final Map<String, List<PhotoItem>> _stagePhotos = {};

  static const int maxPhotos = 8;

  /// 用户亲手挑过的人物条名单；null = 没挑过，默认放前 [_barLimit] 个。
  ///
  /// 之前是「把所有聚类都铺在条子上」，库里有几十个聚类时条子长得离谱，
  /// 而且想选的那个人要横向翻很久。现在默认只放 5 个，其余点「+」勾选后追加，
  /// 选择写进 SettingsStore，下次进页面还是这套人。
  List<String>? _barIds;

  ApiClient get _client => ApiSession.instance.client;

  /// 条上实际显示的人：手挑名单（或默认前 5 个）+ 当前选中的人兜底。
  List<PhotoGrowthPerson> get _visiblePersons {
    final byId = {for (final p in _persons) p.id: p};
    final out = <PhotoGrowthPerson>[];
    final ids = _barIds;
    if (ids == null) {
      out.addAll(_persons.take(_barLimit));
    } else {
      for (final id in ids) {
        final p = byId[id];
        if (p != null) out.add(p);
      }
    }
    // 当前选中的人必须出现在条上（比如上次退出前选的是第 8 个）
    final cur = _personId;
    if (cur != null && !out.any((p) => p.id == cur)) {
      final p = byId[cur];
      if (p != null) out.add(p);
    }
    return out;
  }

  String _faceUrl(String id, {int size = 96}) =>
      '${ApiSession.instance.baseUrl}/api/v1/photo/face/image'
      '?id=${Uri.encodeComponent(id)}&size=$size';

  @override
  void initState() {
    super.initState();
    _asc = SettingsStore.instance.getString(_orderKey) == 'asc';
    final g = SettingsStore.instance.getString(_granularityKey);
    _granularity = (g == 'month' || g == 'quarter' || g == 'year') ? g! : 'auto';
    final bar = SettingsStore.instance.getString(_barKey);
    if (bar != null && bar.trim().isNotEmpty) {
      _barIds = bar.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_scroll.position.extentAfter < 320) _loadStages(reset: false);
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _client.photoGrowthPersons(limit: 20);
      if (!mounted) return;
      final saved = SettingsStore.instance.getString(_personKey);
      var selected = saved;
      if (selected == null || !res.items.any((p) => p.id == selected)) {
        selected = null;
        for (final p in res.items) {
          if ((p.name ?? '').isNotEmpty) {
            selected = p.id;
            break;
          }
        }
        selected ??= res.items.isNotEmpty ? res.items.first.id : null;
      }
      setState(() {
        _persons = res.items;
        _personId = selected;
      });
      if (selected != null) await _loadStages(reset: true);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// [preserveScroll] 用于「原地刷新」：换完封面 / 从阶段页回来时**保住滚动位置**。
  ///
  /// 之前这里无条件 `jumpTo(0)`，用户翻了十几段点开一张图再返回，列表被重置回
  /// 第一张（2026-11-13 反馈）。保位置时会把 limit 放大到「已加载条数」，
  /// 这样列表长度不变，旧偏移才有意义；纯切人 / 换粒度 / 换排序仍然回顶部。
  Future<void> _loadStages({required bool reset, bool preserveScroll = false}) async {
    final person = _personId;
    if (person == null || _loadingMore) return;
    final offset = preserveScroll && _scroll.hasClients ? _scroll.offset : 0.0;
    final limit = preserveScroll ? _stages.length.clamp(_pageSize, 100).toInt() : _pageSize;
    setState(() => _loadingMore = true);
    try {
      final res = await _client.photoGrowthItems(
        person: person,
        order: _asc ? 'asc' : 'desc',
        granularity: _granularity,
        cursor: reset ? null : _cursor,
        limit: limit,
      );
      if (!mounted) return;
      setState(() {
        _stages = reset ? List<PhotoGrowthStage>.from(res.items) : [..._stages, ...res.items];
        _cursor = res.nextCursor;
        _hasMore = res.nextCursor != null;
        _summary = res.summary;
        _loadingMore = false;
      });
      // 先渲染封面兜底，再按批补图；失败不打断列表
      unawaited(_loadStagePhotos(_stages));
      if (reset && _scroll.hasClients) {
        if (!preserveScroll) {
          _scroll.jumpTo(0);
        } else {
          // 新列表要等一帧才布局完，maxScrollExtent 才是新的值
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scroll.hasClients) return;
            _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      NasSnack.show(context, '$e');
    }
  }

  /// 批量补图：按 10 段一批请求，已经拿到的段不再重复拉。
  ///
  /// 每段最多 8 张，卡片里横竖混排；不足 5 张时就有几张显示几张。
  Future<void> _loadStagePhotos(List<PhotoGrowthStage> stages) async {
    final ids = <String>[
      for (final s in stages)
        if (!_stagePhotos.containsKey(s.id)) s.id,
    ];
    if (ids.isEmpty) return;
    for (var i = 0; i < ids.length; i += 10) {
      final end = i + 10 < ids.length ? i + 10 : ids.length;
      try {
        final res = await _client.photoGrowthStagePhotosBatch(
          stageIds: ids.sublist(i, end).join(','),
          limit: maxPhotos,
        );
        if (!mounted) return;
        setState(() {
          for (final g in res.items) {
            _stagePhotos[g.stageId] = g.items.take(maxPhotos).toList();
          }
        });
      } catch (_) {
        // 批量接口不可用时回落到封面/次图/补充图，列表本身不受影响
        return;
      }
    }
  }

  Future<void> _selectPerson(String id) async {
    if (id == _personId) return;
    await SettingsStore.instance.setString(_personKey, id);
    if (!mounted) return;
    setState(() {
      _personId = id;
      _stages = const [];
      _cursor = null;
      _hasMore = false;
      _summary = null;
    });
    await _loadStages(reset: true);
  }

  Future<void> _setAsc(bool asc) async {
    if (asc == _asc) return;
    await SettingsStore.instance.setString(_orderKey, asc ? 'asc' : 'desc');
    if (!mounted) return;
    setState(() => _asc = asc);
    await _loadStages(reset: true);
  }

  Future<void> _setGranularity(String g) async {
    if (g == _granularity) return;
    await SettingsStore.instance.setString(_granularityKey, g);
    if (!mounted) return;
    setState(() => _granularity = g);
    await _loadStages(reset: true);
  }

  Future<void> _rebuild() async {
    final person = _personId;
    if (person == null) return;
    try {
      final res = await _client.photoGrowthRebuild(
        body: PhotoGrowthRebuildBody(person: person, granularity: _granularity),
      );
      if (!mounted) return;
      NasSnack.show(context, tr('photo.growth.rebuilt', {'stages': '${res.stages}'}));
      await _loadStages(reset: true);
      final persons = await _client.photoGrowthPersons(limit: 20);
      if (mounted) setState(() => _persons = persons.items);
    } catch (e) {
      if (mounted) NasSnack.show(context, '$e');
    }
  }

  Future<void> _repin(PhotoGrowthStage stage) async {
    final updated = await showDialog<PhotoGrowthStage>(
      context: context,
      builder: (_) => GrowthRepinDialog(stage: stage),
    );
    // 原地刷新：保住滚动位置，别因为换了个封面把人送回第一段
    if (updated != null && mounted) await _loadStages(reset: true, preserveScroll: true);
  }

  Future<void> _openStage(PhotoGrowthStage stage) async {
    var coverChanged = false;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PhotoGrowthStagePage(
          stage: stage,
          onCoverChanged: () => coverChanged = true,
        ),
      ),
    );
    if (!mounted || !coverChanged) return;
    // 只是点开看了几张图就回来 —— 不动列表、不重排、不跳顶部；
    // 真在二级页里换过封面才刷一次，而且刷完要停在原来那一段。
    await _loadStages(reset: true, preserveScroll: true);
  }

  /// 「+」：多选要显示在人物条上的人（默认前 5 个之外的，勾上才出现）。
  Future<void> _showPersonPicker() async {
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _PersonPickerDialog(
        persons: _persons,
        selected: {for (final p in _visiblePersons) p.id},
      ),
    );
    if (picked == null || !mounted) return;
    // 按 _persons 的原顺序落盘：点开又关上不会让条子里的顺序跳来跳去
    final ids = [for (final p in _persons) if (picked.contains(p.id)) p.id];
    if (ids.isEmpty) return;
    await SettingsStore.instance.setString(_barKey, ids.join(','));
    if (!mounted) return;
    setState(() => _barIds = ids);
  }

  String _date(int sec, {bool short = false}) {
    if (sec <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    final m = d.month.toString().padLeft(2, '0');
    return short ? '${d.year}.$m' : '${d.year}-$m-${d.day.toString().padLeft(2, '0')}';
  }

  String _milestoneLabel(String m) {
    if (m == 'firstPlace') return tr('photo.growth.milestoneFirstPlace');
    if (m == 'firstScene') return tr('photo.growth.milestoneFirstScene');
    return '';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _bootstrap);
    final scheme = Theme.of(context).colorScheme;
    final body = <Widget>[
      _summaryLine(),
      const SizedBox(height: 10),
      _controls(scheme),
      const SizedBox(height: 16),
    ];
    if (_personId == null || _persons.isEmpty) {
      body.add(
        NasEmptyState(
          title: tr('photo.growth.noPerson'),
          message: tr('photo.growth.noPersonHint'),
          icon: Icons.face_retouching_natural_outlined,
        ),
      );
    } else if (_stages.isEmpty && !_loadingMore) {
      body.add(
        NasEmptyState(
          title: tr('photo.growth.noStages'),
          message: tr('photo.growth.noStagesHint'),
          icon: Icons.timeline_outlined,
        ),
      );
    } else {
      body.addAll(_yearSections());
    }
    if (_loadingMore) {
      body.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverToBoxAdapter(child: _headerRow()),
        ),
        // 人物条吸顶：时间轴往下翻的时候头像一直贴在顶部，随时能切人。
        if (_persons.isNotEmpty)
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedPersonBar(extent: _personBarHeight, child: _personBar()),
          ),
        SliverPadding(
          // 右边不留 padding：内容自己留 16，让滚动条/内容更贴窗口右边
          padding: const EdgeInsets.fromLTRB(16, 0, 0, 28),
          // 用 builder 懒构建：年份块里的图很多，避免一次把全部段落建出来
          sliver: SliverList.builder(
            itemCount: body.length,
            itemBuilder: (context, i) => body[i],
          ),
        ),
      ],
    );
  }

  Widget _headerRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('photo.growth.title'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 3),
              Text(
                tr('photo.growth.subtitle'),
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: _bootstrap,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  /// 头像(56+4) + 间距 + 名字 + 张数实测约 88~93px，给到 104 免得
  /// 不同字体下顶部人脸条反复报 "RenderFlex overflowed by 1 pixel"。
  static const double _personBarHeight = 104;

  Widget _personBar() {
    final persons = _visiblePersons;
    // 人少的时候「+」没意义（本来就不止 5 个才需要挑）
    final showAdd = _persons.length > _barLimit;
    return SizedBox(
      height: _personBarHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(left: 16, right: 8),
        itemCount: persons.length + (showAdd ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          if (showAdd && i == persons.length) {
            return GestureDetector(
              onTap: _showPersonPicker,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: context.nasStyle.panelColor,
                    child: const Icon(Icons.add),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('photo.growth.personMore'),
                    style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
                  ),
                ],
              ),
            );
          }
          final p = persons[i];
          final active = p.id == _personId;
          return GestureDetector(
            onTap: () => _selectPerson(p.id),
            child: SizedBox(
              width: 74,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: active
                          ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
                          : null,
                    ),
                    child: CircleAvatar(
                      radius: 26,
                      backgroundColor: context.nasStyle.panelColor,
                      backgroundImage: p.coverFaceId == null
                          ? null
                          : NetworkImage(
                              _faceUrl(p.coverFaceId!),
                              headers: ApiSession.instance.authHeaders,
                            ),
                      child: p.coverFaceId == null
                          ? const Icon(Icons.person_outline, size: 24)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    (p.name ?? '').isNotEmpty ? p.name! : tr('photo.growth.unnamed'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  Text(
                    '${p.size}',
                    style: TextStyle(fontSize: 9, color: context.nasTextSecondary),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _summaryLine() {
    final s = _summary;
    if (s == null) return const SizedBox.shrink();
    return Text(
      tr('photo.growth.summary', {
        'first': _date(s.firstAt, short: true),
        'last': _date(s.lastAt, short: true),
        'cities': '${s.cityCount}',
        'stages': '${s.stageCount}',
      }),
      style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
    );
  }

  Widget _controls(ColorScheme scheme) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: () => _setAsc(!_asc),
          icon: Icon(_asc ? Icons.arrow_upward : Icons.arrow_downward, size: 16),
          label: Text(_asc ? tr('photo.growth.asc') : tr('photo.growth.desc')),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _granularity,
              isDense: true,
              items: [
                DropdownMenuItem(value: 'auto', child: Text(tr('photo.growth.auto'))),
                DropdownMenuItem(value: 'month', child: Text(tr('photo.growth.month'))),
                DropdownMenuItem(value: 'quarter', child: Text(tr('photo.growth.quarter'))),
                DropdownMenuItem(value: 'year', child: Text(tr('photo.growth.year'))),
              ],
              onChanged: (v) {
                if (v != null) _setGranularity(v);
              },
            ),
          ),
        ),
        Text(
          tr('photo.growth.granularity'),
          style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
        ),
        const SizedBox(width: 4),
        OutlinedButton.icon(
          onPressed: _rebuild,
          icon: const Icon(Icons.auto_awesome_outlined, size: 16),
          label: Text(tr('photo.growth.rebuild')),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 杂志拼贴
  //
  // 按年份成块，块内保持 3 列节奏：段落卡片负责放封面，诗句块负责补角，
  // 年份数字负责定调。每张卡片的高度由封面原图宽高比决定（AspectRatio），
  // 图片用 contain 完整显示，不再用固定高度 + cover 把横图/竖图裁掉。
  // 同一时刻的多张照片仍在二级页里看，卡片只负责把「这一段的封面」讲清楚。

  List<Widget> _yearSections() {
    if (_stages.isEmpty) return const [];
    final firstYear = _firstYear();
    final groups = <int, List<PhotoGrowthStage>>{};
    final order = <int>[];
    for (final s in _stages) {
      final y = DateTime.fromMillisecondsSinceEpoch(s.startAt * 1000).year;
      if (!groups.containsKey(y)) order.add(y);
      groups.putIfAbsent(y, () => <PhotoGrowthStage>[]).add(s);
    }
    return [
      for (var i = 0; i < order.length; i++) ...[
        _yearSection(order[i], groups[order[i]]!, firstYear),
        if (i < order.length - 1) const SizedBox(height: 26),
      ],
    ];
  }

  /// 「记录第 N 年」的起点：库里没有生日，只能用该人最早一张照片的年份。
  int _firstYear() {
    var first = 0;
    void consider(int sec) {
      if (sec <= 0) return;
      final y = DateTime.fromMillisecondsSinceEpoch(sec * 1000).year;
      if (first == 0 || y < first) first = y;
    }

    for (final s in _stages) {
      consider(s.startAt);
    }
    consider(_summary?.firstAt ?? 0);
    return first;
  }

  Widget _yearSection(int year, List<PhotoGrowthStage> stages, int firstYear) {
    final photos = stages.fold<int>(0, (sum, s) => sum + s.photoCount);
    final n = firstYear > 0 ? year - firstYear + 1 : 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '$year',
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                height: 1.05,
                letterSpacing: -0.6,
              ),
            ),
            Text(
              tr('photo.growth.recordYear', {'n': '$n'}),
              style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
            ),
            Text(
              tr('photo.growth.yearStats', {
                'stages': '${stages.length}',
                'photos': '$photos',
              }),
              style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < stages.length; i++) ...[
          _stageBlock(stages[i]),
          if (i < stages.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ 单列记忆块
  //
  // 页面从上到下是一条单列：一个块（一个时间段 / 一个记忆）占满整行，块与块
  // 纵向排列，高度随内容自适应。瀑布流只发生在块内部 —— 照片区按列紧贴排布，
  // 每列长度各不相同，形成错落；不再是「一行两张卡片」的多列卡片布局。

  Widget _stageBlock(PhotoGrowthStage s) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.nasStyle;
    final unknown = s.placeName.isEmpty;
    final milestone = _milestoneLabel(s.milestone);
    final d = DateTime.fromMillisecondsSinceEpoch(s.startAt * 1000);
    final mm = d.month.toString().padLeft(2, '0');
    final photos = _photosOf(s);
    return GestureDetector(
      onTap: () => _openStage(s),
      onLongPress: () => _repin(s),
      // 块底色走 NasStyle 的面板材质（半透明 + 背景模糊 + 风格描边），
      // 不再用 surfaceContainerHigh —— 深色主题下那是近黑的实色块（2026-11-14 反馈）。
      child: NasPanel(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        radius: 14,
        // 一屏会有十几二十个块，逐个 BackdropFilter 太贵；背景是渐变，
        // 关掉模糊视觉几乎无差别，保留面板色 / 描边 / 阴影即可。
        blur: 0,
        border: Border.all(
          color: unknown
              ? scheme.primary.withValues(alpha: 0.45)
              : style.panelBorderColor,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  unknown ? '${d.year}.$mm' : '${d.year}.$mm · ${s.placeName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: context.nasTextSecondary,
                  ),
                ),
                if (unknown) _unknownChip(),
                if (milestone.isNotEmpty) _milestoneChip(milestone),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, c) {
                // 宽屏把诗句/计数放到右侧文字栏，照片区专心排图；
                // 窄屏文字落到照片下方，避免每列被挤成一条。
                final wide = c.maxWidth >= 860;
                final textWidth = wide ? 220.0 : c.maxWidth;
                final photoWidth = wide ? c.maxWidth - textWidth - 16 : c.maxWidth;
                final columns = photoWidth >= 900
                    ? 4
                    : photoWidth >= 560
                        ? 3
                        : 2;
                final grid = _photoColumns(photos, columns, photoWidth);
                final text = _blockText(s);
                if (!wide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [grid, const SizedBox(height: 10), text],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: grid),
                    const SizedBox(width: 16),
                    SizedBox(width: textWidth, child: text),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 块内照片瀑布流：把照片逐张投进当前最矮的列，每张按列宽等比铺满。
  ///
  /// 列宽固定、高度 = 列宽 / 宽高比，所以照片本身不裁切、不留边；列与列之间的
  /// 高度差就是错落感的来源。段内照片不足时按实际张数收列，不留空位。
  Widget _photoColumns(List<_GrowthPhoto> photos, int columns, double width) {
    const gap = 6.0;
    if (photos.isEmpty) {
      return Container(
        height: 120,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          // 空占位也跟面板同色，避免深色主题下出现一块纯黑
          color: context.nasStyle.panelColor,
          border: Border.all(color: context.nasStyle.panelBorderColor),
        ),
        child: Center(
          child: Icon(Icons.photo_outlined, size: 24, color: context.nasTextSecondary),
        ),
      );
    }
    // 照片少时直接按张数收列，避免右边空出一整列。
    final used = photos.length < columns ? photos.length : columns;
    final colWidth =
        ((width - gap * (used - 1)) / used).clamp(0.0, 380.0).toDouble();
    final buckets = List.generate(used, (_) => <_GrowthPhoto>[]);
    final heights = List.filled(used, 0.0);
    for (final p in photos) {
      var target = 0;
      for (var c = 1; c < used; c++) {
        if (heights[c] < heights[target]) target = c;
      }
      buckets[target].add(p);
      heights[target] += colWidth / p.ratio + gap;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var c = 0; c < used; c++) ...[
          if (c > 0) const SizedBox(width: gap),
          SizedBox(
            width: colWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final p in buckets[c]) ...[
                  _GrowthPhotoTile(
                    path: p.path,
                    width: colWidth,
                    fallbackRatio: p.ratio,
                  ),
                  const SizedBox(height: gap),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 块内文字：诗句 + 段序号/张数。日期和地点角标在块头。
  Widget _blockText(PhotoGrowthStage s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _poemLine(s),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, height: 1.8, letterSpacing: 0.3),
        ),
        const SizedBox(height: 8),
        Text(
          '${tr('photo.growth.stageIndex', {'seq': '${s.seq}'})} · '
          '${tr('photo.growth.photoCount', {'count': '${s.photoCount}'})}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
        ),
      ],
    );
  }

  /// 每段照片：批量结果优先（最多 8 张），没回来/失败时用 stage 自带图兜底。
  List<_GrowthPhoto> _photosOf(PhotoGrowthStage s) {
    final batch = _stagePhotos[s.id];
    if (batch != null && batch.isNotEmpty) {
      final photos = <_GrowthPhoto>[
        for (final p in batch)
          if (p.path.isNotEmpty)
            _GrowthPhoto(p.path, p.width?.toDouble(), p.height?.toDouble()),
      ];
      if (photos.isNotEmpty) return photos.take(maxPhotos).toList();
    }
    return <_GrowthPhoto>[
      if (s.coverPath.isNotEmpty)
        _GrowthPhoto(
          s.coverPath,
          s.coverWidth?.toDouble(),
          s.coverHeight?.toDouble(),
        ),
      if ((s.secondaryPath ?? '').isNotEmpty)
        _GrowthPhoto(
          s.secondaryPath!,
          s.secondaryWidth?.toDouble(),
          s.secondaryHeight?.toDouble(),
        ),
      for (final p in s.extraPaths)
        if (p.isNotEmpty) _GrowthPhoto(p, null, null),
    ].take(maxPhotos).toList();
  }

  Widget _unknownChip() {
    final style = context.nasStyle;
    final scheme = Theme.of(context).colorScheme;
    // 以前是黑色半透明底 + 白字，压在面板上像一块黑补丁；改用面板材质 + 主题描边
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: style.panelColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.place_outlined, size: 11, color: scheme.primary),
          const SizedBox(width: 3),
          Text(
            tr('photo.growth.unknownPlace'),
            style: TextStyle(fontSize: 10, color: scheme.primary),
          ),
        ],
      ),
    );
  }

  Widget _milestoneChip(String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 10, color: Colors.white),
      ),
    );
  }

  /// 诗句：复用现有 6 句 i18n 模板，按段轮换。
  String _poemLine(PhotoGrowthStage s) {
    final d = DateTime.fromMillisecondsSinceEpoch(s.startAt * 1000);
    final place = s.placeName.isEmpty ? tr('photo.growth.somewhere') : s.placeName;
    final args = {
      'place': place,
      'year': '${d.year}',
      'month': '${d.month}',
    };
    return switch (s.seq % 6) {
      0 => tr('photo.growth.poem1', args),
      1 => tr('photo.growth.poem2', args),
      2 => tr('photo.growth.poem3', args),
      3 => tr('photo.growth.poem4', args),
      4 => tr('photo.growth.poem5', args),
      _ => tr('photo.growth.poem6', args),
    };
  }

}

/// 块内瀑布流里的一张缩略图：定宽，高度按真实宽高比撑开。
///
/// 为什么要解码真实尺寸：库里 `photo_items.width/height` 存的是 EXIF 旋转前的
/// 像素（竖拍照片也是 2048×1536），而缩略图是 ffmpeg 自动转正后的竖图。
/// 只看元数据会把竖图当成横图，块内排布就会出现大块留白。
class _GrowthPhotoTile extends StatefulWidget {
  const _GrowthPhotoTile({
    required this.path,
    required this.width,
    required this.fallbackRatio,
  });

  final String path;

  /// 列宽：照片按这个宽度铺满，高度由比例算
  final double width;
  final double fallbackRatio;

  @override
  State<_GrowthPhotoTile> createState() => _GrowthPhotoTileState();
}

class _GrowthPhotoTileState extends State<_GrowthPhotoTile> {
  static const int _thumbSize = 480;
  static const double _minRatio = 0.5;
  static const double _maxRatio = 2.4;

  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _measured;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _GrowthPhotoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _detach();
      _measured = null;
      _resolve();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _resolve() {
    if (widget.path.isEmpty || _stream != null) return;
    // 与 NasCoverImage 用同一个 provider（同样的 cacheWidth 包装），
    // 这样量尺寸不会额外再下一次缩略图，直接复用图片缓存。
    final provider = ResizeImage.resizeIfNeeded(
      _thumbSize,
      null,
      NetworkImage(
        MediaUrls(ApiSession.instance.baseUrl).thumbnail(widget.path, size: _thumbSize),
        headers: ApiSession.instance.authHeaders,
      ),
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        final h = info.image.height;
        if (h <= 0) return;
        final ratio = info.image.width / h;
        if (!mounted) return;
        if (_measured == null || (_measured! - ratio).abs() > 0.01) {
          setState(() => _measured = ratio);
        }
      },
      onError: (Object error, StackTrace? stack) {},
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  double get _ratio =>
      (_measured ?? widget.fallbackRatio).clamp(_minRatio, _maxRatio).toDouble();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: widget.width,
        // 高度完全由真实比例决定：块内的错落感就来自各列高度不同
        height: widget.width / _ratio,
        child: NasCoverImage(
          url: MediaUrls(ApiSession.instance.baseUrl)
              .thumbnail(widget.path, size: _thumbSize),
          headers: ApiSession.instance.authHeaders,
          cacheWidth: _thumbSize,
          // 槽位比例就是照片比例，contain 只是兜底不裁切
          fit: BoxFit.contain,
          icon: Icons.broken_image_outlined,
        ),
      ),
    );
  }
}

/// 阶段二级页：这个时期的全部照片（真分页）+ 换封面。
/// 块内瀑布流里的一张照片：路径 + 原图宽高（用于估算列高）。
class _GrowthPhoto {
  const _GrowthPhoto(this.path, this.width, this.height);

  final String path;
  final double? width;
  final double? height;

  /// 原图宽高比；缺数据按 4:3，极端比例夹到 0.55~2.2 只防布局爆掉。
  double get ratio {
    final w = width ?? 0;
    final h = height ?? 0;
    if (w <= 0 || h <= 0) return 4.0 / 3.0;
    return (w / h).clamp(0.55, 2.2).toDouble();
  }
}

class PhotoGrowthStagePage extends StatefulWidget {
  const PhotoGrowthStagePage({super.key, required this.stage, this.onCoverChanged});

  final PhotoGrowthStage stage;

  /// 换过封面就通知列表页「回来要刷一次」。
  ///
  /// 只在真换过时通知：用户只是点开看几张图就返回的话，列表页连请求都不用发，
  /// 更不会因为重排把滚动位置冲掉。
  final VoidCallback? onCoverChanged;

  @override
  State<PhotoGrowthStagePage> createState() => _PhotoGrowthStagePageState();
}

class _PhotoGrowthStagePageState extends State<PhotoGrowthStagePage> {
  static const _pageSize = 60;

  late PhotoGrowthStage _stage;
  bool _loading = true;
  String? _error;
  List<PhotoItem> _photos = const [];
  int _total = 0;
  String? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  final ScrollController _scroll = ScrollController();

  ApiClient get _client => ApiSession.instance.client;
  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  String _thumb(String path, {int size = 320}) => _media.thumbnail(path, size: size);

  @override
  void initState() {
    super.initState();
    _stage = widget.stage;
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_scroll.position.extentAfter < 360) _load(reset: false);
  }

  Future<void> _load({required bool reset}) async {
    if (_loadingMore) return;
    setState(() {
      _loadingMore = true;
      if (reset) _loading = true;
      _error = null;
    });
    try {
      final res = await _client.photoGrowthStagePhotos(
        stageId: _stage.id,
        cursor: reset ? null : _cursor,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _photos = reset ? List<PhotoItem>.from(res.items) : [..._photos, ...res.items];
        _total = res.total;
        _cursor = res.nextCursor;
        _hasMore = res.nextCursor != null;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _repin() async {
    final updated = await showDialog<PhotoGrowthStage>(
      context: context,
      builder: (_) => GrowthRepinDialog(stage: _stage),
    );
    if (updated == null || !mounted) return;
    setState(() => _stage = updated);
    widget.onCoverChanged?.call();
    NasSnack.show(context, tr('photo.growth.repinDone'));
  }

  String _date(int sec) {
    if (sec <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width > 1100 ? 6 : width > 800 ? 5 : width > 560 ? 4 : 3;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _stage.placeName.isEmpty ? tr('photo.growth.unknownPlace') : _stage.placeName,
        ),
        actions: [
          TextButton.icon(
            onPressed: _repin,
            icon: const Icon(Icons.swap_horiz, size: 16),
            label: Text(tr('photo.growth.repin')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
              ? NasErrorState(message: _error!, onRetry: () => _load(reset: true))
              : CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_date(_stage.startAt)} — ${_date(_stage.endAt)}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              tr('photo.growth.stagePhotos', {'count': '$_total'}),
                              style: TextStyle(
                                fontSize: NasTokens.fontCaption,
                                color: context.nasTextSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) {
                            final item = _photos[i];
                            return GestureDetector(
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => PhotoViewerPage(items: _photos, initialIndex: i),
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: NasCoverImage(
                                  url: _thumb(item.path),
                                  headers: ApiSession.instance.authHeaders,
                                  cacheWidth: 320,
                                ),
                              ),
                            );
                          },
                          childCount: _photos.length,
                        ),
                      ),
                    ),
                    if (_loadingMore)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      ),
                  ],
                ),
    );
  }
}

/// 「换一张」：列出服务端候选池里的 3 张，选中后写 manual_pin。
class GrowthRepinDialog extends StatefulWidget {
  const GrowthRepinDialog({super.key, required this.stage});

  final PhotoGrowthStage stage;

  @override
  State<GrowthRepinDialog> createState() => _GrowthRepinDialogState();
}

class _GrowthRepinDialogState extends State<GrowthRepinDialog> {
  bool _loading = true;
  String? _error;
  List<PhotoGrowthCandidate> _items = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiSession.instance.client.photoGrowthStageCandidates(
        stageId: widget.stage.id,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
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

  Future<void> _pick(String assetId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.photoGrowthStageRepin(
        body: PhotoGrowthRepinBody(stageId: widget.stage.id, assetId: assetId),
      );
      if (mounted) Navigator.of(context).pop(res.stage);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      NasSnack.show(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('photo.growth.repinTitle')),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(height: 160, child: Center(child: NasLoading()))
            : _error != null
                ? SizedBox(height: 120, child: Center(child: Text(_error!)))
                : _items.isEmpty
                    ? SizedBox(
                        height: 120,
                        child: Center(child: Text(tr('photo.growth.noCandidates'))),
                      )
                    : SizedBox(
                        height: 170,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _items.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (_, i) {
                            final c = _items[i];
                            return GestureDetector(
                              onTap: () => _pick(c.assetId),
                              child: Stack(
                                children: [
                                  SizedBox(
                                    width: 150,
                                    child: PhotoAdaptiveImage(
                                      path: c.path,
                                      minHeight: 100,
                                      maxHeight: 170,
                                      thumbSize: 320,
                                      borderRadius: 8,
                                    ),
                                  ),
                                  if (_busy)
                                    const Positioned.fill(
                                      child: ColoredBox(color: Colors.black26),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('common.cancel')),
        ),
      ],
    );
  }
}

/// 人物条「+」的选择器：勾选要摆在顶部条子上的人。
///
/// 库里聚类可能有几十个，全铺在条子上既挤又难找，所以默认只放前 5 个，
/// 其余的在这里勾选后才出现（选择由调用方写入 SettingsStore）。
class _PersonPickerDialog extends StatefulWidget {
  const _PersonPickerDialog({required this.persons, required this.selected});

  final List<PhotoGrowthPerson> persons;
  final Set<String> selected;

  @override
  State<_PersonPickerDialog> createState() => _PersonPickerDialogState();
}

class _PersonPickerDialogState extends State<_PersonPickerDialog> {
  String _query = '';
  late final Set<String> _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final items = widget.persons
        .where((p) => q.isEmpty || (p.name ?? '').toLowerCase().contains(q))
        .toList();
    return AlertDialog(
      title: Text(tr('photo.growth.personPicker')),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tr('photo.growth.personPickerHint'),
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final p = items[i];
                  final named = (p.name ?? '').isNotEmpty;
                  final on = _picked.contains(p.id);
                  return CheckboxListTile(
                    dense: true,
                    value: on,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _picked.add(p.id);
                      } else {
                        _picked.remove(p.id);
                      }
                    }),
                    title: Text(named ? p.name! : tr('photo.growth.unnamed')),
                    subtitle: Text(
                      named
                          ? tr('photo.growth.photoCount', {'count': '${p.size}'})
                          : tr('photo.growth.namedHint'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          // 至少留一个人，否则条子空了没得切
          onPressed: _picked.isEmpty ? null : () => Navigator.of(context).pop(_picked),
          child: Text(tr('common.confirm')),
        ),
      ],
    );
  }
}

/// 吸顶的人物条代理。
///
/// 这个项目的 `scaffoldBackgroundColor` 是透明的（背景由 NasStyle 铺在 MaterialApp
/// 底层），所以吸顶条必须自己合成一层**不透明**底色，否则时间轴卡片滚过去会从
/// 头像和名字的缝里透出来。
class _PinnedPersonBar extends SliverPersistentHeaderDelegate {
  const _PinnedPersonBar({required this.extent, required this.child});

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final spec = context.nasStyle;
    final solid = Color.alphaBlend(spec.panelColor, spec.baseColor);
    return Container(
      height: extent,
      decoration: BoxDecoration(
        color: solid,
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
        boxShadow: overlapsContent
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: child,
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedPersonBar old) =>
      old.extent != extent || old.child != child;
}
