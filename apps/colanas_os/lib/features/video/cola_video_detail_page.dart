import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/codec_support.dart';
import '../../core/play_preferences.dart';
import '../../core/play_quality_scope.dart';
import '../../core/session.dart';
import 'player_page.dart';
import 'video_card.dart';
import 'video_collection_picker.dart';
import 'video_genre_labels.dart';
import 'video_jp_pages.dart';
import 'video_list_view.dart';
import 'video_scrape_dialogs.dart';
import 'video_item_actions.dart';
import 'series_display.dart';
import 'video_series_widgets.dart';
import 'short_play_page.dart';
import 'library_types.dart';
import 'detail/video_detail_kit.dart';
import 'detail/video_detail_router.dart';

/// 字幕下拉框显示名：内嵌字幕轨没有有效语言（常见 `und`）时显示「内嵌字幕 N」，
/// 不要把 `#embedded:N` 直接丢给用户。
String _subtitleLabel(VideoSubtitleFile sub) {
  final m = RegExp(r'^#embedded:(\d+)$').firstMatch(sub.name);
  if (m != null) {
    final n = (int.tryParse(m.group(1) ?? '') ?? 0) + 1;
    return tr('player.embeddedSubtitle', {'n': '$n'});
  }
  final lang = sub.lang;
  if (lang == null || lang.isEmpty || lang.toLowerCase() == 'und') {
    return sub.name;
  }
  return '${sub.name}（$lang）';
}

/// 影片详情。
///
/// 结构照既有实现的分区：**顶部信息（海报 + 片名 + 年份/片长/评分/类型/地区）
/// → 操作条 → 剧情简介 → 演职人员 → 剧集 → 技术信息**。
///
/// 与旧版的关键差别：旧版只有一张 16:9 首帧 + 8 行技术参数，
/// 刮削出来的东西一个都没地方显示，看起来就像「没有刮削」。
class VideoDetailPage extends StatefulWidget {
  const VideoDetailPage({
    super.key,
    required this.item,
    required this.posterUrl,
    required this.headers,
    this.embedded = false,
  });

  final VideoItem item;

  /// 兼容旧调用点；内部一律按 item 自己算海报地址（刮削海报优先）
  final String posterUrl;
  final Map<String, String> headers;

  /// true = 作为三级页放进影视壳的内容区：
  /// 不画自己的 AppBar（操作改挂右上角浮层），返回交给外壳（`ShellBack`）。
  final bool embedded;

  @override
  State<VideoDetailPage> createState() => VideoDetailPageState();
}

class VideoDetailPageState extends State<VideoDetailPage> {
  late VideoItem _item = widget.item;
  bool _busy = false;
  double _percent = 0;
  String? _position;
  late bool _favorite = widget.item.favorite;
  List<VideoItem> _seriesEpisodes = const [];

  /// 演员名 → 头像 / 身高 / 生日（详情页「演职人员」区用）。
  /// 一次批量问，避免每个演员发一次请求。
  Map<String, Map<String, dynamic>> _actorInfo = const {};

  /// 当前选中的集（只影响「播放起点」与「文件信息」，不动头部信息）。
  ///
  /// 单集页 / 季详情是同一页：`null` 表示还没点过，等价于本页自带的这一集。
  String? _selectedId;

  /// 选集网格里要展示的集。**只列当前这一季**——跨季混排会让人以为
  /// 「第 3 季第 2 集」是这部片的第 2 集（总览页负责选季）。
  List<VideoItem> get _episodes {
    final all = [..._seriesEpisodes]
      ..sort((a, b) {
        final sa = a.season ?? 1;
        final sb = b.season ?? 1;
        if (sa != sb) return sa.compareTo(sb);
        return (a.episode ?? 0).compareTo(b.episode ?? 0);
      });
    if (all.length <= 1) return all;
    final seasons = all.map((e) => e.season ?? 1).toSet();
    if (seasons.length <= 1) return all;
    final cur = _item.season ?? 1;
    final same = all.where((e) => (e.season ?? 1) == cur).toList();
    return same.isEmpty ? all : same;
  }

  /// 当前选中的条目：选过就看选集，没选过就是本页这一条。
  VideoItem get _selected {
    final id = _selectedId;
    if (id == null || id == _item.id) return _item;
    for (final e in _seriesEpisodes) {
      if (e.id == id) return e;
    }
    return _item;
  }

  /// 演职人员（导演在前，演员在后）。
  ///
  /// 用**本页这一条**的演职，不跟选中集走：剧集元数据是剧级的，逐集切换时
  /// 演职区整块消失再出现纯属闪屏（个别集没刮到演员时就会出现）。
  List<VideoPerson> get _people => videoPeopleOf(_item, avatarInfo: _actorInfo);

  @override
  void initState() {
    super.initState();
    // 剧中文名 / TMDB 竖版海报是展示层补充，拉到后重画一次即可
    SeriesDisplayStore.ensure().then((_) {
      if (mounted) setState(() {});
    });
    _loadProgress();
    _loadEpisodes();
    _loadActorInfo();
  }

  Future<void> _loadActorInfo() async {
    final names = [
      for (final n in [..._item.directors, ..._item.actors]) videoPersonName(n),
    ];
    if (names.isEmpty) return;
    try {
      final res = await ApiSession.instance.client.videoActorAvatars(
        body: {'names': names.take(48).toList()},
      );
      if (!mounted) return;
      final list = (res['items'] as List?) ?? const [];
      final map = <String, Map<String, dynamic>>{};
      for (final e in list) {
        if (e is Map) map['${e['name'] ?? ''}'] = Map<String, dynamic>.from(e);
      }
      setState(() => _actorInfo = map);
    } catch (_) {
      // 拿不到就只显示名字，不影响详情
    }
  }

  Future<void> _refreshItem() async {
    try {
      final fresh = await ApiSession.instance.client.videoItem(id: _item.id);
      if (!mounted) return;
      setState(() {
        _item = fresh;
        _favorite = fresh.favorite;
      });
    } catch (_) {
      // 刷新失败就保持旧数据，不弹错（刮削返回里已经给了具体原因）
    }
  }

  Future<void> _loadProgress() async {
    try {
      final p = await ApiSession.instance.client.videoProgress(id: _item.id);
      if (!mounted) return;
      setState(() {
        _percent = p.percent.toDouble();
        _position = p.position;
      });
    } catch (_) {
      // 没有进度是正常情况
    }
  }

  Future<void> _loadEpisodes() async {
    final series = _item.series;
    if (series == null || series.isEmpty) return;
    try {
      final res = await ApiSession.instance.client.videoSeriesItems(
        name: series,
      );
      if (!mounted) return;
      setState(() => _seriesEpisodes = res.items);
    } catch (_) {
      // 剧集读取失败不影响详情
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    NasSnack.show(context, text);
  }

  Future<void> _toggleFavorite() async {
    final target = !_favorite;
    setState(() => _favorite = target);
    try {
      await ApiSession.instance.client.videoFavoriteSet(
        body: VideoFavoriteBody(ids: [_item.id], favorite: target),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _favorite = !target);
      _toast('$e');
    }
  }

  Future<void> _toggleWatched() async {
    final target = !_item.watched;
    setState(() => _busy = true);
    try {
      await ApiSession.instance.client.videoWatchMark(
        body: VideoWatchBody(
          ids: [_item.id],
          watched: target,
          // 点的是「这部剧」→ 服务端展开到全部集
          expandSeries: _item.series != null,
        ),
      );
      await _refreshItem();
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveProgress() async {
    try {
      final p = await ApiSession.instance.client.videoProgressSave(
        body: VideoProgressBody(
          id: _item.id,
          percent: _percent.round(),
          position: _position,
        ),
      );
      if (!mounted) return;
      setState(() {
        _percent = p.percent.toDouble();
        _position = p.position;
      });
      _toast(tr('common.progressSaved', {'percent': '${p.percent}'}));
    } catch (e) {
      _toast(tr('common.saveFailed', {'error': '$e'}));
    }
  }

  /// 播放：从**当前选中集**起播（没选过就是本页这一条）。
  Future<void> _openPlayer() async {
    final target = _selected;
    // 短剧：进上下切换的连播页，而不是单集播放器
    if (VideoLibraryTypes.isShortTv(target.libraryId) &&
        _seriesEpisodes.length > 1) {
      final idx = _seriesEpisodes.indexWhere((e) => e.id == target.id);
      await openShortPlay(context, _seriesEpisodes, idx < 0 ? 0 : idx);
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(
        id: target.id,
      );
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            url: url,
            title: target.title,
            itemId: target.id,
            // 兼容判定（DV / HDR / HEVC / EAC3）交给播放器决定要不要自动转码
            compat: res.compat,
            // 档位菜单按片源分辨率收敛，别列出这部片转不出来的档
            sourceHeight: target.height,
            // 媒体信息面板要显示「源码率 → 目标码率」，源码率 = size ÷ 时长
            sourceBytes: target.size,
            // 转码是边转边播，播放器拿不到总长，用片源时长兜进度条
            durationMs: target.durationMs,
          ),
        ),
      );
    } catch (e) {
      _toast(tr('video.playUrlFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyPlayUrl() async {
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(id: _item.id);
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      await Clipboard.setData(ClipboardData(text: url));
      _toast(
        tr('video.copyUrl', {'hours': '${(res.expiresInSec / 3600).round()}'}),
      );
    } catch (e) {
      _toast(tr('video.playUrlFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: _item.path));
    _toast(tr('ui.book.020'));
  }

  Future<void> _openTranscode() async {
    List<VideoSubtitleFile> subtitles = const [];
    try {
      final res = await ApiSession.instance.client.videoSubtitles(id: _item.id);
      subtitles = res.items;
    } catch (_) {
      // 字幕读取失败不影响转码
    }
    if (!mounted) return;

    // 编码按**当前端的真实解码能力**回落，不按平台一刀切：
    // 浏览器只要 MSE 认这个 codec（Chrome 早就认 AV1 / HEVC），就该让它转这个编码。
    var codec = PlayPreferences.codec;
    if (!codecPlayable(codec)) codec = 'h264';
    // 档位按片源收敛：片源只有 720p 时，4K / 2K / 1080P 这些档根本转不出来，
    // 列在菜单里既选不动也误导（选 1080P 只是把 720p 放大再压一遍，纯浪费 CPU）。
    final sourceHeight = _item.height ?? 0;
    var preset = clampPresetForSource(
      PlayPreferences.preset,
      sourceHeight,
      codec: codec,
    );
    String? subtitle;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('video.transcode.title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NasDropdown<String>(
                initialValue: preset,
                decoration: InputDecoration(
                  labelText: tr('video.transcode.preset'),
                ),
                items: [
                  for (final p in presetsForSource(sourceHeight))
                    DropdownMenuItem(
                      value: p.key,
                      child: Text(p.labelFor(codec)),
                    ),
                ],
                onChanged: (v) => setLocal(() => preset = v ?? preset),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              NasDropdown<String>(
                initialValue: codec,
                decoration: InputDecoration(
                  labelText: tr('video.transcode.codec'),
                ),
                items: [
                  for (final c in playableCodecs())
                    DropdownMenuItem(value: c.key, child: Text(c.label)),
                ],
                onChanged: (v) => setLocal(() => codec = v ?? codec),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              NasDropdown<String?>(
                initialValue: subtitle,
                decoration: InputDecoration(
                  labelText: tr('video.transcode.subtitle'),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(tr('video.transcode.none')),
                  ),
                  for (final s in subtitles)
                    DropdownMenuItem<String?>(
                      value: s.name,
                      child: Text(_subtitleLabel(s)),
                    ),
                ],
                onChanged: (v) => setLocal(() => subtitle = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('video.transcode.start')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final navigator = Navigator.of(context);
    await PlayPreferences.save(preset: preset, codec: codec);
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final created = await ApiSession.instance.client.playerSessionCreate(
        body: PlayerSessionCreateBody(
          id: _item.id,
          preset: preset,
          codec: codec,
          subtitle: subtitle,
          // 客户端音频偏好：只有显式打开才带（null = 不传 = 跟随库级 audio_normalize）
          audioNormalize: PlayPreferences.audioNormalize ? true : null,
          audioDownmix: PlayPreferences.audioDownmix ? true : null,
          // 详情页「转码」也要走同一份默认提前转码时长，不能漏传后由服务端兜底成别的档
          leadMinutes: PlayPreferences.leadMinutes,
        ),
      );
      var job = await ApiSession.instance.client.playerSessionGet(
        id: created.id,
      );
      // 边转边播：只要会话开始产片（running）就进播放器，服务端会等到首个分片
      // 落盘再返回 m3u8。以前这里死等 status=done，4K / AV1 片要等几十分钟，
      // 超时后还报「转码未完成」，实际上完全没必要等整片。
      for (
        var i = 0;
        i < 20 && (job.status == 'pending' || job.status == 'running');
        i++
      ) {
        // running 说明 ffmpeg 已启动，首片最多几秒；不用再轮询到 done
        if (job.status == 'running') break;
        await Future<void>.delayed(const Duration(seconds: 1));
        job = await ApiSession.instance.client.playerSessionGet(id: created.id);
      }
      if (job.status == 'failed' || job.status == 'canceled') {
        _toast(
          tr('video.transcodeIncomplete', {
            'status': job.status,
            'error': job.error ?? '',
          }),
        );
        return;
      }
      if (!mounted) return;
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            url: '${ApiSession.instance.baseUrl}${job.url}',
            title: _item.title,
            itemId: _item.id,
            // 这个地址已经是选定档位的 HLS 会话，别让播放器再按直链处理
            initialPreset: preset,
            // 会话 id 带进去：媒体信息面板要显示转码状态和实际编码
            initialSessionId: created.id,
            sourceHeight: _item.height,
            sourceBytes: _item.size,
            durationMs: _item.durationMs,
          ),
        ),
      );
    } catch (e) {
      _toast(tr('video.transcodeFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scrape({bool force = false}) async {
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.videoScrapeStart(
        body: VideoScrapeBody(id: _item.id, mode: force ? 'force' : 'auto'),
      );
      if (!mounted) return;
      await showScrapeOutcome(context, res);
      await _refreshItem();
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manualMatch() async {
    final ok = await showTmdbMatchDialog(context, item: _item);
    if (ok) await _refreshItem();
  }

  Future<void> _cleanup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Text(tr('video.action.scrapeCleanup')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.ok')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ApiSession.instance.client.videoScrapeCleanup(
        body: VideoScrapeCleanupBody(id: _item.id),
      );
      _toast(tr('video.scrape.cleaned'));
      await _refreshItem();
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exclude() async {
    setState(() => _busy = true);
    try {
      await ApiSession.instance.client.videoScrapeMatch(
        body: VideoMatchNfoBody(id: _item.id, match: false),
      );
      _toast(tr('video.scrape.excluded'));
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final eps = _episodes;
    final hasEpisodes = eps.length > 1;

    return Scaffold(
      // 背景是模糊封面，内容从顶上压下来；AppBar 只留返回与菜单
      extendBodyBehindAppBar: !widget.embedded,
      // 嵌入模式不画 AppBar：顶栏由外壳提供，操作改挂右上角浮层
      appBar: widget.embedded ? null : _appBar(context),
      body: Stack(
        children: [
          Positioned.fill(child: _backdrop(context, item)),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, c) {
                // 断点用**内容区宽度**而不是屏幕宽度：外壳左侧有一二级栏，
                // 拿屏幕宽会在大窗口下误判成桌面（海报突然变超大）。
                final mode = layoutFor(c.maxWidth);
                // 内容铺满三级页：不再按 1080 限宽居中，也不按档位加 48/32 的大边距。
                // 用户 2026-11-11：「铺满三级页面，而不是只有一部分，就像手机一样」。
                const double hPad = 16.0;
                final top = widget.embedded
                    ? NasTokens.spaceSm
                    : MediaQuery.of(context).padding.top +
                          kToolbarHeight +
                          NasTokens.spaceSm;

                return RefreshIndicator(
                  onRefresh: _refreshItem,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: <Widget>[
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(hPad, top, hPad, 0),
                        sliver: SliverToBoxAdapter(
                          child: _headSection(context, item, mode),
                        ),
                      ),
                      if ((item.overview ?? '').trim().isNotEmpty)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 0),
                          sliver: SliverToBoxAdapter(
                            child: VideoSection(
                              title: tr('video.detail.overview'),
                              child: VideoExpandableText(item.overview!),
                            ),
                          ),
                        ),
                      if (hasEpisodes) ...<Widget>[
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 10),
                          sliver: SliverToBoxAdapter(
                            child: videoSectionHead(
                              context,
                              tr('video.detail.episodes'),
                              trailing: '${eps.length}',
                            ),
                          ),
                        ),
                        videoEpisodeGridSliver(
                          episodes: eps,
                          selectedId: _selected.id,
                          onPlay: (ep) => _playEpisode(ep),
                          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 0),
                          menuEntries: (ep) => videoItemMenuEntries(
                            ep,
                            onAction: (action) => _episodeAction(action, ep),
                          ),
                        ),
                      ],
                      if (_people.isNotEmpty)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 0),
                          sliver: SliverToBoxAdapter(
                            child: VideoSection(
                              title: tr('video.detail.people'),
                              // 横向滚动区自己带左右内边距，卡片不再套一层内边距
                              cardPadding: EdgeInsets.zero,
                              child: VideoActorRail(
                                people: _people,
                                onTap: _openPerson,
                              ),
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 0),
                        sliver: SliverToBoxAdapter(
                          child: VideoSection(
                            title: tr('video.detail.fileAndTech'),
                            child: VideoFilePanel(item: _selected, mode: mode),
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(
                        child: SizedBox(height: NasTokens.spaceXl),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (widget.embedded)
            Positioned(top: 8, right: 8, child: _floatingActions(context)),
        ],
      ),
    );
  }

  /// 未嵌入时（整页路由形态）的顶栏：返回 + 刮削 + 更多。
  AppBar _appBar(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: Colors.white,
      title: const SizedBox.shrink(),
      flexibleSpace: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: 0.5), Colors.transparent],
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: tr('video.action.scrape'),
          onPressed: _busy ? null : () => _scrape(),
          icon: const Icon(Icons.auto_awesome_outlined),
        ),
        PopupMenuButton<String>(
          onSelected: _onMenuSelected,
          itemBuilder: (_) => _menuItems(),
        ),
      ],
    );
  }

  void _onMenuSelected(String v) {
    switch (v) {
      case 'force':
        _scrape(force: true);
      case 'match':
        _manualMatch();
      case 'cleanup':
        _cleanup();
      case 'exclude':
        _exclude();
      case 'copyPath':
        _copyPath();
      case 'about':
        _showAbout();
    }
  }

  List<PopupMenuEntry<String>> _menuItems() {
    return [
      PopupMenuItem(
        value: 'force',
        child: Text(tr('video.action.scrapeForce')),
      ),
      PopupMenuItem(value: 'match', child: Text(tr('video.action.matchTmdb'))),
      PopupMenuItem(
        value: 'cleanup',
        child: Text(tr('video.action.scrapeCleanup')),
      ),
      PopupMenuItem(
        value: 'exclude',
        child: Text(tr('video.action.excludeScrape')),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'copyPath',
        child: Text(tr('video.action.copyPath')),
      ),
      PopupMenuItem(value: 'about', child: Text(tr('video.detail.about'))),
    ];
  }

  /// 「关于」：原来贴在页面底部的播放器说明文字收进这里（PRD 要求）。
  Future<void> _showAbout() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.detail.about')),
        content: Text(tr('ui.video.h390648')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.close')),
          ),
        ],
      ),
    );
  }

  /// 嵌入模式的浮层操作：刮削 + 更多菜单，黑色半透明胶囊保证在封面上也看得清
  Widget _floatingActions(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(999),
      child: IconTheme(
        data: const IconThemeData(color: Colors.white),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: tr('video.action.scrape'),
              onPressed: _busy ? null : () => _scrape(),
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'force':
                    _scrape(force: true);
                  case 'match':
                    _manualMatch();
                  case 'cleanup':
                    _cleanup();
                  case 'exclude':
                    _exclude();
                  case 'copyPath':
                    _copyPath();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'force',
                  child: Text(tr('video.action.scrapeForce')),
                ),
                PopupMenuItem(
                  value: 'match',
                  child: Text(tr('video.action.matchTmdb')),
                ),
                PopupMenuItem(
                  value: 'cleanup',
                  child: Text(tr('video.action.scrapeCleanup')),
                ),
                PopupMenuItem(
                  value: 'exclude',
                  child: Text(tr('video.action.excludeScrape')),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'copyPath',
                  child: Text(tr('video.action.copyPath')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 背景：模糊封面 + 表面色压暗。
  ///
  /// 截图里的观感是「整页深色、左上角透出海报的色块」，所以用封面自身做底、
  /// 高斯模糊后压一层 72%~100% 的表面色，文字始终可读。
  Widget _backdrop(BuildContext context, VideoItem item) {
    final scheme = Theme.of(context).colorScheme;
    final art = videoPosterUrl(item, kind: 'fanart', size: 640);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: 36,
              sigmaY: 36,
              tileMode: TileMode.decal,
            ),
            child: NasCoverImage(
              url: art,
              fit: BoxFit.cover,
              headers: videoArtHeaders,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.surface.withValues(alpha: 0.74),
                  scheme.surface.withValues(alpha: 0.92),
                  scheme.surface,
                ],
                stops: const [0, 0.42, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部信息区：左海报 + 右标题 / 元信息 / 画质标签 / 操作。
  ///
  /// 海报宽度、字号、窄屏竖排全部由 [VideoDetailHeader] 按断点决定，
  /// 电影 / 剧集总览 / 季详情共用同一份，三页头部不会再各长一个样。
  Widget _headSection(BuildContext context, VideoItem item, LayoutMode mode) {
    final runtime = (item.runtimeMin ?? 0) > 0
        ? item.runtimeMin!
        : ((item.durationMs ?? 0) / 60000).round();
    final meta = <String>[
      if ((item.year ?? 0) > 0) '${item.year}',
      ...genreLabels(item.genres.take(3)),
      if (item.regions.isNotEmpty) item.regions.first,
      if (runtime > 0) tr('video.detail.minutes', {'count': '$runtime'}),
    ];
    final flags = videoFlagsOf(item);

    return VideoDetailHeader(
      title: _displayTitle(item),
      mode: mode,
      originalTitle: item.originalName,
      posterUrl: videoPosterUrl(item, size: 480),
      posterText: item.title,
      meta: meta,
      score: item.score ?? 0,
      // 番号（日本库）排在画质标签前面，跟卡片角标的口径一致
      badges: <String>[if ((item.code ?? '').isNotEmpty) item.code!, ...flags],
      // 嵌入模式右上角有一枚浮层胶囊（刮削 + 更多），标题行要让出这段宽度，
      // 否则长片名会被胶囊盖住（2026-11-11 用户截图）。
      trailingReserve: widget.embedded ? 104 : 0,
      actions: _actionRow(context, item),
    );
  }

  /// 详情页标题：电视剧显示剧名（多季再补「第 N 季」），电影仍显示片名。
  String _displayTitle(VideoItem item) {
    final series = (item.series ?? '').trim();
    if (series.isEmpty) return item.title;
    final name =
        SeriesDisplayStore.nameOf(series) ?? _zhSeriesName(series, item.path);
    final seasons = _seriesEpisodes.map((e) => e.season ?? 1).toSet().length;
    final n = item.season ?? 0;
    if (seasons > 1 && n > 0) {
      return '$name · ${tr('video.series.season', {'n': '$n'})}';
    }
    return name;
  }

  /// series 列是英文发布名；目录 / 文件名里常带中文剧名，优先用它。
  String _zhSeriesName(String series, String path) {
    final re = RegExp(r'[\u3400-\u9fff][\u3400-\u9fff0-9A-Za-z·：:，,、\s]{1,30}');
    for (final s in [series, path]) {
      final m = re.firstMatch(s);
      if (m == null) continue;
      final t = (m.group(0) ?? '').trim().replaceAll(
        RegExp(r'[\s.,·:：，、]+$'),
        '',
      );
      if (t.length >= 2) return t;
    }
    return series;
  }

  /// 续播起点：优先用上报的播放位置，缺失时按片长 × 百分比估算。
  int? _resumeMinutes(VideoItem item, double percent) {
    final raw = (_position ?? '').trim();
    if (raw.isNotEmpty) {
      final ms = int.tryParse(raw);
      if (ms != null) return ms ~/ 60000;
      final parts = raw.split(':');
      if (parts.length >= 2) {
        final h = int.tryParse(parts[0].trim()) ?? 0;
        final m = int.tryParse(parts[1].trim()) ?? 0;
        return h * 60 + m;
      }
    }
    final duration = item.durationMs ?? 0;
    if (duration > 0) return (duration * percent / 100 / 60000).floor();
    return null;
  }

  String? _resumeHint(VideoItem item) {
    if (_percent <= 0 || _percent >= 95) return null;
    final minutes = _resumeMinutes(item, _percent);
    if (minutes == null) return null;
    final n = item.episode ?? 0;
    if ((item.series ?? '').isNotEmpty && n > 0) {
      return tr('video.detail.resumeEpisodeMinute', {
        'episode': '$n',
        'minute': '$minutes',
      });
    }
    return tr('video.detail.resumeMinute', {'minute': '$minutes'});
  }

  /// 操作行：播放胶囊 + 三个圆形按钮（收藏 / 已看 / 更多）。
  ///
  /// 有播放记录 →「继续播放」，没有 →「播放」；按钮下方给出续播起点。
  Widget _actionRow(BuildContext context, VideoItem item) {
    // 进度只属于**本页这一条**；用户在选集网格里换了别的集之后，
    // 「继续播放」就不成立了（那集会从头播），标签要跟着变回「播放」。
    final onPage = _selected.id == _item.id;
    final hasProgress = onPage && _percent > 0 && _percent < 100;
    final hint = hasProgress ? _resumeHint(item) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _openPlayer,
              icon: const Icon(Icons.play_arrow, size: 20),
              label: Text(
                hasProgress
                    ? tr('video.series.resume')
                    : (onPage || (_selected.episode ?? 0) <= 0
                          ? tr('video.series.play')
                          // 刚点播过别的集（播完返回）：按钮点名要播第几集，
                          // 否则读者会以为顶部按钮播的仍是页头那一条
                          : tr('video.detail.playEpisode', {
                              'n': '${_selected.episode}',
                            })),
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                shape: const StadiumBorder(),
              ),
            ),
            _circleAction(
              context,
              icon: _favorite ? Icons.favorite : Icons.favorite_border,
              tooltip: _favorite
                  ? tr('video.action.unfavorite')
                  : tr('video.action.favorite'),
              active: _favorite,
              onTap: _toggleFavorite,
            ),
            _circleAction(
              context,
              icon: item.watched
                  ? Icons.check_circle
                  : Icons.check_circle_outline,
              tooltip: item.watched
                  ? tr('video.action.markUnwatched')
                  : (item.series != null
                        ? tr('video.action.markTvWatched')
                        : tr('video.action.markWatched')),
              active: item.watched,
              onTap: _busy ? null : _toggleWatched,
            ),
            _circleAction(
              context,
              icon: Icons.more_horiz,
              tooltip: tr('video.card.more'),
              onTap: () => _showMoreActions(context, item),
            ),
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 6),
          Text(
            hint,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ],
    );
  }

  Widget _circleAction(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active
            ? scheme.primary.withValues(alpha: 0.16)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              size: 20,
              color: active ? scheme.primary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  /// 「更多」里保住的原来那些动作（转码 / 合集 / 复制 / 强制刮削 / 进度）。
  Future<void> _showMoreActions(BuildContext context, VideoItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.high_quality_outlined),
              title: Text(tr('ui.video.019')),
              onTap: () => Navigator.pop(ctx, 'transcode'),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: Text(tr('video.collection.addTo')),
              onTap: () => Navigator.pop(ctx, 'collection'),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(tr('ui.music.014')),
              onTap: () => Navigator.pop(ctx, 'link'),
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(tr('ui.video.020')),
              onTap: () => Navigator.pop(ctx, 'path'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.timeline),
              title: Text(tr('ui.video.017')),
              onTap: () => Navigator.pop(ctx, 'progress'),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: Text(tr('video.action.scrapeForce')),
              onTap: () => Navigator.pop(ctx, 'scrapeForce'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'transcode':
        await _openTranscode();
      case 'collection':
        if (!mounted) return;
        await showAddToCollectionDialog(this.context, itemIds: [item.id]);
      case 'link':
        await _copyPlayUrl();
      case 'path':
        _copyPath();
      case 'progress':
        if (!mounted) return;
        await showDialog<void>(
          context: this.context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('ui.video.017')),
            content: _progressRow(ctx),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('common.close')),
              ),
            ],
          ),
        );
      case 'scrapeForce':
        await _scrape(force: true);
    }
  }

  // ---------------------------------------------------------------- 进度

  Widget _progressRow(BuildContext context) {
    return Row(
      children: [
        Text(
          tr('ui.video.017'),
          style: const TextStyle(fontSize: NasTokens.fontCaption),
        ),
        Expanded(
          child: Slider(
            value: _percent.clamp(0, 100),
            max: 100,
            divisions: 20,
            label: '${_percent.round()}%',
            onChanged: (v) => setState(() => _percent = v),
          ),
        ),
        Text(
          '${_percent.round()}%',
          style: const TextStyle(fontSize: NasTokens.fontCaption),
        ),
        TextButton(onPressed: _saveProgress, child: Text(tr('common.save'))),
      ],
    );
  }

  /// 单集右键动作：走的还是影片列表那一套，做完就地刷新这一集和选集列表。
  Future<void> _episodeAction(String action, VideoItem ep) async {
    final changed = await runVideoItemAction(context, action, ep);
    if (!mounted) return;
    // 删掉的正是当前正在看的那一集：退回上一级，不要停在一个已经不存在的条目上
    if (action == VideoItemAction.delete && ep.id == _item.id) {
      Navigator.of(context).maybePop();
      return;
    }
    // 删掉的是当前选中的那一集：选中态要拨回本页这一条，
    // 否则文件信息面板会指着一个已经不存在的文件
    if (action == VideoItemAction.delete && _selectedId == ep.id) {
      _selectedId = null;
    }
    if (!changed) return;
    await _loadEpisodes();
    await _loadProgress();
  }

  /// 点集数直接开播（用户 2026-11-11 19:24 要求：不要「先选中再点一次」）。
  ///
  /// 播之前先把选中态拨到这一集：从播放器回来时，选集高亮和下方「文件与技术
  /// 信息」都停在刚看过的那一集，而不是页头那条。
  Future<void> _playEpisode(VideoItem ep) async {
    if (_selectedId != ep.id) setState(() => _selectedId = ep.id);
    if (VideoLibraryTypes.isShortTv(ep.libraryId) &&
        _seriesEpisodes.length > 1) {
      final idx = _seriesEpisodes.indexWhere((e) => e.id == ep.id);
      await openShortPlay(context, _seriesEpisodes, idx < 0 ? 0 : idx);
      if (mounted) await _loadEpisodes();
      return;
    }
    await playVideoItemNow(context, ep);
    if (mounted) {
      await _loadEpisodes();
      await _loadProgress();
    }
  }

  /// 演职人员点击：日本库进日本演员页（有身高 / 三围 / 档案），
  /// 普通库进「某人的作品」列表。
  void _openPerson(VideoPerson person) {
    if (VideoDetailRouter.instance.isJpLibrary(_item.libraryId)) {
      openVideoJpActor(context, name: person.name, libraryId: _item.libraryId);
      return;
    }
    openVideoListByPerson(
      context,
      kind: person.isDirector ? 'director' : 'actor',
      name: person.name,
    );
  }
}

/// 打开影视详情的统一入口。
///
/// 影视壳挂载、且调用方还在内容区时，一律叠成三级页（**所有尺寸**），
/// 左侧一二级栏保持不动；只有壳没挂载、或调用方本身已是整页路由，
/// 才退回整页 push。用户 2026-11-11 澄清：「全屏」指内容铺满三级页，
/// 不是把整个窗口盖掉。
Future<void> openVideoDetail(BuildContext context, VideoItem item) {
  final router = VideoDetailRouter.instance;
  if (router.embeddableFrom(context)) {
    router.open(
      VideoDetailEntry(
        tag: 'video:${item.id}',
        build: (_) => VideoDetailPage(
          item: item,
          posterUrl: videoPosterUrl(item),
          headers: videoArtHeaders,
          embedded: true,
        ),
      ),
    );
    return Future<void>.value();
  }
  return _pushVideoDetail(Navigator.of(context), item);
}

/// 同上，但直接收 [NavigatorState]：在 `await` 之后调用时，
/// 先取好 navigator 再 await，就不会触发 `use_build_context_synchronously`。
///
/// 这里只有 navigator、拿不到调用方所在的 route，所以按「影视壳是否挂载」
/// 判定；调用点都在壳的内容区（列表 / 查重 / 详情页切集），不会误叠。
Future<void> openVideoDetailOn(NavigatorState navigator, VideoItem item) {
  final router = VideoDetailRouter.instance;
  if (router.attached) {
    router.open(
      VideoDetailEntry(
        tag: 'video:${item.id}',
        build: (_) => VideoDetailPage(
          item: item,
          posterUrl: videoPosterUrl(item),
          headers: videoArtHeaders,
          embedded: true,
        ),
      ),
    );
    return Future<void>.value();
  }
  return _pushVideoDetail(navigator, item);
}

Future<void> _pushVideoDetail(NavigatorState navigator, VideoItem item) {
  return navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => VideoDetailPage(
        item: item,
        posterUrl: videoPosterUrl(item),
        headers: videoArtHeaders,
      ),
    ),
  );
}
