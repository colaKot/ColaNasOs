import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 影视详情整页（D4）：大图 + 基本信息 + 季集 + 简介/演员 + PT 操作。
///
/// 收藏 / 下载状态目前没有服务端字段，所以这里**不放**收藏与下载按钮；
/// 「复制 TMDB 链接」是纯客户端动作，离线也能用。
class DiscoverDetailPage extends StatefulWidget {
  const DiscoverDetailPage({
    super.key,
    required this.id,
    required this.mediaType,
  });

  final int id;
  final String mediaType;

  @override
  State<DiscoverDetailPage> createState() => _DiscoverDetailPageState();
}

class _DiscoverDetailPageState extends State<DiscoverDetailPage> {
  DiscoverDetailResponse? _detail;
  bool _loading = true;
  String? _error;

  String _imageUrl(String path, String size) =>
      '${ApiSession.instance.baseUrl}/api/v1/discover/image?path=${Uri.encodeComponent(path)}&size=$size';

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
      final d = await ApiSession.instance.client.discoverDetail(
        id: widget.id,
        media: widget.mediaType,
      );
      if (!mounted) return;
      setState(() {
        _detail = d;
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

  Future<void> _subscribePt() async {
    final d = _detail;
    if (d == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.ptSubscriptionUpsert(
        body: <String, dynamic>{
          'mediaTitle': d.title,
          if (d.year != null) 'mediaYear': '${d.year}',
          'enabled': true,
        },
      );
      messenger.showSnackBar(
        SnackBar(content: Text(tr('discover.pt.subscribed'))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _searchPt() async {
    final d = _detail;
    if (d == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.ptSearch(
        body: <String, dynamic>{
          'title': d.title,
          if (d.originalTitle.isNotEmpty) 'originalTitle': d.originalTitle,
          if (d.year != null) 'year': '${d.year}',
        },
      );
      if (!mounted) return;
      final items = ((res['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('discover.pt.results')),
          content: SizedBox(
            width: 640,
            height: 420,
            child: items.isEmpty
                ? Center(child: Text(tr('discover.ptEmpty')))
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (c, i) {
                      final r = items[i];
                      final size = (r['sizeBytes'] as num?)?.toInt() ?? 0;
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.arrow_downward, size: 18),
                        title: Text(
                          '${r['title'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${formatBytes(size)} · S${r['seeders'] ?? 0} · ${r['siteName'] ?? ''}',
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.close')),
            ),
          ],
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _copyLink() async {
    final d = _detail;
    if (d == null) return;
    final url = 'https://www.themoviedb.org/${d.mediaType}/${d.id}';
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('discover.detail.linkCopied'))),
    );
  }

  Widget _metaLine(DiscoverDetailResponse d, Color secondary) {
    return Text(
      [
        if (d.year != null) '${d.year}',
        if (d.runtime != null)
          tr('discover.runtime', {'minutes': '${d.runtime}'}),
        if (d.rating != null) '★ ${d.rating!.toStringAsFixed(1)}',
      ].join(' · '),
      style: TextStyle(fontSize: NasTokens.fontCaption, color: secondary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    if (_loading) {
      return Scaffold(appBar: AppBar(), body: const NasLoading());
    }
    if (_error != null || d == null) {
      return Scaffold(
        appBar: AppBar(),
        body: NasErrorState(message: _error ?? '', onRetry: _load),
      );
    }
    final secondary = context.nasTextSecondary;
    final backdrop = d.backdropPath;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 240,
            pinned: true,
            title: Text(
              d.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: backdrop == null
                  ? Container(color: Theme.of(context).colorScheme.surfaceContainerHighest)
                  : Image.network(
                      _imageUrl(backdrop, 'w780'),
                      headers: ApiSession.instance.authHeaders,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(NasTokens.spaceLg),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (d.posterPath != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(NasTokens.radiusMd),
                        child: Image.network(
                          _imageUrl(d.posterPath!, 'w342'),
                          headers: ApiSession.instance.authHeaders,
                          width: 132,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const SizedBox(width: 132, height: 198),
                        ),
                      ),
                    const SizedBox(width: NasTokens.spaceMd),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (d.originalTitle.isNotEmpty)
                            Text(
                              d.originalTitle,
                              style: TextStyle(
                                color: secondary,
                                fontSize: NasTokens.fontCaption,
                              ),
                            ),
                          const SizedBox(height: NasTokens.spaceXs),
                          _metaLine(d, secondary),
                          const SizedBox(height: NasTokens.spaceSm),
                          Wrap(
                            spacing: NasTokens.spaceXs,
                            runSpacing: NasTokens.spaceXs,
                            children: [
                              for (final g in d.genres)
                                Chip(label: Text(g), visualDensity: VisualDensity.compact),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: NasTokens.spaceLg),
                if (d.degraded)
                  Text(
                    tr('discover.detailUnavailable', {'reason': d.reason}),
                    style: TextStyle(color: context.nasDanger, fontSize: NasTokens.fontCaption),
                  )
                else ...[
                  Text(tr('ui.discover.003'), style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: NasTokens.spaceXs),
                  Text(d.overview.isEmpty ? tr('ui.discover.004') : d.overview),
                  if (d.cast.isNotEmpty) ...[
                    const SizedBox(height: NasTokens.spaceMd),
                    Text(tr('ui.discover.005'), style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: NasTokens.spaceXs),
                    Wrap(
                      spacing: NasTokens.spaceXs,
                      runSpacing: NasTokens.spaceXs,
                      children: [
                        for (final c in d.cast)
                          Chip(label: Text(c), visualDensity: VisualDensity.compact),
                      ],
                    ),
                  ],
                  if (d.seasons.isNotEmpty) ...[
                    const SizedBox(height: NasTokens.spaceMd),
                    Text(tr('discover.detail.seasons'), style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: NasTokens.spaceXs),
                    Wrap(
                      spacing: NasTokens.spaceXs,
                      runSpacing: NasTokens.spaceXs,
                      children: [
                        for (final s in d.seasons)
                          Chip(
                            label: Text(
                              [
                                tr('discover.detail.season', {'n': '${s['season'] ?? ''}'}),
                                if (((s['episodes'] as num?)?.toInt() ?? 0) > 0)
                                  tr('discover.detail.episodeCount', {'n': '${s['episodes']}'}),
                              ].join(' · '),
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: NasTokens.spaceLg),
                  Text(tr('discover.pt.actions'), style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: NasTokens.spaceXs),
                  Wrap(
                    spacing: NasTokens.spaceSm,
                    runSpacing: NasTokens.spaceSm,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _subscribePt,
                        icon: const Icon(Icons.playlist_add, size: 18),
                        label: Text(tr('discover.pt.subscribe')),
                      ),
                      OutlinedButton.icon(
                        onPressed: _searchPt,
                        icon: const Icon(Icons.search, size: 18),
                        label: Text(tr('discover.pt.searchNow')),
                      ),
                      OutlinedButton.icon(
                        onPressed: _copyLink,
                        icon: const Icon(Icons.link, size: 18),
                        label: Text(tr('discover.detail.copyLink')),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: NasTokens.spaceLg),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}