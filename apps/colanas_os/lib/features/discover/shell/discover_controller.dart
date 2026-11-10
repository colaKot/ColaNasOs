// 从参考实现原样搬运：以下 lint 属于参考源码风格，保持 1:1 不改写。
// ignore_for_file: use_null_aware_elements, unnecessary_underscores, use_build_context_synchronously, unused_element, dead_code, dead_null_aware_expression
import 'compat/getx.dart';
import 'compat/i18n.dart';

import 'service/discover_api_service.dart';

/// 可选语言（TMDB with_original_language 代码）
const List<Map<String, String>> kDiscoverLanguages = [
  {'code': 'zh', 'label': 'discover_lang_zh'},
  {'code': 'en', 'label': 'discover_lang_en'},
  {'code': 'ja', 'label': 'discover_lang_ja'},
  {'code': 'ko', 'label': 'discover_lang_ko'},
  {'code': 'fr', 'label': 'discover_lang_fr'},
  {'code': 'de', 'label': 'discover_lang_de'},
  {'code': 'es', 'label': 'discover_lang_es'},
  {'code': 'it', 'label': 'discover_lang_it'},
  {'code': 'ru', 'label': 'discover_lang_ru'},
  {'code': 'pt', 'label': 'discover_lang_pt'},
  {'code': 'ar', 'label': 'discover_lang_ar'},
  {'code': 'th', 'label': 'discover_lang_th'},
  {'code': 'hi', 'label': 'discover_lang_hi'},
  {'code': 'id', 'label': 'discover_lang_id'},
  {'code': 'vi', 'label': 'discover_lang_vi'},
];

/// 国家/地区筛选（TMDB with_origin_country；空 = 不限）
const List<Map<String, String>> kDiscoverCountries = [
  {'code': 'all', 'label': 'discover_country_all', 'regions': ''},
  {'code': 'cn', 'label': 'discover_country_cn', 'regions': 'CN|HK|TW'},
  {'code': 'jpkr', 'label': 'discover_country_jpkr', 'regions': 'JP|KR'},
  {'code': 'west', 'label': 'discover_country_west', 'regions': 'US|GB|FR|DE|ES|IT|CA|AU|NZ|SE|NO|DK|FI|NL|BE|CH|AT|PT|IE|GR|PL'},
  {'code': 'other', 'label': 'discover_country_other', 'regions': 'IN|TH|TR|ID|PH|VN|MY|SG|PK|BD|IR|IL|EG|ZA|BR|MX|AR|CL|CO|PE|RU|UA|CZ|HU|RO|BG'},
];

/// 年代筛选（from/to 为空表示不限）
const List<Map<String, String>> kDiscoverYears = [
  {'code': 'all', 'label': 'discover_year_all', 'from': '', 'to': ''},
  {'code': '2026', 'label': 'discover_year_2026', 'from': '2026', 'to': '2026'},
  {'code': '2025', 'label': 'discover_year_2025', 'from': '2025', 'to': '2025'},
  {'code': '2024', 'label': 'discover_year_2024', 'from': '2024', 'to': '2024'},
  {'code': '2023', 'label': 'discover_year_2023', 'from': '2023', 'to': '2023'},
  {'code': '2022', 'label': 'discover_year_2022', 'from': '2022', 'to': '2022'},
  {'code': '2021', 'label': 'discover_year_2021', 'from': '2021', 'to': '2021'},
  {'code': '2020s', 'label': 'discover_year_2020s', 'from': '2020', 'to': '2029'},
  {'code': '2010s', 'label': 'discover_year_2010s', 'from': '2010', 'to': '2019'},
  {'code': '2000s', 'label': 'discover_year_2000s', 'from': '2000', 'to': '2009'},
  {'code': '90s', 'label': 'discover_year_90s', 'from': '1990', 'to': '1999'},
  {'code': '80s', 'label': 'discover_year_80s', 'from': '1980', 'to': '1989'},
  {'code': '70s', 'label': 'discover_year_70s', 'from': '1970', 'to': '1979'},
  {'code': '60s', 'label': 'discover_year_60s', 'from': '1960', 'to': '1969'},
];

/// 影视发现 / PT / RSS 应用控制器。
class DiscoverController extends GetxController {
  final DiscoverApiService _api = DiscoverApiService.instance;

  // ===== 发现页：筛选 / 排序状态 =====
  final RxString mediaType = 'movie'.obs;
  final RxString sortBy = 'popularity.desc'.obs;
  final RxList<int> genreIds = <int>[].obs;
  final RxList<String> languages = <String>[].obs;
  final RxDouble minVote = 6.0.obs;

  final RxInt browsePage = 1.obs;
  final RxInt totalPages = 1.obs;
  final RxInt totalResults = 0.obs;
  final RxBool browsing = false.obs;
  final RxList<Map<String, dynamic>> browseItems = <Map<String, dynamic>>[].obs;
  final RxList<Map<String, dynamic>> genres = <Map<String, dynamic>>[].obs;

  // ===== PT / RSS / 任务 =====
  final RxList<Map<String, dynamic>> sites = <Map<String, dynamic>>[].obs;
  final RxList<Map<String, dynamic>> rules = <Map<String, dynamic>>[].obs;
  final RxList<Map<String, dynamic>> searchResults = <Map<String, dynamic>>[].obs;
  final RxList<Map<String, dynamic>> excludedResults = <Map<String, dynamic>>[].obs;
  /// 各站点搜索状态（含失败原因），用于界面上说明「为什么没有结果」
  final RxList<Map<String, dynamic>> siteStatus = <Map<String, dynamic>>[].obs;
  final RxBool searching = false.obs;

  final RxList<Map<String, dynamic>> tasks = <Map<String, dynamic>>[].obs;
  final RxList<Map<String, dynamic>> feeds = <Map<String, dynamic>>[].obs;
  final RxList<Map<String, dynamic>> entries = <Map<String, dynamic>>[].obs;

  /// 排序项：日期字段随类型切换（电影 primary_release_date / 剧集 first_air_date）
  List<Map<String, String>> get sortOptions {
    final dateField = mediaType.value == 'tv' ? 'first_air_date' : 'primary_release_date';
    return [
      {'value': 'popularity.desc', 'label': 'discover_sort_popularity_desc'},
      {'value': 'popularity.asc', 'label': 'discover_sort_popularity_asc'},
      {'value': '$dateField.desc', 'label': 'discover_sort_date_desc'},
      {'value': '$dateField.asc', 'label': 'discover_sort_date_asc'},
      {'value': 'vote_average.desc', 'label': 'discover_sort_vote_desc'},
      {'value': 'vote_average.asc', 'label': 'discover_sort_vote_asc'},
    ];
  }

  bool get hasMore => browsePage.value < totalPages.value;

  // ===== 页签 / 年代 =====
  final RxInt tabIndex = 0.obs;
  final RxString yearCode = 'all'.obs;
  final RxString countryCode = 'all'.obs;

  /// 当前国家档对应的 TMDB with_origin_country 值（空 = 不限）
  String get countryRegions {
    final c = kDiscoverCountries.firstWhere((e) => e['code'] == countryCode.value,
        orElse: () => kDiscoverCountries.first);
    return c['regions'] ?? '';
  }

  void setCountry(String code) {
    if (countryCode.value == code) return;
    countryCode.value = code;
    loadBrowse(reset: true);
  }

  Map<String, String?> get yearRange {
    final y = kDiscoverYears.firstWhere((e) => e['code'] == yearCode.value,
        orElse: () => kDiscoverYears.first);
    final from = y['from'] ?? '';
    final to = y['to'] ?? '';
    return {'from': from.isEmpty ? null : from, 'to': to.isEmpty ? null : to};
  }

  String get sortLabel =>
      (sortOptions.firstWhere((o) => o['value'] == sortBy.value, orElse: () => sortOptions.first))['label']!.tr;

  void setYear(String code) {
    if (yearCode.value == code) return;
    yearCode.value = code;
    loadBrowse(reset: true);
  }

  void setTab(int i) {
    tabIndex.value = i;
    if (i == 1) {
      loadSites();
      loadSubscriptions();
      // 订阅页的「下载归档目录」下拉要库列表 + 当前保存的库 id
      loadFilter();
      loadVideoSources();
    } else if (i == 2) {
      loadFeeds();
      loadLedger();
    } else if (i == 3) {
      loadTasks();
      loadFavorites();
    }
  }

  @override
  void onInit() {
    super.onInit();
    loadGenres();
    loadBrowse(reset: true);
    // 预载订阅列表：发现页卡片右键「订阅」需要据此判断是否已订阅（避免重复订阅 / 显示正确文案）
    loadSubscriptions();
  }

  // ---------- 发现页 ----------

  Future<void> loadGenres() async {
    final res = await _api.getGenres(mediaType.value);
    if (res.success && res.data != null) {
      genres.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
  }

  Future<Map<String, dynamic>?> _fetchPage(int page) async {
    final range = yearRange;
    final res = await _api.browse({
      'media_type': mediaType.value,
      'sort_by': sortBy.value,
      'genre_ids': genreIds.toList(),
      'languages': const <String>[],
      if (countryRegions.isNotEmpty) 'country': countryRegions,
      if (range['from'] != null) 'year_from': range['from'],
      if (range['to'] != null) 'year_to': range['to'],
      'min_vote': minVote.value,
      'page': page,
    });
    return res.success ? res.data : null;
  }

  // ---------- 评分体系（TMDB 默认 / 豆瓣）----------

  /// 当前评分体系：'tmdb'（默认）或 'douban'
  final RxString ratingProvider = 'tmdb'.obs;

  /// 按当前评分体系取一部片子的展示分（豆瓣缺数据时返回 null）
  double? ratingOf(Map<String, dynamic> item) {
    if (ratingProvider.value == 'douban') {
      final v = item['rating_douban'];
      return (v is num && v > 0) ? v.toDouble() : null;
    }
    final v = item['vote_average'];
    return (v is num && v > 0) ? v.toDouble() : null;
  }

  /// 从列表响应里同步「评分体系」（服务端在 browse/catalog/search 里带回 rating_provider）
  void _takeProvider(Map<String, dynamic>? data) {
    final p = (data?['rating_provider'] ?? '').toString();
    if (p == 'douban' || p == 'tmdb') ratingProvider.value = p;
  }

  /// 评分体系=豆瓣 时，为当前列表补齐豆瓣评分（后台补，不阻塞首屏）
  Future<void> enrichDoubanFor(List<Map<String, dynamic>> items) async {
    if (ratingProvider.value != 'douban' || items.isEmpty) return;
    final need = <int>[];
    for (final it in items) {
      final v = it['rating_douban'];
      if (v is num && v > 0) continue;
      final id = (it['id'] as num?)?.toInt() ?? 0;
      if (id > 0) need.add(id);
    }
    if (need.isEmpty) return;
    final res = await _api.enrichDouban(need);
    if (!res.success || res.data == null) return;
    final map = (res.data!['items'] as Map?)?.cast<String, dynamic>();
    if (map == null) return;
    map.forEach((k, v) {
      if (v is! Map) return;
      final id = int.tryParse(k);
      if (id == null) return;
      _applyDouban(id, v.cast<String, dynamic>());
    });
  }

  void _applyDouban(int mediaId, Map<String, dynamic> v) {
    void upd(RxList<Map<String, dynamic>> list) {
      for (var i = 0; i < list.length; i++) {
        if (((list[i]['id'] as num?)?.toInt() ?? 0) == mediaId) {
          list[i] = {
            ...list[i],
            'rating_douban': v['rating'],
            'douban_vote_count': v['vote_count'],
            'douban_id': v['douban_id'],
            'douban_url': v['url'],
          };
        }
      }
    }

    upd(browseItems);
    upd(catalogItems);
    upd(mediaSearchResults);
  }

  /// reset=true 时默认加载 40 部（TMDB 每页 20，取两页）
  Future<void> loadBrowse({bool reset = false}) async {
    if (browsing.value) return;
    browsing.value = true;
    try {
      if (reset) {
        browsePage.value = 1;
        final collected = <Map<String, dynamic>>[];
        var fetched = 0;
        var pagesTotal = 1;
        // ⭐ 首屏两页并行取（原来是串行 for 循环，40 张卡要多等一整个来回）
        final pages = await Future.wait([_fetchPage(1), _fetchPage(2)]);
        for (final d in pages) {
          if (d == null) continue;
          _takeProvider(d);
          collected.addAll(((d['items'] as List?) ?? []).cast<Map<String, dynamic>>());
          fetched = (d['total_results'] as num?)?.toInt() ?? fetched;
          pagesTotal = (d['total_pages'] as num?)?.toInt() ?? pagesTotal;
        }
        browseItems.value = collected;
        totalResults.value = fetched;
        totalPages.value = pagesTotal;
        browsePage.value = collected.isEmpty ? 1 : (collected.length / 20).ceil();
        enrichDoubanFor(browseItems);
      } else {
        final d = await _fetchPage(browsePage.value + 1);
        if (d != null) {
          _takeProvider(d);
          browseItems.addAll(((d['items'] as List?) ?? []).cast<Map<String, dynamic>>());
          totalResults.value = (d['total_results'] as num?)?.toInt() ?? totalResults.value;
          totalPages.value = (d['total_pages'] as num?)?.toInt() ?? totalPages.value;
          browsePage.value += 1;
          enrichDoubanFor(browseItems);
        }
      }
    } finally {
      browsing.value = false;
    }
  }

  Future<void> _loadMoreLegacy() async {
    if (!hasMore || browsing.value) return;
    browsePage.value += 1;
    await loadBrowse();
  }

  Future<void> loadMore() async {
    await loadBrowse();
  }

  void setMediaType(String mt) {
    if (mediaType.value == mt) return;
    mediaType.value = mt;
    // 日期排序字段需随类型切换，避免失效
    if (sortBy.value.startsWith('primary_release_date') || sortBy.value.startsWith('first_air_date')) {
      sortBy.value = mt == 'tv' ? 'first_air_date.desc' : 'primary_release_date.desc';
    }
    genreIds.clear();
    loadGenres();
    loadBrowse(reset: true);
    // 榜单模式下：类型切换后若当前榜单在新类型不可用则退出，否则按新类型重载
    if (catalogCode.value.isNotEmpty) {
      if (!_catalogAvailable(catalogCode.value)) {
        catalogCode.value = '';
      } else {
        loadCatalog();
      }
    }
  }

  void setSort(String value) {
    if (sortBy.value == value) return;
    sortBy.value = value;
    loadBrowse(reset: true);
  }

  void toggleGenre(int id) {
    if (genreIds.contains(id)) {
      genreIds.remove(id);
    } else {
      genreIds.add(id);
    }
    loadBrowse(reset: true);
  }

  void toggleLanguage(String code) {
    if (languages.contains(code)) {
      languages.remove(code);
    } else {
      languages.add(code);
    }
    loadBrowse(reset: true);
  }

  void setMinVote(double v) {
    minVote.value = v;
  }

  void resetFilters() {
    genreIds.clear();
    languages.clear();
    countryCode.value = 'all';
    minVote.value = 6.0;
    sortBy.value = 'popularity.desc';
    loadBrowse(reset: true);
  }

  // ---------- PT ----------

  Future<Map<String, dynamic>?> findDetail(String mediaType, dynamic id) async {
    final res = await _api.getMediaDetail(mediaType: mediaType, id: id);
    return res.success ? res.data : null;
  }

  Future<void> loadSites() async {
    final res = await _api.listSites();
    if (res.success && res.data != null) {
      sites.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
  }

  /// 保存站点：返回 null 表示成功，否则是给用户看的错误文案。
  ///
  /// 以前返回 bool、调用点只在成功时关弹窗，失败时静默 —— 服务端 400 的时候
  /// 用户只看到「点了没反应」（2026-11-10 反馈）。
  Future<String?> addSite(Map<String, dynamic> body) async {
    final res = await _api.addSite(body);
    if (res.success) {
      await loadSites();
      return null;
    }
    return res.message.trim().isEmpty ? 'discover_save_failed'.tr : res.message;
  }

  Future<bool> saveSiteToken({required int id, required String token}) async {
    final res = await _api.updateSiteCredentials(id: id, token: token);
    if (res.success) await loadSites();
    return res.success;
  }

  Future<bool> deleteSite(int id) async {
    final res = await _api.deleteSite(id);
    if (res.success) await loadSites();
    return res.success;
  }

  Future<Map<String, dynamic>?> testSite(int id) async {
    final res = await _api.testSite(id);
    await loadSites();
    return res.success ? res.data : null;
  }

  Future<void> loadRules() async {
    final res = await _api.listRules();
    if (res.success && res.data != null) {
      rules.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
  }

  Future<void> runSearch({String? keyword, int? mediaId}) async {
    searching.value = true;
    try {
      final res = await _api.ptPreview({
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        if (mediaId != null) 'media_id': mediaId,
      });
      if (res.success && res.data != null) {
        searchResults.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        excludedResults.value = ((res.data!['excluded'] as List?) ?? []).cast<Map<String, dynamic>>();
        siteStatus.value = ((res.data!['sites'] as List?) ?? []).cast<Map<String, dynamic>>();
      }
    } finally {
      searching.value = false;
    }
  }

  Future<bool> submitCandidate(int candidateId, {String? savePath}) async {
    final res = await _api.ptSubmit(candidateId: candidateId, savePath: savePath);
    if (res.success) await loadTasks();
    return res.success;
  }

  Future<void> loadTasks() async {
    final res = await _api.listTasks();
    if (res.success && res.data != null) {
      tasks.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
  }

  Future<void> syncTasks() async {
    await _api.syncTaskStatus();
    await loadTasks();
  }

  Future<void> taskAction(int id, String action) async {
    await _api.taskAction(id, action);
    await loadTasks();
  }

  /// 删除下载任务。toFavorite=true → 先移回「待下载」（收藏监控）再删。
  Future<void> deleteTask(int id, {bool toFavorite = false}) async {
    await _api.taskAction(id, 'delete', body: {'to_favorite': toFavorite});
    await loadTasks();
    await loadFavorites();
  }

  // ---------- RSS ----------

  Future<void> loadFeeds() async {
    final res = await _api.listFeeds();
    if (res.success && res.data != null) {
      feeds.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
  }

  /// 添加 RSS 源。
  ///
  /// [savePath] = 该源专属下载目录（空则用「下载设置」里的默认目录）；
  /// [immediate] = 立即下载；false 时只把种子挂到下载器上、任务保持暂停。
  Future<bool> addFeed({
    required String url,
    String? name,
    String savePath = '',
    bool immediate = true,
  }) async {
    final res = await _api.addFeed({
      'url': url,
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (savePath.trim().isNotEmpty) 'save_path': savePath.trim(),
      'immediate': immediate,
    });
    if (res.success) await loadFeeds();
    return res.success;
  }

  Future<void> deleteFeed(int id) async {
    await _api.deleteFeed(id);
    await loadFeeds();
  }

  Future<void> refreshFeed(int id) async {
    await _api.refreshFeed(id);
    await loadFeeds();
  }

  Future<void> setFeedAuto(int id, bool enabled) async {
    await _api.setFeedAutoDownload(id, enabled);
    await loadFeeds();
  }

  /// 改源的「自动加种 / 立刻开始」；返回被一起 start/stop 的任务数，
  /// 界面据此提示「已应用到 N 个任务」。
  Future<int> setFeedSettings(int id, {bool? autoDownload, bool? immediate}) async {
    final res = await _api.setFeedSettings(id, autoDownload: autoDownload, immediate: immediate);
    await loadFeeds();
    if (!res.success || res.data == null) return 0;
    return (res.data!['applied'] as num?)?.toInt() ?? 0;
  }

  Future<void> loadEntries({String? state}) async {
    final res = await _api.listEntries(state: state);
    if (res.success && res.data != null) {
      entries.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
  }

  Future<void> entryAction(int id, String action) async {
    await _api.entryAction(id, action);
    await loadEntries();
    await loadTasks();
  }

  // ---------- 收藏（星标）----------

  /// 切换收藏；成功后就地更新列表项，避免整页重刷
  Future<void> toggleFavorite(int index) async {
    if (index < 0 || index >= browseItems.length) return;
    final item = browseItems[index];
    final id = item['id'];
    if (id is! int) return;
    final on = !(item['favorited'] == true);
    final res = await _api.favoriteToggle(mediaId: id, on: on);
    if (res.success) {
      browseItems[index] = {...item, 'favorited': on};
      // 待下载 / 已下载是另外两个列表，不刷新的话刚收藏的电影看不见
      await loadFavorites();
    }
  }

  // ---------- 收藏列表（待下载 / 已下载）----------

  final RxList<Map<String, dynamic>> favWatching = <Map<String, dynamic>>[].obs;
  final RxList<Map<String, dynamic>> favDownloaded = <Map<String, dynamic>>[].obs;

  /// 收藏列表里查一项（待下载 + 已下载）
  Map<String, dynamic>? _findFavorite(dynamic mediaId) {
    if (mediaId == null) return null;
    for (final list in [favWatching, favDownloaded]) {
      for (final it in list) {
        if (it['media_id'] == mediaId || it['id'] == mediaId) return it;
      }
    }
    return null;
  }

  /// 是否已收藏（星标）：先查列表，再退回到发现页当前项
  bool isFavorited(dynamic mediaId) {
    if (mediaId == null) return false;
    final f = _findFavorite(mediaId);
    if (f != null) return true;
    for (final it in browseItems) {
      if (it['id'] == mediaId && it['favorited'] == true) return true;
    }
    return false;
  }

  /// 是否已拥有/已下载：按媒体 id 匹配（后端以 tmdb/imdb id 判定）
  bool isOwned(dynamic mediaId) {
    if (mediaId == null) return false;
    final f = _findFavorite(mediaId);
    if (f != null && (f['owned'] == true || f['downloaded'] == true)) return true;
    for (final it in browseItems) {
      if (it['id'] == mediaId && (it['owned'] == true || it['downloaded'] == true)) return true;
    }
    return false;
  }

  /// 按媒体 id 切换收藏（详情页用）：命中发现页列表则就地更新，否则直接调接口
  Future<void> toggleFavoriteByMediaId(int mediaId) async {
    final on = !isFavorited(mediaId);
    for (var i = 0; i < browseItems.length; i++) {
      if (browseItems[i]['id'] == mediaId) {
        final res = await _api.favoriteToggle(mediaId: mediaId, on: on);
        if (res.success) browseItems[i] = {...browseItems[i], 'favorited': on};
        await loadFavorites();
        return;
      }
    }
    await _api.favoriteToggle(mediaId: mediaId, on: on);
    await loadFavorites();
  }

  Future<void> loadFavorites() async {
    final w = await _api.listFavorites(state: 'watching');
    if (w.success && w.data != null) {
      favWatching.value = ((w.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
    final d = await _api.listFavorites(state: 'downloaded');
    if (d.success && d.data != null) {
      favDownloaded.value = ((d.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
  }

  Future<void> unFavorite(int mediaId) async {
    await _api.favoriteToggle(mediaId: mediaId, on: false);
    await loadFavorites();
    // 之前这里还跟着 loadBrowse(reset: true) —— 取消一个收藏要把整页发现列表
    // 重新拉一遍（要走 TMDB / 代理），点一下星标就卡住。改成只更新受影响的那几项。
    _setFavorited(mediaId, false);
  }

  /// 就地更新各列表里的收藏星标（不重新拉整页）
  void _setFavorited(int mediaId, bool on) {
    void upd(RxList<Map<String, dynamic>> list) {
      for (var i = 0; i < list.length; i++) {
        if (((list[i]['id'] as num?)?.toInt() ?? 0) == mediaId) {
          list[i] = {...list[i], 'favorited': on};
        }
      }
    }

    upd(browseItems);
    upd(catalogItems);
    upd(mediaSearchResults);
  }

  // ---------- 下载筛选 ----------

  final RxMap<String, dynamic> downloadFilter = <String, dynamic>{}.obs;

  Future<void> loadFilter() async {
    final res = await _api.getFilter();
    if (res.success && res.data != null) downloadFilter.assignAll(res.data!);
  }

  Future<bool> saveFilter(Map<String, dynamic> body) async {
    final res = await _api.setFilter(body);
    if (res.success && res.data != null) downloadFilter.assignAll(res.data!);
    return res.success;
  }

  /// 立即扫描待下载收藏：返回服务端统计（scanned / submitted / skipped / owned），
  /// 前端据此提示「扫了几条、新增几条」，避免点了没反应又连点几次。
  Future<Map<String, dynamic>?> scanFavorites() async {
    final res = await _api.favoriteScan();
    await loadTasks();
    await loadFavorites();
    await loadBrowse(reset: true);
    return res.success ? res.data : null;
  }

  // ---------- 发现设置（TMDB 凭据）----------

  final RxMap<String, dynamic> discoverSettings = <String, dynamic>{}.obs;

  Future<void> loadDiscoverSettings() async {
    final res = await _api.getDiscoverSettings();
    if (res.success && res.data != null) discoverSettings.assignAll(res.data!);
  }

  Future<bool> saveDiscoverSettings(Map<String, dynamic> body) async {
    final res = await _api.setDiscoverSettings(body);
    if (res.success && res.data != null) {
      discoverSettings.assignAll(res.data!);
      // 评分体系可能刚被改：同步到 ratingProvider，并刷新榜单入口 + 列表数据源
      _takeProvider(res.data);
      if (catalogCode.value.isNotEmpty && !_catalogAvailable(catalogCode.value)) {
        catalogCode.value = '';
      }
      loadBrowse(reset: true);
      if (catalogMode) loadCatalog();
    }
    return res.success;
  }

  /// 测试 TMDB 连通性（设置页「测试」按钮）
  Future<Map<String, dynamic>?> testDiscoverSettings() async {
    final res = await _api.testDiscoverSettings();
    return res.success ? res.data : null;
  }

  /// 测试豆瓣（返回两段：site 网站连通 / cookie 登录态；含耗时与命中样例）
  /// [cookie] 非空时测这个 cookie（输入框里现填、尚未保存的也能测）
  Future<Map<String, dynamic>?> testDouban({String cookie = ''}) async {
    final res = await _api.testDouban(cookie: cookie);
    return res.success ? res.data : null;
  }

  /// 缓存占用统计（图片落盘 + 评分条数）
  Future<Map<String, dynamic>?> getDiscoverCacheStats() async {
    final res = await _api.getDiscoverCacheStats();
    return res.success ? res.data : null;
  }

  /// 影视库源目录（下载目录下拉用）
  final RxList<Map<String, dynamic>> videoSources = <Map<String, dynamic>>[].obs;

  Future<void> loadVideoSources() async {
    final res = await _api.listVideoSources();
    if (res.success && res.data != null) {
      videoSources.value =
          res.data!.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
  }

  // ---------- 榜单（TMDB catalogs）----------

  /// 榜单入口定义：部分榜单只在特定类型下可用（电影没有「正在播出」，剧集没有「即将上映」）
  static const List<Map<String, String>> kCatalogDefs = [
    {'code': 'today', 'label': 'discover_catalog_today', 'movie': 'trending_day', 'tv': 'trending_tv_day'},
    {'code': 'week', 'label': 'discover_catalog_week', 'movie': 'trending_week', 'tv': 'trending_tv_week'},
    {'code': 'popular', 'label': 'discover_catalog_popular', 'movie': 'popular_movie', 'tv': 'popular_tv'},
    {'code': 'top_rated', 'label': 'discover_catalog_top_rated', 'movie': 'top_rated_movie', 'tv': 'top_rated_tv'},
    {'code': 'upcoming', 'label': 'discover_catalog_upcoming', 'movie': 'upcoming', 'tv': ''},
    {'code': 'on_air', 'label': 'discover_catalog_on_air', 'movie': '', 'tv': 'on_the_air'},
  ];

  /// 豆瓣榜单入口（骨架=豆瓣排名/评分；海报/简介/演员仍走 TMDB 反查）。
  /// ⚠️ 实测豆瓣只有这些 collection：**剧集没有 Top250**（改用分地区榜）、港台已含在国产剧里。
  static const List<Map<String, String>> kDoubanCatalogDefs = [
    {'code': 'showing', 'label': 'discover_dc_showing', 'movie': 'movie_showing', 'tv': ''},
    {'code': 'hot', 'label': 'discover_dc_hot', 'movie': 'movie_hot_gaia', 'tv': 'tv_hot'},
    {'code': 'top250', 'label': 'discover_dc_top250', 'movie': 'movie_top250', 'tv': ''},
    {'code': 'weekly', 'label': 'discover_dc_weekly', 'movie': 'movie_weekly_best', 'tv': 'tv_chinese_best_weekly'},
    {'code': 'weekly_global', 'label': 'discover_dc_weekly_global', 'movie': '', 'tv': 'tv_global_best_weekly'},
    {'code': 'domestic', 'label': 'discover_dc_domestic', 'movie': '', 'tv': 'tv_domestic'},
    {'code': 'american', 'label': 'discover_dc_american', 'movie': '', 'tv': 'tv_american'},
    {'code': 'korean', 'label': 'discover_dc_korean', 'movie': '', 'tv': 'tv_korean'},
    {'code': 'japanese', 'label': 'discover_dc_japanese', 'movie': '', 'tv': 'tv_japanese'},
    {'code': 'variety', 'label': 'discover_dc_variety', 'movie': '', 'tv': 'tv_variety_show'},
    {'code': 'documentary', 'label': 'discover_dc_documentary', 'movie': '', 'tv': 'tv_documentary'},
  ];

  /// 当前评分体系对应的榜单定义（豆瓣 = 豆瓣榜；TMDB = 现状）
  List<Map<String, String>> get _catalogDefs =>
      ratingProvider.value == 'douban' ? kDoubanCatalogDefs : kCatalogDefs;

  /// 当前媒体类型下可用的榜单（**随评分体系切换**）
  List<Map<String, String>> get availableCatalogs =>
      _catalogDefs.where((d) => (d[mediaType.value] ?? '').isNotEmpty).toList();

  /// 当前评分体系 + 媒体类型下，该榜单 code 是否可用
  bool _catalogAvailable(String code) {
    final hit = _catalogDefs.where((e) => e['code'] == code).toList();
    return hit.isNotEmpty && (hit.first[mediaType.value] ?? '').isNotEmpty;
  }

  /// 当前选中的榜单 code（'' = 未进入榜单模式）
  final RxString catalogCode = ''.obs;
  final RxList<Map<String, dynamic>> catalogItems = <Map<String, dynamic>>[].obs;
  final RxBool catalogLoading = false.obs;

  bool get catalogMode => catalogCode.value.isNotEmpty;

  String _catalogTypeOf(String code) {
    final d = kCatalogDefs.firstWhere((e) => e['code'] == code, orElse: () => kCatalogDefs.first);
    return d[mediaType.value] ?? '';
  }

  Future<void> openCatalog(String code) async {
    if (!_catalogAvailable(code)) return;
    catalogCode.value = code;
    await loadCatalog();
  }

  void closeCatalog() {
    catalogCode.value = '';
  }

  Future<void> loadCatalog() async {
    if (!catalogMode) return;
    final code = catalogCode.value;
    catalogLoading.value = true;
    try {
      if (ratingProvider.value == 'douban') {
        // ① 首屏占位：只出「已缓存/DB 已知」的条目，秒回（未命中的先给标题+豆瓣分）
        final fastRes = await _api.getDoubanCatalog(mediaType.value, code, fast: true);
        if (code != catalogCode.value) return; // 期间切换了榜单
        if (fastRes.success && fastRes.data != null) {
          catalogItems.value =
              ((fastRes.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
          _takeProvider(fastRes.data);
        }
        catalogLoading.value = false; // 先结束 loading，页面立刻可见
        // ② 再取完整数据（服务端已后台补全 / 命中缓存）→ 卡片自动带上 TMDB 海报与详情
        final fullRes = await _api.getDoubanCatalog(mediaType.value, code);
        if (code != catalogCode.value) return;
        if (fullRes.success && fullRes.data != null) {
          catalogItems.value =
              ((fullRes.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
          _takeProvider(fullRes.data);
        }
        return;
      }
      final res = await _api.getCatalogs(_catalogTypeOf(code));
      if (res.success && res.data != null) {
        catalogItems.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _takeProvider(res.data);
        enrichDoubanFor(catalogItems);
      } else {
        catalogItems.value = <Map<String, dynamic>>[];
      }
    } finally {
      catalogLoading.value = false;
    }
  }

  // ---------- 影视关键词搜索（TMDB）----------

  final RxString mediaSearchKeyword = ''.obs;
  final RxList<Map<String, dynamic>> mediaSearchResults = <Map<String, dynamic>>[].obs;
  final RxBool mediaSearching = false.obs;

  Future<void> searchMediaKeyword(String keyword) async {
    final kw = keyword.trim();
    mediaSearchKeyword.value = kw;
    if (kw.isEmpty) {
      mediaSearchResults.clear();
      return;
    }
    mediaSearching.value = true;
    try {
      final res = await _api.searchMedia(keyword: kw);
      if (res.success && res.data != null) {
        mediaSearchResults.value =
            ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _takeProvider(res.data);
        enrichDoubanFor(mediaSearchResults);
      } else {
        mediaSearchResults.clear();
      }
    } finally {
      mediaSearching.value = false;
    }
  }

  void clearMediaSearch() {
    mediaSearchKeyword.value = '';
    mediaSearchResults.clear();
  }

  // ---------- 订阅 ----------

  final RxList<Map<String, dynamic>> subscriptions = <Map<String, dynamic>>[].obs;

  Future<void> loadSubscriptions() async {
    final res = await _api.listSubscriptions();
    if (res.success && res.data != null) {
      subscriptions.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
  }

  bool isSubscribed(dynamic mediaId) {
    if (mediaId == null) return false;
    for (final s in subscriptions) {
      if (s['media_id'] == mediaId) return true;
    }
    return false;
  }

  /// 取该影片订阅记录的 id（取消订阅需要的是订阅记录 id，而非 media_id）。
  int? subscriptionIdOf(dynamic mediaId) {
    if (mediaId == null) return null;
    for (final s in subscriptions) {
      if (s['media_id'] == mediaId) {
        final id = s['id'];
        return id is int ? id : int.tryParse('$id');
      }
    }
    return null;
  }

  /// 订阅一部影视（媒体 id 来自发现/详情页）
  Future<bool> subscribe(dynamic mediaId, {int? ruleId}) async {
    final id = mediaId is int ? mediaId : int.tryParse('$mediaId');
    if (id == null) return false;
    final res = await _api.createSubscription(mediaId: id, ruleId: ruleId, enabled: true);
    if (res.success) await loadSubscriptions();
    return res.success;
  }

  Future<bool> unsubscribe(int id) async {
    final res = await _api.deleteSubscription(id);
    if (res.success) await loadSubscriptions();
    return res.success;
  }

  Future<bool> setSubscriptionEnabled(int id, bool enabled) async {
    final res = await _api.updateSubscription(id: id, enabled: enabled);
    if (res.success) await loadSubscriptions();
    return res.success;
  }

  // ---------- 择种规则 CRUD ----------

  Future<bool> addRule(Map<String, dynamic> body) async {
    final res = await _api.addRule(body);
    if (res.success) await loadRules();
    return res.success;
  }

  Future<bool> updateRule(Map<String, dynamic> body) async {
    final res = await _api.updateRule(body);
    if (res.success) await loadRules();
    return res.success;
  }

  Future<bool> deleteRule(int id) async {
    final res = await _api.deleteRule(id);
    if (res.success) await loadRules();
    return res.success;
  }

  // ---------- RSS 下载台账 ----------

  final RxList<Map<String, dynamic>> ledger = <Map<String, dynamic>>[].obs;

  Future<void> loadLedger({String? keyword}) async {
    final res = await _api.listDownloadedLedger(keyword: keyword);
    if (res.success && res.data != null) {
      ledger.value = ((res.data!['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    }
  }

  Future<void> deleteLedgerItem(int id) async {
    await _api.deleteLedgerItem(id);
    await loadLedger();
  }

  Future<void> clearLedger() async {
    await _api.clearLedger();
    await loadLedger();
  }
}