import 'package:nas_core/nas_core.dart';

import '../../../../core/session.dart';

/// 既有实现 `BaseApiService` / `ApiResponse` 的等价实现。
///
/// 参考源码的 `DiscoverApiService` 调 `apiGet/apiPost('/api/...')`，而本项目走
/// 强类型 `ApiSession.instance.client`（`/api/v1/...`，camelCase 字段）。
/// 这里做一层「路径 + 字段」双向翻译，让搬过来的三个 Dart 文件**一行都不用改**。
///
/// 参考服务里的 43 个端点已全部接到本项目真实能力上；字段层面除了 snake_case ↔
/// camelCase，还要处理几处语义差异（设置存库 id 而非路径、时间戳要格式化、
/// 地区是多选列表、条目 id 是文本 id 需要 int 桥接）。
class ApiResponse<T> {
  const ApiResponse({
    required this.success,
    this.data,
    this.code = 0,
    this.message = '',
  });

  final bool success;
  final T? data;
  final int code;
  final String message;
}

typedef DataParser<T> = T Function(Map<String, dynamic> json, int code);

abstract class BaseApiService {
  Future<ApiResponse<T>> apiGet<T>(
    String path, {
    Map<String, String>? queryParams,
    DataParser<T>? dataParser,
    bool showLoading = true,
    Duration? timeout,
  }) =>
      _call<T>('GET', path, query: queryParams, dataParser: dataParser);

  Future<ApiResponse<T>> apiPost<T>(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? queryParams,
    DataParser<T>? dataParser,
    bool showLoading = true,
    Duration? timeout,
  }) =>
      _call<T>('POST', path,
          query: queryParams, body: body, dataParser: dataParser);

  Future<ApiResponse<T>> _call<T>(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    DataParser<T>? dataParser,
  }) async {
    try {
      final raw = await CompatApi.send(method, path, body: body, query: query);
      return ApiResponse<T>(success: true, data: _parse<T>(raw, dataParser));
    } catch (e) {
      return ApiResponse<T>(success: false, code: -1, message: '$e');
    }
  }
}

T? _parse<T>(dynamic raw, DataParser<T>? parser) {
  if (raw == null) return null;
  if (parser != null) {
    final map = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    return parser(map, 200);
  }
  if (raw is T) return raw;
  return null;
}

/// 路径分发 + 字段形状转换。
class CompatApi {
  const CompatApi._();

  static ApiClient get _api => ApiSession.instance.client;

  /// 既有实现 的 catalog type → 本项目的 (kind, media)。
  static const Map<String, List<String>> _catalogTypes = <String, List<String>>{
    'trending_day': <String>['trending_day', 'movie'],
    'trending_week': <String>['trending_week', 'movie'],
    'trending_tv_day': <String>['trending_day', 'tv'],
    'trending_tv_week': <String>['trending_week', 'tv'],
    'popular_movie': <String>['popular', 'movie'],
    'popular_tv': <String>['popular', 'tv'],
    'top_rated_movie': <String>['top_rated', 'movie'],
    'top_rated_tv': <String>['top_rated', 'tv'],
    'upcoming': <String>['upcoming', 'movie'],
    'on_the_air': <String>['on_air', 'tv'],
  };

  static const List<Map<String, dynamic>> _movieGenres = <Map<String, dynamic>>[
    {'id': 28, 'name': '动作'}, {'id': 12, 'name': '冒险'},
    {'id': 16, 'name': '动画'}, {'id': 35, 'name': '喜剧'},
    {'id': 80, 'name': '犯罪'}, {'id': 99, 'name': '纪录片'},
    {'id': 18, 'name': '剧情'}, {'id': 10751, 'name': '家庭'},
    {'id': 14, 'name': '奇幻'}, {'id': 27, 'name': '恐怖'},
    {'id': 9648, 'name': '悬疑'}, {'id': 10749, 'name': '爱情'},
    {'id': 878, 'name': '科幻'}, {'id': 53, 'name': '惊悚'},
    {'id': 10752, 'name': '战争'}, {'id': 37, 'name': '西部'},
  ];

  static const List<Map<String, dynamic>> _tvGenres = <Map<String, dynamic>>[
    {'id': 10759, 'name': '动作冒险'}, {'id': 16, 'name': '动画'},
    {'id': 35, 'name': '喜剧'}, {'id': 80, 'name': '犯罪'},
    {'id': 99, 'name': '纪录片'}, {'id': 18, 'name': '剧情'},
    {'id': 10751, 'name': '家庭'}, {'id': 9648, 'name': '悬疑'},
    {'id': 10764, 'name': '真人秀'}, {'id': 10765, 'name': '科幻奇幻'},
  ];

  static Future<dynamic> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final Map<String, dynamic> b = body ?? const <String, dynamic>{};
    final Map<String, String> q = query ?? const <String, String>{};

    // ---------- 发现：榜单 ----------
    if (path.startsWith('/api/discover/catalogs/')) {
      final type = path.substring('/api/discover/catalogs/'.length);
      final pair = _catalogTypes[type] ?? const <String>['trending_day', 'movie'];
      final res = await _api.discoverCatalog(kind: pair[0], media: pair[1], page: 1);
      return _listResponse(res.toJson(), page: res.page, totalPages: res.totalPages);
    }

    // ---------- 发现：风格表（本项目没有该接口，用与 TMDB 一致的静态表） ----------
    if (path.startsWith('/api/discover/genres/')) {
      final media = path.substring('/api/discover/genres/'.length);
      try {
        final res = await _api.discoverGenres(mediaType: media);
        if ((res['items'] as List?)?.isNotEmpty == true) {
          return <String, dynamic>{'media_type': media, 'items': res['items']};
        }
      } catch (_) { /* 回退到内置静态表 */ }
      return <String, dynamic>{
        'media_type': media,
        'items': media == 'tv' ? _tvGenres : _movieGenres,
      };
    }

    // ---------- 发现：筛选浏览 ----------
    if (path == '/api/discover/browse') {
      final genreIds = b['genre_ids'] ?? b['genreIds'];
      final langs = b['languages'];
      // 参考页的 country 是 List<String>（多选地区），本项目接口只要单个 ISO 码
      final countryRaw = _firstOf(b['country'] ?? b['origin_country']);
      final res = await _api.discoverCatalog(
        kind: 'popular',
        media: _str(b['media_type'] ?? b['mediaType'], 'movie'),
        page: _int(b['page'], 1),
        genre: (genreIds is List && genreIds.isNotEmpty) ? genreIds.join('|') : null,
        year: _intOrNull(b['year']),
        yearFrom: _intOrNull(b['year_from'] ?? b['yearFrom']),
        yearTo: _intOrNull(b['year_to'] ?? b['yearTo']),
        language: (langs is List && langs.isNotEmpty) ? langs.take(3).join(',') : null,
        sort: _str(b['sort_by'] ?? b['sortBy'], 'popularity.desc'),
        country: countryRaw.isEmpty ? null : countryRaw.split('|').first,
        minVote: _doubleOrNull(b['min_vote'] ?? b['minVote']),
      );
      return _listResponse(res.toJson(), page: res.page, totalPages: res.totalPages);
    }

    // ---------- 发现：全库搜索 ----------
    if (path == '/api/discover/media/search') {
      final res = await _api.discoverSearch(
        q: _str(b['keyword'], ''),
        media: b['media_type']?.toString(),
        page: 1,
      );
      return _listResponse(res.toJson(), page: res.page, totalPages: res.totalPages);
    }

    // ---------- 发现：详情 ----------
    if (path.startsWith('/api/discover/media/')) {
      final rest = path.substring('/api/discover/media/'.length).split('/');
      if (rest.length >= 2 && rest[1].isNotEmpty) {
        final media = rest[0];
        final id = int.tryParse(rest[1]) ?? 0;
        final res = await _api.discoverDetail(id: id, media: media);
        return _detail(res);
      }
      return _empty();
    }

    // ---------- 设置 ----------
    if (path == '/api/discover/settings' && method == 'GET') {
      final j = (await _api.discoverSettingsGet()).toJson();
      final douban = await _safe(() => _api.discoverDoubanSettingsGet());
      return <String, dynamic>{
        'token_configured': j['apiKeyConfigured'] ?? false,
        'token': '',
        'api_url': j['baseUrl'] ?? '',
        'language': j['language'] ?? 'zh-CN',
        'image_base_url': j['imageBase'] ?? '',
        'proxy_effective': j['proxyUrl'] ?? '',
        'rating_provider': j['ratingProvider'] ?? 'tmdb',
        'douban_cookie': (douban is Map ? douban['cookie'] : null) ?? '',
      };
    }
    if (path == '/api/discover/settings' && method == 'POST') {
      await _api.discoverSettingsSet(
        body: DiscoverSettingsBody(
          apiKey: _nullableStr(b['token']),
          baseUrl: _nullableStr(b['api_url']),
          language: _nullableStr(b['language']),
          imageBase: _nullableStr(b['image_base_url']),
          ratingProvider: _nullableStr(b['rating_provider']),
        ),
      );
      // 豆瓣 Cookie 与评分体系同属「设置页」，一起提交时顺手落库
      if (b.containsKey('douban_cookie')) {
        await _safe(() => _api.discoverDoubanSettings(
            body: <String, dynamic>{'cookie': _str(b['douban_cookie'], '')}));
      }
      return <String, dynamic>{'ok': true};
    }
    if (path == '/api/discover/settings/test') return _api.discoverSettingsTest();
    if (path == '/api/discover/cache/stats') return _api.discoverCacheStats();
    if (path == '/api/discover/douban/enrich') {
      return _api.discoverDoubanEnrich(body: <String, dynamic>{
        'mediaIds': (b['media_ids'] as List?)?.map((e) => _int(e, 0)).toList() ?? <int>[],
        'mediaType': _str(b['media_type'], 'movie'),
      });
    }
    if (path == '/api/discover/douban/test') {
      return await _api.discoverDoubanTest(
          body: <String, dynamic>{'cookie': _str(b['douban_cookie'], '')});
    }
    if (path.startsWith('/api/discover/douban/catalogs/')) {
      final kind = path.substring('/api/discover/douban/catalogs/'.length);
      final res = await _api.discoverDoubanCatalogs(
        kind: kind,
        body: <String, dynamic>{
          'code': _str(b['code'], 'hot'),
          'count': _int(b['count'], 20),
          if (b['fast'] == true) 'fast': true,
        },
      );
      return _listResponse(res);
    }

    // ---------- PT：站点 → 候选 → 提交下载 → 状态同步 ----------
    if (path == '/api/pt/sites/list') {
      final res = _ensureItems(await _api.ptSiteList());
      final items = (res['items'] as List).map((e) {
        final m = _asMap(e);
        return <String, dynamic>{
          ...m,
          'adapter_type': m['kind'] ?? 'nexusphp',
          'web_base_url': m['baseUrl'] ?? '',
          'api_base_url': m['baseUrl'] ?? '',
          'last_test_status': m['lastTestStatus'] ?? '-',
          'credential_configured':
              m['hasCookie'] == true || m['hasApiKey'] == true,
          'priority': m['priority'] ?? 0,
          'enabled': m['enabled'] ?? true,
        };
      }).toList();
      return <String, dynamic>{...res, 'items': items};
    }
    if (path == '/api/pt/sites/add' || path == '/api/pt/sites/credentials') {
      final token = _str(b['token'], '');
      final name = _str(b['name'], '');
      // 站点根地址：网页地址 / API 地址 / base_url 里第一个**非空**的。
      // 不能写 `web_base_url ?? api_base_url`：表单里网页地址是空串（不是 null），
      // `??` 不会回退 → baseUrl 为空 → 服务端 400。
      final siteUrl = <String>[
        _str(b['web_base_url'], ''),
        _str(b['api_base_url'], ''),
        _str(b['base_url'], ''),
      ].map((v) => v.trim()).firstWhere((v) => v.isNotEmpty, orElse: () => '');
      final body = <String, dynamic>{
        if (name.isNotEmpty) 'name': name,
        if (siteUrl.isNotEmpty) 'baseUrl': siteUrl,
        // 既有实现 的 adapter_type=mteam 对应本项目的 kind=mteam（走专有 JSON API）
        'kind': (_str(b['adapter_type'], '') == 'mteam' || siteUrl.contains('m-team'))
            ? 'mteam'
            : 'nexusphp',
        if (b['cookie'] != null && b['cookie'].toString().isNotEmpty)
          'cookie': b['cookie'].toString(),
        if (token.isNotEmpty) 'apiKey': token,
        if (b['user_agent'] != null && b['user_agent'].toString().isNotEmpty)
          'userAgent': b['user_agent'].toString(),
        if (b['priority'] != null)
          'priority': _int(b['priority'], 100).clamp(0, 9999),
        // 超时以前被丢掉（表单里填了也不生效），服务端本来就有 timeoutMs
        if (b['timeout_ms'] != null)
          'timeoutMs': _int(b['timeout_ms'], 20000).clamp(1000, 60000),
        if (b['id'] != null) 'id': _rawId(b['id']),
      };
      return _api.ptSiteUpsert(body: body);
    }
    if (path == '/api/pt/sites/delete') {
      return _api.ptSiteDelete(body: <String, dynamic>{'id': _rawId(b['id'])});
    }
    final siteTest =
        RegExp(r'^/api/pt/sites/([^/]+)/test$').firstMatch(path);
    if (siteTest != null) {
      return _api.ptSiteTest(id: _pathId(siteTest.group(1)!));
    }
    if (path == '/api/pt/downloads/preview') {
      final res = await _api.ptDownloadPreview(body: <String, dynamic>{
        'keyword': _str(b['keyword'] ?? b['title'], ''),
        if (b['original_title'] != null) 'originalTitle': b['original_title'],
        if (b['year'] != null) 'year': b['year'],
        if (b['season'] != null) 'season': _int(b['season'], 0),
        if (b['media_id'] != null) 'mediaId': _int(b['media_id'], 0),
        if (b['media_type'] != null) 'mediaType': b['media_type'],
      });
      return <String, dynamic>{
        'items': _itemsOf(res),
        'excluded': (res['excluded'] as List?) ?? <dynamic>[],
        'sites': (res['sites'] as List?) ?? <dynamic>[],
        'keyword': res['keyword'] ?? '',
        'selected': res['selected'],
        'reason': res['reason'] ?? '',
      };
    }
    if (path == '/api/pt/downloads/submit') {
      return _api.ptDownloadSubmit(body: <String, dynamic>{
        if (b['candidate_id'] != null) 'candidateId': _int(b['candidate_id'], 0),
        if (b['rss_entry_id'] != null) 'rssEntryId': _rawId(b['rss_entry_id']),
        if (b['save_path'] != null) 'savePath': b['save_path'].toString(),
        'paused': b['paused'] == true,
      });
    }
    if (path == '/api/pt/downloads/sync-status') return _api.ptDownloadSyncStatus();
    if (path == '/api/pt/downloads' && method == 'GET') {
      return _ensureItems(await _api.ptDownloads());
    }
    final taskAction =
        RegExp(r'^/api/pt/downloads/([^/]+)/(pause|resume|remove|retry|delete)$')
            .firstMatch(path);
    if (taskAction != null) {
      final raw = taskAction.group(2)!;
      return _api.ptDownloadAction(body: <String, dynamic>{
        'id': _rawId(taskAction.group(1)!),
        // 参考页的「删除」就是移除任务（本地文件不删）
        'action': raw == 'delete' ? 'remove' : raw,
      });
    }
    if (path == '/api/pt/subscriptions' && method == 'GET') {
      final res = _ensureItems(await _api.ptSubscriptionList());
      final items = (res['items'] as List).map((e) {
        final m = _asMap(e);
        return <String, dynamic>{
          ...m,
          'title': m['media_title'] ?? m['mediaTitle'] ?? '',
          'status': m['last_result'] ?? m['lastResult'] ?? '',
        };
      }).toList();
      return <String, dynamic>{...res, 'items': items};
    }
    if (path == '/api/pt/subscriptions' && method == 'POST') {
      return _api.ptSubscriptionUpsert(body: <String, dynamic>{
        if (b['media_id'] != null) 'mediaId': _int(b['media_id'], 0),
        if (b['media_type'] != null) 'mediaType': b['media_type'],
        if (b['rule_id'] != null) 'ruleId': _rawId(b['rule_id']),
        if (b['poster_path'] != null) 'posterPath': b['poster_path'],
        'mediaTitle': _str(b['media_title'] ?? b['title'], ''),
        'enabled': b['enabled'] != false,
      });
    }
    if (path == '/api/pt/subscriptions/update') {
      return _api.ptSubscriptionUpsert(body: <String, dynamic>{
        'id': _rawId(b['id']),
        if (b['media_id'] != null) 'mediaId': _int(b['media_id'], 0),
        if (b['rule_id'] != null) 'ruleId': _rawId(b['rule_id']),
        'mediaTitle': _str(b['media_title'] ?? b['title'], ''),
        'enabled': b['enabled'] != false,
      });
    }
    if (path == '/api/pt/subscriptions/delete') {
      return _api.ptSubscriptionDelete(body: <String, dynamic>{'id': _rawId(b['id'])});
    }

    // ---------- PT：择种规则 CRUD ----------
    if (path == '/api/pt/rules/list') {
      return _ensureItems(await _api.ptRuleList(body: const <String, dynamic>{}));
    }
    if (path == '/api/pt/rules/add' || path == '/api/pt/rules/update') {
      final body = <String, dynamic>{
        'name': _str(b['name'], '规则'),
        if (b['id'] != null) 'id': _rawId(b['id']),
        if (b['enabled'] != null) 'enabled': b['enabled'] == true,
        if (b['priority'] != null) 'priority': _int(b['priority'], 100),
        if (b['quality'] != null) 'quality': b['quality'].toString(),
        if (b['hdr'] != null) 'hdr': b['hdr'].toString(),
        if (b['resolution_order'] is List)
          'resolutionOrder':
              (b['resolution_order'] as List).map((e) => e.toString()).toList(),
        if (b['audio_langs'] is List)
          'audioLangs':
              (b['audio_langs'] as List).map((e) => e.toString()).toList(),
        if (b['min_seeders'] != null) 'minSeeders': _int(b['min_seeders'], 0),
        if (b['max_size_bytes'] != null)
          'maxSizeBytes': _int(b['max_size_bytes'], 0),
        if (b['excluded_keywords'] is List)
          'excludedKeywords':
              (b['excluded_keywords'] as List).map((e) => e.toString()).toList(),
      };
      return path.endsWith('/add')
          ? _api.ptRuleAdd(body: body)
          : _api.ptRuleUpdate(body: body);
    }
    if (path == '/api/pt/rules/delete') {
      return _api.ptRuleDelete(body: <String, dynamic>{'id': _rawId(b['id'])});
    }
    if (path == '/api/pt/favorites' && method == 'GET') {
      final res = _ensureItems(await _api.ptFavoriteList(state: q['state']));
      // 参考页按日期字符串展示「入库时间」，后端回的是 unix 秒
      final items = (res['items'] as List).map((e) {
        final m = _asMap(e);
        return <String, dynamic>{
          ...m,
          'create_time': _fmtTime(m['create_time'] ?? m['createTime']),
          'task_updated_at': _fmtTime(m['task_updated_at'] ?? m['taskUpdatedAt']),
        };
      }).toList();
      return <String, dynamic>{...res, 'items': items};
    }
    if (path == '/api/pt/favorites/toggle') {
      await _api.discoverFavoriteSet(
        body: DiscoverFavoriteBody(
          id: _int(b['media_id'], 0),
          // 以前写死 movie：剧集收藏会被记成电影，收藏页/详情页的类型就错了
          mediaType: _str(b['media_type'], 'movie') == 'tv' ? 'tv' : 'movie',
          favorite: b['on'] == true,
          state: 'watching',
        ),
      );
      return <String, dynamic>{'ok': true};
    }
    if (path == '/api/pt/favorites/scan') return _api.ptFavoriteScan();
    if (path == '/api/pt/filter' && method == 'GET') {
      // 参考页按 snake_case 读（movie_save_path / scan_interval_minutes ...），
      // 而本项目模型是 camelCase + 库 id，直接 toJson 会让整页显示空。
      final res = await _api.ptDownloadSettingsGet();
      return _filterOf(res);
    }
    if (path == '/api/pt/filter' && method == 'POST') {
      // 订阅页的「归档目录」直接传库 id（movie_library_id / tv_library_id）；
      // 设置页仍传源目录路径，按路径反查库 id。两者都能用，谁传谁说了算。
      final explicitMovie = b.containsKey('movie_library_id');
      final explicitTv = b.containsKey('tv_library_id');
      final body = PtDownloadSettingsBody(
        movieLibraryId: explicitMovie
            ? (b['movie_library_id'] ?? '').toString()
            : await _libraryIdForPath(b['movie_save_path']),
        tvLibraryId: explicitTv
            ? (b['tv_library_id'] ?? '').toString()
            : await _libraryIdForPath(b['tv_save_path']),
        siteIds: (b['site_ids'] as List?)?.map((e) => _rawId(e)).toList(),
        quality: _nullableStr(b['quality']),
        hdr: _nullableStr(b['hdr']),
        audioLangs: (b['audio_langs'] as List?)?.map((e) => e.toString()).toList(),
        maxSizeBytes: b['max_size_bytes'] is num ? (b['max_size_bytes'] as num).toInt() : null,
        minSeeders: b['min_seeders'] is num ? (b['min_seeders'] as num).toInt() : null,
        excludedKeywords: (b['excluded_keywords'] as List?)?.map((e) => e.toString()).toList(),
        // 参考页字段名是 scan_interval_minutes（本项目模型叫 scanIntervalMin）
        scanIntervalMin: (b['scan_interval_minutes'] ?? b['scan_interval_min']) is num
            ? ((b['scan_interval_minutes'] ?? b['scan_interval_min']) as num).toInt()
            : null,
        autoDownload: b['auto_download'] is bool ? b['auto_download'] as bool : null,
      );
      return _filterOf(await _api.ptDownloadSettingsSet(body: body));
    }

    // ---------- RSS：feed / 条目 / 永久下载台账 ----------
    if (path == '/api/rss/feeds/list') return _ensureItems(await _api.rssListFeeds());
    if (path == '/api/rss/feeds/add') {
      return _api.rssAddFeed(body: <String, dynamic>{
        'url': _str(b['url'], ''),
        // 名称以前被丢掉了（参考页传 name，本项目 schema 叫 title）
        if (_str(b['name'], '').isNotEmpty) 'title': _str(b['name'], ''),
        if (_str(b['save_path'], '').isNotEmpty) 'savePath': _str(b['save_path'], ''),
        if (b['immediate'] is bool) 'immediate': b['immediate'] as bool,
      });
    }
    if (path == '/api/rss/feeds/delete') {
      return _api.rssRemoveFeed(body: <String, dynamic>{'id': _rawId(b['id'])});
    }
    final feedRefresh =
        RegExp(r'^/api/rss/feeds/([^/]+)/refresh$').firstMatch(path);
    if (feedRefresh != null) {
      return _api.rssRefresh(body: <String, dynamic>{'feedId': _rawId(feedRefresh.group(1)!)});
    }
    final feedAuto =
        RegExp(r'^/api/rss/feeds/([^/]+)/auto_download$').firstMatch(path);
    if (feedAuto != null) {
      return _api.rssFeedAutoDownload(body: <String, dynamic>{
        'id': _rawId(feedAuto.group(1)!),
        'enabled': b['enabled'] == true,
      });
    }
    if (path == '/api/rss/feeds/settings') {
      return _api.rssFeedSettings(body: <String, dynamic>{
        'id': _rawId(b['id']),
        if (b['auto_download'] != null) 'autoDownload': b['auto_download'] == true,
        if (b['immediate'] != null) 'immediate': b['immediate'] == true,
      });
    }
    if (path == '/api/rss/entries') {
      final res = _ensureItems(await _api.rssItems(
        feedId: q['feedId'],
        state: q['state'],
        limit: int.tryParse(q['limit'] ?? ''),
      ));
      // 参考页副标题读 feed_name（本项目字段叫 feedTitle → feed_title）
      final items = (res['items'] as List).map((e) {
        final m = _asMap(e);
        return <String, dynamic>{
          ...m,
          // 参考页拿 `id` 做行操作；本项目条目主键是 guid，映射成 int 才能一进一出
          // （以前压根没给 id，列表上的确认/拒绝按钮点了什么都不会发生）
          'id': _numId((m['guid'] ?? '').toString()),
          'feed_name': m['feed_title'] ?? m['feedTitle'] ?? '',
        };
      }).toList();
      return <String, dynamic>{...res, 'items': items};
    }
    final entryAction =
        RegExp(r'^/api/rss/entries/([^/]+)/(confirm|reject)$').firstMatch(path);
    if (entryAction != null) {
      return _api.rssEntryAction(body: <String, dynamic>{
        'id': _pathId(entryAction.group(1)!),
        'action': entryAction.group(2)!,
      });
    }
    if (path == '/api/rss/downloaded' && method == 'GET') {
      final res = _ensureItems(await _api.rssDownloadedList(
        keyword: q['keyword'],
        limit: int.tryParse(q['limit'] ?? ''),
      ));
      // 参考页把 create_time 当日期字符串用（.replaceAll('T',' ')），
      // 本项目回的是 unix 秒，直接拼会显示成一串数字。
      final items = (res['items'] as List).map((e) {
        final m = _asMap(e);
        return <String, dynamic>{
          ...m,
          'create_time': _fmtTime(m['create_time'] ?? m['createTime']),
        };
      }).toList();
      return <String, dynamic>{...res, 'items': items};
    }
    if (path == '/api/rss/downloaded/delete') {
      return _api.rssDownloadedDelete(
          body: <String, dynamic>{'id': _rawId(b['id'])});
    }
    if (path == '/api/rss/downloaded/clear') return _api.rssDownloadedClear();
    if (path == '/api/video/source/list') {
      final res = await _api.videoSourceList(body: const <String, dynamic>{});
      final raw = res['items'];
      return (raw is List ? raw : const [])
          .whereType<Map>()
          .map((e) => <String, dynamic>{
                'id': e['id'],
                'path': e['path'],
                'library_name': e['libraryName'],
                'media_type': e['mediaType'],
              })
          .toList();
    }

    // 兜底：未识别的 既有实现 端点回空结构（参考页不会崩，只是这一块没数据）。
    // 43 个端点已全部接完，这里正常不会命中。
    return _empty();
  }

  // ---------- 形状转换 ----------

  /// 下载筛选设置：本项目 `{settings, movieDir, tvDir}` → 参考页的 snake_case 平面字段。
  static Map<String, dynamic> _filterOf(PtDownloadSettingsResponse res) {
    final s = res.settings;
    return <String, dynamic>{
      'movie_save_path': res.movieDir,
      'tv_save_path': res.tvDir,
      'movie_library_id': s.movieLibraryId,
      'tv_library_id': s.tvLibraryId,
      // 参考页里所有 id 都是 int：站点列表由 _ensureItems 把 base64url 文本 id 哈希成
      // int，设置页也按 int 存 _siteIds 并用 int.tryParse 回填勾选。这里必须同口径转换，
      // 否则保存能写进库（_rawId 会把 int 还原成真实 id），但重进页面时字符串 id 解析失败
      // ⇒ 勾选恒为空，表现为「保存了又变回不勾选」。
      'site_ids': s.siteIds.map(_numId).toList(),
      'quality': s.quality,
      'hdr': s.hdr,
      'audio_langs': s.audioLangs,
      'max_size_bytes': s.maxSizeBytes,
      'min_seeders': s.minSeeders,
      'excluded_keywords': s.excludedKeywords,
      'scan_interval_minutes': s.scanIntervalMin,
      'auto_download': s.autoDownload,
    };
  }

  /// 参考页存的是「保存目录路径」，本项目存的是影视库 id：按源目录路径反查。
  /// 查不到就返回 null（= 不改），绝不能传空串把已配好的库清掉。
  static Future<String?> _libraryIdForPath(dynamic raw) async {
    final path = (raw ?? '').toString().trim();
    if (path.isEmpty) return null;
    final norm = _normPath(path);
    try {
      final res = await _api.videoSourceList(body: const <String, dynamic>{});
      final list = res['items'];
      if (list is! List) return null;
      for (final e in list) {
        final m = _asMap(e);
        if (_normPath((m['path'] ?? '').toString()) == norm) {
          final id = (m['libraryId'] ?? '').toString();
          if (id.isNotEmpty) return id;
        }
      }
    } catch (_) {
      /* 拿不到源目录列表就当「不改」 */
    }
    return null;
  }

  static String _normPath(String p) =>
      p.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();

  /// unix 秒 / 毫秒 或 ISO 串 → `yyyy-MM-dd HH:mm`（参考页原样展示这个字符串）
  static String _fmtTime(dynamic v) {
    if (v == null) return '';
    if (v is String && v.contains('-')) {
      return v.replaceFirst('T', ' ').split('.').first;
    }
    final n = v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    if (n <= 0) return '';
    // 小于 1e11 当秒，否则当毫秒
    final ms = n < 100000000000 ? n * 1000 : n;
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static Map<String, dynamic> _listResponse(
    Map<String, dynamic> json, {
    int? page,
    int? totalPages,
  }) {
    final items = _itemsOf(json)
        .map((e) => _card(_asMap(e)))
        .toList(growable: false);
    return <String, dynamic>{
      'items': items,
      'page': page ?? json['page'] ?? 1,
      'total_pages': totalPages ?? json['totalPages'] ?? 1,
      'total_results': items.length,
      'degraded': json['degraded'] ?? false,
      'reason': json['reason'] ?? '',
      // 参考页按 rating_provider 决定评分取 vote_average 还是 rating_douban。
      'rating_provider': json['ratingProvider'] ?? 'tmdb',
    };
  }

  /// 本项目 camelCase 媒体卡 → 既有实现 snake_case 条目（补齐参考页会读的字段）。
  static Map<String, dynamic> _card(Map<String, dynamic> c) {
    final id = c['id'];
    final year = c['year'];
    final date = year == null ? '' : '$year-01-01';
    return <String, dynamic>{
      ..._snake(c),
      'id': id,
      'tmdb_id': id,
      'name': c['title'],
      'title': c['title'],
      'original_title': c['originalTitle'],
      'media_type': c['mediaType'] ?? 'movie',
      'poster_path': c['posterPath'],
      // 豆瓣榜单的占位卡没有 TMDB 图，只能用豆瓣封面绝对地址
      'poster_url': c['posterUrl'] ?? c['posterPath'],
      'backdrop_path': c['backdropPath'],
      'release_date': date,
      'first_air_date': date,
      'vote_average': c['rating'] ?? 0,
      // 豆瓣分单独一列：没补齐时是 0，参考页 ratingOf 会返回 null（显示 '-'）
      'rating_douban': c['ratingDouban'] ?? 0,
      'douban_id': c['doubanId'],
      'douban_url': c['doubanUrl'],
      'douban_vote_count': c['doubanVoteCount'],
      'popularity': 0,
      'genre_ids': const <int>[],
      'owned': c['owned'] ?? false,
      // downloaded 以前恒等于 owned（`c['owned']`）：服务端从没回这个字段，
      // 「已下载」角标等于死代码。现在按 downloadState 判定，删掉文件也保留。
      'downloaded': (c['downloadState'] ?? '') == 'downloaded',
      'download_state': c['downloadState'] ?? '',
      'favorited': c['favorited'] ?? false,
    };
  }

  static Map<String, dynamic> _detail(DiscoverDetailResponse r) {
    final year = r.year;
    final date = year == null ? '' : '$year-01-01';
    return <String, dynamic>{
      ..._snake(r.toJson()),
      'id': r.id,
      'tmdb_id': r.id,
      'title': r.title,
      'name': r.title,
      'original_title': r.originalTitle,
      'media_type': r.mediaType,
      'poster_path': r.posterPath,
      'backdrop_path': r.backdropPath,
      'release_date': date,
      'first_air_date': date,
      'vote_average': r.rating ?? 0,
      'runtime': r.runtime ?? 0,
      // 剧集优先用 TMDB 的 number_of_seasons（含特别篇），拿不到再退回季数组长度
      'number_of_seasons':
          r.numberOfSeasons > 0 ? r.numberOfSeasons : r.seasons.length,
      'number_of_episodes': r.numberOfEpisodes,
      'genres': r.genres
          .map((g) => <String, dynamic>{'id': 0, 'name': g})
          .toList(),
      // 演员：优先用带角色名 + 头像的 castMembers（参考页按 profile_url 渲染头像）
      'cast': (r.castMembers?.isNotEmpty == true
              ? r.castMembers!
                  .map((m) => <String, dynamic>{
                        'name': (m['name'] ?? '').toString(),
                        'character': (m['character'] ?? '').toString(),
                        'profile_path': m['profilePath'] ?? '',
                        'profile_url': m['profilePath'] ?? '',
                      })
                  .toList()
              : r.cast
                  .map((n) => <String, dynamic>{
                        'name': n,
                        'character': '',
                        'profile_path': '',
                        'profile_url': '',
                      })
                  .toList()),
      'seasons': r.seasons
          .map((s) => <String, dynamic>{
                'season_number': s['season'],
                'season': s['season'],
                'name': '第 ${s['season']} 季',
                'episode_count': s['episodes'],
                'air_date': '',
              })
          .toList(),
      'status': r.status,
      'tagline': r.tagline,
      'original_language': r.originalLanguage,
      'vote_count': r.voteCount,
      // 参考详情页 _buildInfo 读的是 countries / companies（不是 TMDB 原名）。
      'countries': r.countries,
      'origin_country': r.countries,
      'networks': r.networks,
      'companies': r.companies,
      'production_companies': r.companies,
      'created_by': r.createdBy,
      'external_ids': <String, dynamic>{
        'imdb_id': r.imdbId ?? '',
        'douban_id': r.doubanId ?? '',
      },
      'rating_douban': r.ratingDouban ?? 0,
      'links': <String, dynamic>{
        'tmdb': 'https://www.themoviedb.org/${r.mediaType}/${r.id}',
        'imdb': (r.imdbId ?? '').isEmpty
            ? ''
            : 'https://www.imdb.com/title/${r.imdbId}/',
        'douban': r.doubanUrl ?? '',
      },
    };
  }

  static Map<String, dynamic> _snake(Map<String, dynamic> src) => src.map(
        (String k, dynamic v) => MapEntry<String, dynamic>(
          k.replaceAllMapped(
              RegExp(r'[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}'),
          v,
        ),
      );

  static Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  static List<dynamic> _itemsOf(dynamic v) {
    if (v is List) return v;
    if (v is Map && v['items'] is List) return v['items'] as List<dynamic>;
    return const <dynamic>[];
  }

  /// 既有实现 全用 int id，本项目是 base64url 文本 id / guid。
  /// 下发列表时把字符串映射成稳定整数，动作回传时再反查，避免运行时类型错误。
  static final Map<int, String> _idMap = <int, String>{};

  static int _numId(String raw) {
    var n = raw.hashCode & 0x7fffffff;
    while (_idMap.containsKey(n) && _idMap[n] != raw) {
      n = (n + 1) & 0x7fffffff;
    }
    _idMap[n] = raw;
    return n;
  }

  static String _rawId(dynamic id) {
    if (id is int) return _idMap[id] ?? id.toString();
    return id?.toString() ?? '';
  }

  /// 路径里那段 id → 真实 id。
  ///
  /// 既有实现把 id 直接拼进 URL（`'/api/pt/sites/$id/test'`），而本项目站点 id 是
  /// base64 字符串；UI 手里拿到的是 `_ensureItems` 哈希后的 int，拼进路径就成了纯数字。
  /// 拿这个数字去 `/api/v1/pt/sites/<id>/test` 必然 404，所以按 `_idMap` 还原。
  static String _pathId(String seg) {
    final n = int.tryParse(seg);
    if (n != null) {
      final raw = _idMap[n];
      if (raw != null) return raw;
    }
    return Uri.decodeComponent(seg);
  }

  static Map<String, dynamic> _ensureItems(dynamic v) {
    final items = _itemsOf(v).map((e) {
      // 本项目接口是 camelCase，参考页读 snake_case：两套键都给，省得每处再手写映射
      final m = <String, dynamic>{..._snake(_asMap(e)), ..._asMap(e)};
      final raw = (m['id'] ?? m['guid'] ?? m['feedId'] ?? m['torrentId'])?.toString() ?? '';
      if (raw.isNotEmpty) {
        m['id'] = int.tryParse(raw) ?? _numId(raw);
        m['_rawId'] = raw;
      }
      return m;
    }).toList();
    return <String, dynamic>{
      'items': items,
      'page': 1,
      'total_pages': 1,
      'total_results': items.length,
    };
  }

  static Map<String, dynamic> _empty() => <String, dynamic>{
        'items': <dynamic>[],
        'page': 1,
        'total_pages': 1,
        'total_results': 0,
        'ok': true,
      };

  static Future<dynamic> _safe(Future<dynamic> Function() fn) async {
    try {
      return await fn();
    } catch (_) {
      return null;
    }
  }

  static String _str(dynamic v, String fallback) {
    final s = v?.toString() ?? '';
    return s.isEmpty ? fallback : s;
  }

  /// 取「列表的第一个」或字符串本身（地区多选 → 单个码）。
  static String _firstOf(dynamic v) {
    if (v is List) {
      for (final e in v) {
        final s = e?.toString() ?? '';
        if (s.isNotEmpty) return s;
      }
      return '';
    }
    return v?.toString() ?? '';
  }

  static String? _nullableStr(dynamic v) {
    final s = v?.toString() ?? '';
    return s.isEmpty ? null : s;
  }

  static int _int(dynamic v, int fallback) =>
      v is int ? v : int.tryParse('$v') ?? fallback;

  static int? _intOrNull(dynamic v) {
    if (v == null || '$v'.isEmpty) return null;
    return v is int ? v : int.tryParse('$v');
  }

  static double? _doubleOrNull(dynamic v) {
    if (v == null || '$v'.isEmpty) return null;
    return v is num ? v.toDouble() : double.tryParse('$v');
  }
}
