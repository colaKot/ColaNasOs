import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/play_preferences.dart';
import '../../core/play_quality.dart';
import '../../core/session.dart';
import 'player_page.dart';
import 'video_card.dart';
import 'video_collection_picker.dart';
import 'video_list_view.dart';
import 'video_scrape_dialogs.dart';

/// 影片详情。
///
/// 结构照参考实现的分区：**顶部信息（海报 + 片名 + 年份/片长/评分/类型/地区）
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
  });

  final VideoItem item;

  /// 兼容旧调用点；内部一律按 item 自己算海报地址（刮削海报优先）
  final String posterUrl;
  final Map<String, String> headers;

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

  @override
  void initState() {
    super.initState();
    _loadProgress();
    _loadEpisodes();
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
      final res = await ApiSession.instance.client.videoSeriesItems(name: series);
      if (!mounted) return;
      setState(() => _seriesEpisodes = res.items);
    } catch (_) {
      // 剧集读取失败不影响详情
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(id: _item.id);
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(url: url, title: _item.title, itemId: _item.id),
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
      _toast(tr('video.copyUrl', {'minutes': '${res.expiresInSec ~/ 60}'}));
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

    var preset = PlayPreferences.preset;
    var codec = PlayPreferences.codec;
    String? subtitle;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('video.transcode.title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: preset,
                decoration: InputDecoration(labelText: tr('video.transcode.preset')),
                items: [
                  for (final p in playQualityPresets)
                    DropdownMenuItem(value: p.key, child: Text('${p.label} · ${p.bitrateLabel}')),
                ],
                onChanged: (v) => setLocal(() => preset = v ?? preset),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              DropdownButtonFormField<String>(
                initialValue: codec,
                decoration: InputDecoration(labelText: tr('video.transcode.codec')),
                items: [
                  for (final c in playCodecs)
                    DropdownMenuItem(value: c.key, child: Text(c.label)),
                ],
                onChanged: (v) => setLocal(() => codec = v ?? codec),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              DropdownButtonFormField<String?>(
                initialValue: subtitle,
                decoration: InputDecoration(labelText: tr('video.transcode.subtitle')),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text(tr('video.transcode.none'))),
                  for (final s in subtitles)
                    DropdownMenuItem<String?>(
                      value: s.name,
                      child: Text(s.lang == null ? s.name : '${s.name}（${s.lang}）'),
                    ),
                ],
                onChanged: (v) => setLocal(() => subtitle = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('video.transcode.start'))),
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
        ),
      );
      var job = await ApiSession.instance.client.playerSessionGet(id: created.id);
      for (var i = 0; i < 180 && (job.status == 'pending' || job.status == 'running'); i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        job = await ApiSession.instance.client.playerSessionGet(id: created.id);
      }
      if (job.status != 'done') {
        _toast(tr('video.transcodeIncomplete', {'status': job.status, 'error': job.error ?? ''}));
        return;
      }
      if (!mounted) return;
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            url: '${ApiSession.instance.baseUrl}${job.url}',
            title: _item.title,
            itemId: _item.id,
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.ok'))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ApiSession.instance.client.videoScrapeCleanup(body: VideoScrapeCleanupBody(id: _item.id));
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
    return Scaffold(
      appBar: AppBar(
        title: Text(item.title, overflow: TextOverflow.ellipsis),
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
              PopupMenuItem(value: 'force', child: Text(tr('video.action.scrapeForce'))),
              PopupMenuItem(value: 'match', child: Text(tr('video.action.matchTmdb'))),
              PopupMenuItem(value: 'cleanup', child: Text(tr('video.action.scrapeCleanup'))),
              PopupMenuItem(value: 'exclude', child: Text(tr('video.action.excludeScrape'))),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'copyPath', child: Text(tr('video.action.copyPath'))),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshItem,
        child: ListView(
          padding: const EdgeInsets.all(NasTokens.spaceMd),
          children: [
            _header(context, item),
            const SizedBox(height: NasTokens.spaceMd),
            _actions(context, item),
            const SizedBox(height: NasTokens.spaceSm),
            _progressRow(context),
            if ((item.overview ?? '').isNotEmpty) ...[
              const SizedBox(height: NasTokens.spaceMd),
              _sectionTitle(context, tr('video.detail.overview')),
              const SizedBox(height: NasTokens.spaceXs),
              Text(item.overview!, style: const TextStyle(height: 1.5)),
            ],
            if (item.directors.isNotEmpty || item.actors.isNotEmpty) ...[
              const SizedBox(height: NasTokens.spaceMd),
              _sectionTitle(context, tr('video.detail.people')),
              const SizedBox(height: NasTokens.spaceXs),
              if (item.directors.isNotEmpty)
                _peopleRow(context, tr('video.detail.director'), item.directors, 'director'),
              if (item.actors.isNotEmpty)
                _peopleRow(context, tr('video.detail.actor'), item.actors, 'actor'),
            ],
            if (_seriesEpisodes.length > 1) ...[
              const SizedBox(height: NasTokens.spaceMd),
              _sectionTitle(context, tr('video.nav.series')),
              const SizedBox(height: NasTokens.spaceXs),
              _episodeList(context, item),
            ],
            const SizedBox(height: NasTokens.spaceMd),
            _sectionTitle(context, tr('video.detail.info')),
            const SizedBox(height: NasTokens.spaceXs),
            _infoTable(context, item),
            const SizedBox(height: NasTokens.spaceMd),
            Text(
              tr('ui.video.h390648'),
              style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
            ),
            const SizedBox(height: NasTokens.spaceLg),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 顶部

  Widget _header(BuildContext context, VideoItem item) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.of(context).size.width >= 720;
    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      child: SizedBox(
        width: wide ? 200 : 130,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: NasCoverImage(
            url: videoPosterUrl(item),
            headers: videoArtHeaders,
            fallbackText: item.title,
            icon: Icons.movie_outlined,
          ),
        ),
      ),
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title,
          style: const TextStyle(fontSize: NasTokens.fontTitle, fontWeight: FontWeight.w700),
        ),
        if ((item.originalName ?? '').isNotEmpty && item.originalName != item.title) ...[
          const SizedBox(height: 2),
          Text(
            item.originalName!,
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
        ],
        const SizedBox(height: NasTokens.spaceSm),
        Wrap(
          spacing: NasTokens.spaceXs,
          runSpacing: NasTokens.spaceXs,
          children: [
            if ((item.year ?? 0) > 0) _chip(context, '${item.year}'),
            if ((item.runtimeMin ?? 0) > 0)
              _chip(context, tr('video.detail.minutes', {'count': '${item.runtimeMin}'})),
            if ((item.score ?? 0) > 0)
              _chip(context, '★ ${(item.score ?? 0).toStringAsFixed(1)}', highlight: true),
            for (final g in item.genres.take(3)) _chip(context, g),
            for (final r in item.regions.take(2)) _chip(context, r),
            if (item.is4k) _chip(context, '4K', highlight: true),
            if (item.dolbyVision) _chip(context, 'Dolby Vision', highlight: true),
            if (item.dolbyAtmos) _chip(context, 'Atmos', highlight: true),
            if (item.code != null && item.code!.isNotEmpty) _chip(context, item.code!),
          ],
        ),
        if (item.nfoSource == null || item.nfoSource == 'none') ...[
          const SizedBox(height: NasTokens.spaceSm),
          InkWell(
            onTap: _busy ? null : () => _scrape(),
            borderRadius: BorderRadius.circular(NasTokens.radiusSm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    tr('video.detail.notScrapedHint'),
                    style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );

    if (!wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          poster,
          const SizedBox(width: NasTokens.spaceMd),
          Expanded(child: info),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        poster,
        const SizedBox(width: NasTokens.spaceLg),
        Expanded(child: info),
      ],
    );
  }

  Widget _chip(BuildContext context, String text, {bool highlight = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.primary.withValues(alpha: 0.14)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: NasTokens.fontMicro,
          color: highlight ? scheme.primary : scheme.onSurface,
          fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: NasTokens.fontSubtitle, fontWeight: FontWeight.w600),
    );
  }

  // ---------------------------------------------------------------- 操作

  Widget _actions(BuildContext context, VideoItem item) {
    return Wrap(
      spacing: NasTokens.spaceSm,
      runSpacing: NasTokens.spaceSm,
      children: [
        FilledButton.icon(
          onPressed: _busy ? null : _openPlayer,
          icon: const Icon(Icons.play_arrow),
          label: Text(tr('ui.video.018')),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _openTranscode,
          icon: const Icon(Icons.high_quality_outlined, size: 18),
          label: Text(tr('ui.video.019')),
        ),
        OutlinedButton.icon(
          onPressed: _toggleFavorite,
          icon: Icon(_favorite ? Icons.favorite : Icons.favorite_border, size: 18),
          label: Text(_favorite ? tr('video.action.unfavorite') : tr('video.action.favorite')),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _toggleWatched,
          icon: Icon(item.watched ? Icons.remove_done : Icons.done_all, size: 18),
          label: Text(
            item.watched
                ? tr('video.action.markUnwatched')
                : (item.series != null
                    ? tr('video.action.markTvWatched')
                    : tr('video.action.markWatched')),
          ),
        ),
        OutlinedButton.icon(
          onPressed: () => showAddToCollectionDialog(context, itemIds: [item.id]),
          icon: const Icon(Icons.playlist_add, size: 18),
          label: Text(tr('video.collection.addTo')),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _copyPlayUrl,
          icon: const Icon(Icons.link, size: 18),
          label: Text(tr('ui.music.014')),
        ),
        OutlinedButton.icon(
          onPressed: _copyPath,
          icon: const Icon(Icons.copy, size: 18),
          label: Text(tr('ui.video.020')),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _scrape(force: true),
          icon: const Icon(Icons.auto_awesome_outlined, size: 18),
          label: Text(tr('video.action.scrapeForce')),
        ),
      ],
    );
  }

  Widget _progressRow(BuildContext context) {
    return Row(
      children: [
        Text(tr('ui.video.017'), style: const TextStyle(fontSize: NasTokens.fontCaption)),
        Expanded(
          child: Slider(
            value: _percent.clamp(0, 100),
            max: 100,
            divisions: 20,
            label: '${_percent.round()}%',
            onChanged: (v) => setState(() => _percent = v),
          ),
        ),
        Text('${_percent.round()}%', style: const TextStyle(fontSize: NasTokens.fontCaption)),
        TextButton(onPressed: _saveProgress, child: Text(tr('common.save'))),
      ],
    );
  }

  Widget _peopleRow(BuildContext context, String label, List<String> names, String kind) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Text(
              label,
              style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: NasTokens.spaceXs,
              runSpacing: NasTokens.spaceXs,
              children: [
                for (final name in names.take(20))
                  ActionChip(
                    label: Text(name, style: const TextStyle(fontSize: NasTokens.fontMicro)),
                    onPressed: () => openVideoListByPerson(context, kind: kind, name: name),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeList(BuildContext context, VideoItem item) {
    final eps = [..._seriesEpisodes]..sort((a, b) {
        final sa = a.season ?? 0;
        final sb = b.season ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        return (a.episode ?? 0).compareTo(b.episode ?? 0);
      });
    return Column(
      children: [
        for (final ep in eps.take(30))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              ep.watched ? Icons.check_circle : Icons.play_circle_outline,
              size: 20,
              color: ep.id == item.id
                  ? Theme.of(context).colorScheme.primary
                  : context.nasTextSecondary,
            ),
            title: Text(
              'S${ep.season ?? 1}E${ep.episode ?? 0}',
              style: const TextStyle(fontSize: NasTokens.fontCaption),
            ),
            subtitle: Text(ep.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: ep.id == item.id ? Text(tr('video.jp.inLibrary')) : null,
            onTap: ep.id == item.id
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => VideoDetailPage(
                          item: ep,
                          posterUrl: videoPosterUrl(ep),
                          headers: widget.headers,
                        ),
                      ),
                    ),
          ),
      ],
    );
  }

  Widget _infoTable(BuildContext context, VideoItem item) {
    final unknown = tr('ui.book.hd9c32a');
    final rows = <(String, String)>[
      (tr('video.detail.year'), (item.year ?? 0) > 0 ? '${item.year}' : unknown),
      (tr('video.detail.score'), (item.score ?? 0) > 0 ? (item.score ?? 0).toStringAsFixed(1) : unknown),
      (
        tr('video.detail.runtime'),
        (item.runtimeMin ?? 0) > 0 ? tr('video.detail.minutes', {'count': '${item.runtimeMin}'}) : unknown,
      ),
      (tr('video.detail.region'), item.regions.isEmpty ? unknown : item.regions.join(' / ')),
      (tr('video.detail.genre'), item.genres.isEmpty ? unknown : item.genres.join(' / ')),
      (tr('video.detail.studio'), (item.studio ?? '').isEmpty ? unknown : item.studio!),
      (tr('video.detail.releaseDate'), (item.releaseDate ?? '').isEmpty ? unknown : item.releaseDate!),
      (tr('video.detail.source'), (item.nfoSource ?? 'none').toString()),
      (
        tr('ui.music.h29d055'),
        item.durationMs == null ? unknown : formatDurationMs(item.durationMs!),
      ),
      (
        tr('ui.video.hcde9b5'),
        item.width == null || item.height == null ? unknown : '${item.width}×${item.height}',
      ),
      (tr('ui.video.he348df'), item.videoCodec ?? unknown),
      (tr('ui.video.h1137ee'), item.audioCodec ?? unknown),
      (tr('ui.video.hd179a3'), item.container.isEmpty ? unknown : item.container),
      (tr('ui.video.haaa5f2'), item.hasSubtitle ? tr('ui.video.hbe1c0c') : tr('ui.video.h720777')),
      (tr('files.size'), formatBytes(item.size)),
      (tr('ui.book.025'), item.path),
    ];
    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceXs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  child: Text(
                    label,
                    style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                  ),
                ),
                Expanded(child: SelectableText(value)),
              ],
            ),
          ),
      ],
    );
  }
}
