import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'video_genre_labels.dart';

/// 日系库的四维筛选值（分辨率 / 标签 / 来源 / 题材）。
///
/// 影片列表和演员列表共用同一个类：演员页的口径是「命中任一部符合条件的影片，
/// 这个演员才留下」，所以两边必须传一模一样的参数，否则会出现
/// 「列表筛出 12 部，演员页还有 30 个人」这种对不上的情况。
class VideoJpFilter {
  const VideoJpFilter({
    this.resolution = '',
    this.jpTag = '',
    this.sourceId = '',
    this.genre = '',
  });

  /// '' / '4k' / '1080'
  final String resolution;

  /// '' / 'uncensored' / 'cracked' / 'ltx'
  final String jpTag;

  final String sourceId;
  final String genre;

  bool get isEmpty =>
      resolution.isEmpty && jpTag.isEmpty && sourceId.isEmpty && genre.isEmpty;

  bool get isNotEmpty => !isEmpty;

  int get activeCount => [
    resolution,
    jpTag,
    sourceId,
    genre,
  ].where((v) => v.isNotEmpty).length;

  VideoJpFilter copyWith({
    String? resolution,
    String? jpTag,
    String? sourceId,
    String? genre,
  }) => VideoJpFilter(
    resolution: resolution ?? this.resolution,
    jpTag: jpTag ?? this.jpTag,
    sourceId: sourceId ?? this.sourceId,
    genre: genre ?? this.genre,
  );

  /// 塞进 querystring 的形式（空值不传）
  Map<String, String> toQuery() => <String, String>{
    if (resolution.isNotEmpty) 'resolution': resolution,
    if (jpTag.isNotEmpty) 'jpTag': jpTag,
    if (sourceId.isNotEmpty) 'sourceId': sourceId,
    if (genre.isNotEmpty) 'genre': genre,
  };
}

enum _Facet { resolution, tag, source, genre }

/// 日系演员库的筛选入口：一个图标按钮，点开才是筛选面板。
///
/// 按钮样式与普通影视列表的筛选按钮完全一致（`Icons.filter_alt_outlined` +
/// 有筛选时高亮），只是面板里装的内容不同 —— 日系四维 + 演员页的两个开关。
/// 自己负责 facets 的懒加载与缓存，调用方不用管。
class VideoJpFilterButton extends StatefulWidget {
  const VideoJpFilterButton({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onlyFavorite,
    required this.onlyUnwatched,
    required this.onOnlyFavoriteChanged,
    required this.onOnlyUnwatchedChanged,
    this.libraryId,
  });

  final VideoJpFilter value;
  final ValueChanged<VideoJpFilter> onChanged;

  /// 演员页的两个本地开关，一起收进面板，别再单独占一行
  final bool onlyFavorite;
  final bool onlyUnwatched;
  final ValueChanged<bool> onOnlyFavoriteChanged;
  final ValueChanged<bool> onOnlyUnwatchedChanged;

  final String? libraryId;

  @override
  State<VideoJpFilterButton> createState() => _VideoJpFilterButtonState();
}

class _VideoJpFilterButtonState extends State<VideoJpFilterButton> {
  VideoFacetsResponse? _facets;
  Future<VideoFacetsResponse?>? _pending;

  @override
  void initState() {
    super.initState();
    // 提前拉一次：点开面板时不该等网络
    _load();
  }

  Future<VideoFacetsResponse?> _load() {
    final cached = _facets;
    if (cached != null) return Future.value(cached);
    final pending = _pending;
    if (pending != null) return pending;
    final fut = () async {
      try {
        final f = await ApiSession.instance.client.videoFacets(
          libraryId: widget.libraryId,
        );
        if (mounted) setState(() => _facets = f);
        return f;
      } catch (_) {
        // 选项接口失败不该阻断筛选：面板退化成「没有选项」，开关照常生效
        return null;
      } finally {
        _pending = null;
      }
    }();
    _pending = fut;
    return fut;
  }

  String _tagLabel(String key) => switch (key) {
    'uncensored' => tr('video.filter.uncensored'),
    'cracked' => tr('video.filter.cracked'),
    'ltx' => tr('video.filter.ltx'),
    _ => key,
  };

  String _resLabel(String key) => switch (key) {
    '4k' => tr('video.filter.res4k'),
    '1080' => tr('video.filter.res1080'),
    _ => key,
  };

  String _facetLabel(_Facet f) => switch (f) {
    _Facet.resolution => tr('video.filter.resolution'),
    _Facet.tag => tr('video.filter.tag'),
    _Facet.source => tr('video.filter.source'),
    _Facet.genre => tr('video.filter.genre'),
  };

  /// (值, 显示名)；条数不写进 chip，面板样式与普通影视列表保持一致
  List<(String, String)> _options(_Facet f, VideoFacetsResponse? facets) {
    final sources = facets?.sources ?? const <VideoSourceFacet>[];
    return switch (f) {
      _Facet.resolution => [
        for (final r in facets?.resolutions ?? const <VideoFacetCount>[])
          (r.key, _resLabel(r.key)),
      ],
      _Facet.tag => [
        for (final t in facets?.tags ?? const <VideoFacetCount>[])
          (t.key, _tagLabel(t.key)),
      ],
      _Facet.source => [
        for (var i = 0; i < sources.length; i += 1)
          (sources[i].id, tr('video.filter.sourceN', {'n': '${i + 1}'})),
      ],
      _Facet.genre => [
        for (final g in facets?.genres ?? const <VideoGenreFacet>[])
          (g.name, genreLabel(g.name)),
      ],
    };
  }

  String _current(_Facet f, VideoJpFilter v) => switch (f) {
    _Facet.resolution => v.resolution,
    _Facet.tag => v.jpTag,
    _Facet.source => v.sourceId,
    _Facet.genre => v.genre,
  };

  VideoJpFilter _with(_Facet f, String v, VideoJpFilter old) => switch (f) {
    _Facet.resolution => old.copyWith(resolution: v),
    _Facet.tag => old.copyWith(jpTag: v),
    _Facet.source => old.copyWith(sourceId: v),
    _Facet.genre => old.copyWith(genre: v),
  };

  @override
  Widget build(BuildContext context) {
    final active =
        widget.value.isNotEmpty || widget.onlyFavorite || widget.onlyUnwatched;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tr('video.list.filter'),
      onPressed: _openSheet,
      iconSize: 19,
      visualDensity: VisualDensity.compact,
      style: active
          ? IconButton.styleFrom(
              backgroundColor: scheme.primary.withValues(alpha: 0.14),
            )
          : null,
      icon: Icon(
        Icons.filter_alt_outlined,
        color: active ? scheme.primary : null,
      ),
    );
  }

  Future<void> _openSheet() async {
    final facets = await _load();
    if (!mounted) return;
    // 面板里先改草稿，点「确定」才提交，取消不会悄悄改掉筛选
    var draft = widget.value;
    var fav = widget.onlyFavorite;
    var unwatched = widget.onlyUnwatched;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setLocal) {
            Widget group(
              _Facet f,
              List<(String, String)> options,
              String current,
            ) {
              return Padding(
                padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _facetLabel(f),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        NasChip(
                          label: Text(tr('video.filter.all')),
                          selected: current.isEmpty,
                          onSelected: (_) => setLocal(() {
                            draft = _with(f, '', draft);
                          }),
                        ),
                        for (final (value, label) in options)
                          NasChip(
                            label: Text(label),
                            selected: current == value,
                            onSelected: (_) => setLocal(() {
                              draft = _with(f, value, draft);
                            }),
                          ),
                        // 只有「全部」= 这个维度还没扫到值（SMB 离线 / 没跑过 AI）
                        if (options.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              tr('video.filter.noOptions'),
                              style: TextStyle(
                                fontSize: NasTokens.fontCaption,
                                color: ctx.nasTextSecondary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                0,
                NasTokens.spaceMd,
                NasTokens.spaceMd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      NasChip(
                        label: Text(tr('video.jp.favorites')),
                        selected: fav,
                        onSelected: (v) => setLocal(() => fav = v),
                      ),
                      NasChip(
                        label: Text(tr('video.jp.onlyUnwatched')),
                        selected: unwatched,
                        onSelected: (v) => setLocal(() => unwatched = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  for (final f in _Facet.values)
                    group(f, _options(f, facets), _current(f, draft)),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () => setLocal(() {
                          draft = const VideoJpFilter();
                          fav = false;
                          unwatched = false;
                        }),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: Text(tr('video.list.reset')),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(tr('common.ok')),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final old = widget.value;
    final changed =
        draft.resolution != old.resolution ||
        draft.jpTag != old.jpTag ||
        draft.sourceId != old.sourceId ||
        draft.genre != old.genre;
    if (changed) widget.onChanged(draft);
    if (fav != widget.onlyFavorite) widget.onOnlyFavoriteChanged(fav);
    if (unwatched != widget.onlyUnwatched) {
      widget.onOnlyUnwatchedChanged(unwatched);
    }
  }
}
