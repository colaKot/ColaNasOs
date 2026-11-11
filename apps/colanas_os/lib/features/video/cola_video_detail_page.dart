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
import 'video_jp_pages.dart';
import 'video_list_view.dart';
import 'video_scrape_dialogs.dart';
import 'video_item_actions.dart';
import 'series_display.dart';
import 'video_series_widgets.dart';
import 'short_play_page.dart';
import 'library_types.dart';
import 'detail/video_detail_router.dart';

/// 演职人员名清洗。
///
/// NFO / 刮削偶尔把「名字 头像地址 TMDB-id」拼成一整串塞进 actors / directors
/// （实测《超人》的导演就是这样），直接展示会把整条 URL 打到页面上，
/// 拿去当演员筛选条件也永远匹配不到。这里只剥掉地址与纯数字 id，**不动名字里的空格**
/// （`Grace Chan` / `Ryan J. Pezdirc` 这种必须原样保留）。
String videoPersonName(String raw) {
  var s = raw.trim();
  s = s.replaceAll(RegExp(r'\s*https?://\S+'), '');
  s = s.replaceAll(RegExp(r'\s+\d{3,}$'), '');
  return s.trim();
}

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

  /// 剧情简介是否展开（默认 4 行）
  bool _overviewExpanded = false;

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

  Future<void> _openPlayer() async {
    // 短剧：进上下切换的连播页，而不是单集播放器
    if (VideoLibraryTypes.isShortTv(_item.libraryId) &&
        _seriesEpisodes.length > 1) {
      final idx = _seriesEpisodes.indexWhere((e) => e.id == _item.id);
      await openShortPlay(context, _seriesEpisodes, idx < 0 ? 0 : idx);
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(id: _item.id);
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            url: url,
            title: _item.title,
            itemId: _item.id,
            // 兼容判定（DV / HDR / HEVC / EAC3）交给播放器决定要不要自动转码
            compat: res.compat,
            // 档位菜单按片源分辨率收敛，别列出这部片转不出来的档
            sourceHeight: _item.height,
            // 媒体信息面板要显示「源码率 → 目标码率」，源码率 = size ÷ 时长
            sourceBytes: _item.size,
            // 转码是边转边播，播放器拿不到总长，用片源时长兜进度条
            durationMs: _item.durationMs,
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
    final screen = MediaQuery.of(context).size;
    final hPad = screen.width < 600
        ? 16.0
        : (screen.width < 1000 ? 32.0 : 48.0);
    final wide = screen.width >= 820;
    final hasEpisodes = _seriesEpisodes.length > 1;

    return Scaffold(
      // 背景是模糊封面，内容从顶上压下来；AppBar 只留返回与菜单
      extendBodyBehindAppBar: !widget.embedded,
      // 嵌入模式不画 AppBar：顶栏由外壳提供，操作改挂右上角浮层
      appBar: widget.embedded
          ? null
          : AppBar(
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
                      colors: [
                        Colors.black.withValues(alpha: 0.5),
                        Colors.transparent,
                      ],
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
      body: Stack(
        children: [
          Positioned.fill(child: _backdrop(context, item)),
          RefreshIndicator(
            onRefresh: _refreshItem,
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                hPad,
                // 嵌入模式没有自己的 AppBar，不用再为它留一条高度
                widget.embedded
                    ? NasTokens.spaceSm
                    : MediaQuery.of(context).padding.top +
                          kToolbarHeight +
                          NasTokens.spaceSm,
                hPad,
                NasTokens.spaceXl,
              ),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                _headSection(context, item, wide),
                if ((item.overview ?? '').isNotEmpty) ...[
                  const SizedBox(height: NasTokens.spaceMd),
                  _overviewBlock(context, item),
                ],
                if (hasEpisodes) ...[
                  const SizedBox(height: NasTokens.spaceLg),
                  _episodeSection(context, item),
                ],
                const SizedBox(height: NasTokens.spaceLg),
                _peopleSection(context),
                const SizedBox(height: NasTokens.spaceLg),
                _fileInfoSection(context, item),
                const SizedBox(height: NasTokens.spaceLg),
                _mediaInfoSection(context, item),
                const SizedBox(height: NasTokens.spaceLg),
                Text(
                  tr('ui.video.h390648'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (widget.embedded)
            Positioned(top: 8, right: 8, child: _floatingActions(context)),
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

  /// 顶部信息区：**左侧竖版封面 + 右侧标题/元信息/按钮**（照用户给的截图）。
  ///
  /// 电影和电视剧用同一套头（电影以前没有封面，这次补上）。
  Widget _headSection(BuildContext context, VideoItem item, bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final posterW = wide ? 190.0 : 116.0;
    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      child: SizedBox(
        width: posterW,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: NasCoverImage(
            url: videoPosterUrl(item, size: (posterW * 2).round()),
            headers: videoArtHeaders,
            fallbackText: item.title,
            icon: Icons.movie_outlined,
          ),
        ),
      ),
    );

    final meta = <String>[
      if ((item.year ?? 0) > 0) '${item.year}',
      ...item.genres.take(3),
      if (item.regions.isNotEmpty) item.regions.first,
      if ((item.runtimeMin ?? 0) > 0)
        tr('video.detail.minutes', {'count': '${item.runtimeMin}'}),
    ];
    final flags = videoFlagsOf(item);
    final score = item.score ?? 0;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 嵌入模式的右上角有一枚浮层胶囊（刮削 + 更多），它压在内容层之上。
        // 标题行右侧必须让出这段宽度，否则长片名会被胶囊盖住。
        // 评分也**不再放标题行右端**：那个位置正好是胶囊的地盘，
        // 之前 6.5 和 ⋮ 叠在一起就是这么来的（2026-11-11 用户截图）。
        Padding(
          padding: EdgeInsets.only(right: widget.embedded ? 104 : 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _displayTitle(item),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: wide ? 26 : 20,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        if ((item.originalName ?? '').isNotEmpty &&
            item.originalName != item.title) ...[
          const SizedBox(height: 3),
          Text(
            item.originalName!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
        if (meta.isNotEmpty || score > 0) ...[
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (score > 0) ...[
                Text(
                  '★ ${score.toStringAsFixed(1)}',
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
                if (meta.isNotEmpty)
                  Text(
                    ' · ',
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
              ],
              for (var i = 0; i < meta.length; i++) ...[
                if (i > 0)
                  Text(
                    ' · ',
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                Text(
                  meta[i],
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ],
          ),
        ],
        if (flags.isNotEmpty ||
            (item.code != null && item.code!.isNotEmpty)) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (item.code != null && item.code!.isNotEmpty)
                _heroBadge(context, item.code!),
              for (final f in flags) _heroBadge(context, f),
            ],
          ),
        ],
        const SizedBox(height: 14),
        _actionRow(context, item),
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        poster,
        SizedBox(width: wide ? 22 : 14),
        Expanded(child: info),
      ],
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
    final hasProgress = _percent > 0 && _percent < 100;
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
                    : tr('video.series.play'),
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
              icon: item.watched ? Icons.check_circle : Icons.check_circle_outline,
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

  Widget _overviewBlock(BuildContext context, VideoItem item) {
    final text = item.overview ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, tr('video.detail.overview')),
        const SizedBox(height: NasTokens.spaceXs),
        GestureDetector(
          onTap: () => setState(() => _overviewExpanded = !_overviewExpanded),
          child: Text(
            text,
            maxLines: _overviewExpanded ? null : 4,
            overflow: _overviewExpanded
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
            style: const TextStyle(height: 1.6),
          ),
        ),
      ],
    );
  }

  Widget _heroBadge(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface.withValues(alpha: 0.86),
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: NasTokens.fontSubtitle,
        fontWeight: FontWeight.w600,
      ),
    );
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

  // ---------------------------------------------------------------- 演职人员

  /// 演职人员：**圆形头像**横排（照用户给的截图），名字 + 身高/角色两行。
  ///
  /// 头像是 NFO 里的 `<actor><thumb>`；拿不到就显示名字首字，不留空白。
  Widget _peopleSection(BuildContext context) {
    final people = <(String, String, String)>[
      for (final name in _item.directors)
        (videoPersonName(name), 'director', tr('video.detail.director')),
      for (final name in _item.actors)
        (videoPersonName(name), 'actor', tr('video.detail.actor')),
    ].where((p) => p.$1.isNotEmpty).toList();
    if (people.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, tr('video.detail.people')),
        const SizedBox(height: 10),
        SizedBox(
          height: 132,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: people.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (ctx, i) {
              final (name, kind, role) = people[i];
              final info = _actorInfo[name];
              final avatar = '${info?['avatarUrl'] ?? ''}';
              final height = (info?['heightCm'] as num?)?.toInt() ?? 0;
              final birthday = '${info?['birthday'] ?? ''}';
              final sub = height > 0
                  ? '$height cm${birthday.isEmpty ? '' : ' · $birthday'}'
                  : role;

              return InkWell(
                borderRadius: BorderRadius.circular(40),
                // 日本库：演员页有身高 / 三围 / 生日，必须进日本演员页；
                // 普通库走「某人的作品」。
                onTap: () {
                  if (VideoDetailRouter.instance.isJpLibrary(_item.libraryId)) {
                    openVideoJpActor(
                      context,
                      name: name,
                      libraryId: _item.libraryId,
                    );
                  } else {
                    openVideoListByPerson(context, kind: kind, name: name);
                  }
                },
                child: SizedBox(
                  width: 76,
                  child: Column(
                    children: [
                      ClipOval(
                        child: SizedBox(
                          width: 64,
                          height: 64,
                          // 不要 fallbackText：没头像时它会把这个名字按 64×64 画成
                          // 一个个巨字（还被裁掉），远不如一个人形图标干净。
                          child: NasCoverImage(
                            url: avatar.isEmpty ? null : avatar,
                            icon: Icons.person_outline,
                            cacheWidth: 128,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: NasTokens.fontMicro,
                          color: height > 0
                              ? scheme.primary
                              : context.nasTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 选集

  /// 选集：数字网格（照截图：浅底小方块，当前集高亮，看过的用主色描边）。
  Widget _episodeSection(BuildContext context, VideoItem item) {
    final scheme = Theme.of(context).colorScheme;
    final eps = [..._seriesEpisodes]
      ..sort((a, b) {
        final sa = a.season ?? 0;
        final sb = b.season ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        return (a.episode ?? 0).compareTo(b.episode ?? 0);
      });
    if (eps.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionTitle(context, tr('video.detail.episodes')),
            const SizedBox(width: 8),
            Text(
              '${eps.length}',
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < eps.length; i++)
              _episodeButton(
                context,
                eps[i],
                i + 1,
                eps[i].id == item.id,
                scheme,
              ),
          ],
        ),
      ],
    );
  }

  Widget _episodeButton(
    BuildContext context,
    VideoItem ep,
    int index,
    bool current,
    ColorScheme scheme,
  ) {
    return Tooltip(
      message: ep.title,
      // 单集右键：菜单与影片列表同一套（一集就是一个 VideoItem）
      child: NasContextMenuRegion(
        entries: videoItemMenuEntries(
          ep,
          onAction: (action) => _episodeAction(action, ep),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          // 点具体剧集立刻起播；短剧走上下切换的连播页
          onTap: () {
            if (VideoLibraryTypes.isShortTv(_item.libraryId) &&
                _seriesEpisodes.length > 1) {
              final idx = _seriesEpisodes.indexWhere((e) => e.id == ep.id);
              openShortPlay(context, _seriesEpisodes, idx < 0 ? 0 : idx);
              return;
            }
            playVideoItemNow(context, ep);
          },
          child: Container(
            width: 52,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: current
                  ? scheme.primary
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(8),
              border: !current && ep.watched
                  ? Border.all(color: scheme.primary.withValues(alpha: 0.45))
                  : null,
            ),
            child: Text(
              '$index',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: current
                    ? scheme.onPrimary
                    : (ep.watched ? scheme.primary : scheme.onSurface),
              ),
            ),
          ),
        ),
      ),
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
    if (!changed) return;
    await _loadEpisodes();
    await _loadProgress();
  }

  // ---------------------------------------------------------------- 文件 / 轨道

  /// 文件信息：卡片里「标签在上、值在下」的网格（照截图）。
  Widget _fileInfoSection(BuildContext context, VideoItem item) {
    final scheme = Theme.of(context).colorScheme;
    final unknown = tr('ui.book.hd9c32a');

    Widget cell(String label, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: NasTokens.fontMicro,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: 3),
        SelectableText(
          value,
          style: const TextStyle(fontSize: NasTokens.fontCaption, height: 1.35),
        ),
      ],
    );

    final resolution = item.width == null || item.height == null
        ? unknown
        : '${item.width}×${item.height}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, tr('video.detail.file')),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cell(tr('video.detail.fileLocation'), item.path),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: cell(
                      tr('video.detail.fileSize'),
                      formatBytes(item.size),
                    ),
                  ),
                  Expanded(
                    child: cell(tr('video.detail.trackVideo'), resolution),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: cell(
                      tr('video.detail.movie'),
                      [
                        if ((item.year ?? 0) > 0) '${item.year}',
                        if (item.genres.isNotEmpty) item.genres.first,
                      ].join(' · '),
                    ),
                  ),
                  Expanded(
                    child: cell(
                      tr('video.detail.source'),
                      (item.nfoSource ?? 'none').toString(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 视频 / 音频 / 字幕三列参数（照截图的三段式）。
  Widget _mediaInfoSection(BuildContext context, VideoItem item) {
    final scheme = Theme.of(context).colorScheme;
    final mbps = (item.size > 0 && (item.durationMs ?? 0) > 0)
        ? (item.size * 8) / (item.durationMs! / 1000) / 1000000
        : 0;

    Widget column(IconData icon, String title, List<String> lines) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: context.nasTextSecondary),
                const SizedBox(width: 5),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: NasTokens.fontMicro,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontCaption,
                    height: 1.3,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    final res = item.height == null
        ? '—'
        : ((item.height ?? 0) >= 2160
              ? '4K'
              : ((item.height ?? 0) >= 1080 ? '1080P' : '720P'));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          column(Icons.movie_outlined, tr('video.detail.trackVideo'), [
            res,
            if ((item.videoCodec ?? '').isNotEmpty)
              item.videoCodec!.toUpperCase(),
            if (mbps > 0) '${mbps.toStringAsFixed(2)} Mbps',
          ]),
          column(Icons.audiotrack_outlined, tr('video.detail.trackAudio'), [
            if ((item.audioCodec ?? '').isNotEmpty)
              item.audioCodec!.toUpperCase(),
            if (item.container.isNotEmpty) item.container.toUpperCase(),
          ]),
          column(Icons.subtitles_outlined, tr('video.detail.trackSubtitle'), [
            item.hasSubtitle ? tr('ui.video.hbe1c0c') : tr('ui.video.h720777'),
          ]),
        ],
      ),
    );
  }
}

/// 打开影视详情的统一入口。
///
/// 影视壳挂载时走**三级页**（内容区叠层，左侧一二级栏保留、返回走外壳）；
/// 壳不在时（桌面卡片 / 独立窗口）或调用方本身在整页路由里时，退回整页 push。
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
  return openVideoDetailOn(Navigator.of(context), item);
}

/// 同上，但直接收 [NavigatorState]：在 `await` 之后调用时，
/// 先取好 navigator 再 await，就不会触发 `use_build_context_synchronously`。
///
/// 拿不到 context 就无法判断调用方是不是在整页路由里，所以**只在内容区调用**；
/// 页面自己知道自己在哪（详情页切集、列表页点卡片），不需要再猜。
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
