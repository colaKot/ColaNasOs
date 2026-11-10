// 从既有实现按接口约定实现：以下 lint 属于参考源码风格，保持 1:1 不改写。
// ignore_for_file: use_null_aware_elements, unnecessary_underscores, use_build_context_synchronously, unused_element, dead_code, dead_null_aware_expression
import '../compat/getx.dart';

import '../compat/api_base.dart';

/// 影视发现 / PT / RSS 应用的接口层。
class DiscoverApiService extends BaseApiService {
  static DiscoverApiService get instance =>
      Get.isRegistered<DiscoverApiService>()
          ? Get.find<DiscoverApiService>()
          : DiscoverApiService();

  /// 榜单（trending_day/trending_week/popular_movie/popular_tv/upcoming/on_the_air ...）
  Future<ApiResponse<Map<String, dynamic>>> getCatalogs(
    String type, {
    bool force = false,
  }) {
    return apiPost<Map<String, dynamic>>(
      '/api/discover/catalogs/$type',
      body: {'force': force},
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  /// 官方风格表（筛选用）
  Future<ApiResponse<Map<String, dynamic>>> getGenres(String mediaType) {
    return apiGet<Map<String, dynamic>>(
      '/api/discover/genres/$mediaType',
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  /// 筛选式浏览（服务端过滤）
  Future<ApiResponse<Map<String, dynamic>>> browse(Map<String, dynamic> body) {
    return apiPost<Map<String, dynamic>>(
      '/api/discover/browse',
      body: body,
      dataParser: (json, code) => json,
      showLoading: false,
      timeout: const Duration(seconds: 60),
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> searchMedia({
    required String keyword,
    String? mediaType,
  }) {
    return apiPost<Map<String, dynamic>>(
      '/api/discover/media/search',
      body: {
        'keyword': keyword,
        if (mediaType != null) 'media_type': mediaType,
      },
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> getMediaDetail({
    required String mediaType,
    required dynamic id,
  }) {
    return apiGet<Map<String, dynamic>>(
      '/api/discover/media/$mediaType/$id',
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  /// 批量补豆瓣评分（评分体系=豆瓣 时对当前页条目按需调用；服务端带缓存与限流保护）
  Future<ApiResponse<Map<String, dynamic>>> enrichDouban(List<int> mediaIds) {
    return apiPost<Map<String, dynamic>>(
      '/api/discover/douban/enrich',
      body: {'media_ids': mediaIds},
      dataParser: (json, code) => json,
      showLoading: false,
      timeout: const Duration(seconds: 120),
    );
  }

  // ===== PT =====
  Future<ApiResponse<Map<String, dynamic>>> listSites() {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/sites/list',
      body: const <String, dynamic>{},
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> addSite(Map<String, dynamic> body) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/sites/add',
      body: body,
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteSite(int id) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/sites/delete',
      body: {'id': id},
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> updateSiteCredentials({
    required int id,
    required String token,
  }) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/sites/credentials',
      body: {'id': id, 'token': token},
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> testSite(int id) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/sites/$id/test',
      body: const <String, dynamic>{},
      dataParser: (json, code) => json,
      timeout: const Duration(seconds: 30),
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> ptPreview(Map<String, dynamic> body) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/downloads/preview',
      body: body,
      dataParser: (json, code) => json,
      timeout: const Duration(seconds: 60),
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> ptSubmit({
    int? candidateId,
    int? rssEntryId,
    String? savePath,
    bool paused = false,
  }) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/downloads/submit',
      body: {
        if (candidateId != null) 'candidate_id': candidateId,
        if (rssEntryId != null) 'rss_entry_id': rssEntryId,
        if (savePath != null && savePath.isNotEmpty) 'save_path': savePath,
        'paused': paused,
      },
      dataParser: (json, code) => json,
      timeout: const Duration(seconds: 60),
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> listTasks() {
    return apiGet<Map<String, dynamic>>(
      '/api/pt/downloads',
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> syncTaskStatus() {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/downloads/sync-status',
      body: const <String, dynamic>{},
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> taskAction(int id, String action,
      {Map<String, dynamic>? body}) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/downloads/$id/$action',
      body: body ?? const <String, dynamic>{},
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> listRules() {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/rules/list',
      body: const <String, dynamic>{},
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  // ===== 择种规则 CRUD =====
  Future<ApiResponse<Map<String, dynamic>>> addRule(Map<String, dynamic> body) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/rules/add',
      body: body,
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> updateRule(Map<String, dynamic> body) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/rules/update',
      body: body,
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteRule(int id) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/rules/delete',
      body: {'id': id},
      dataParser: (json, code) => json,
    );
  }

  // ===== 影视订阅 =====
  Future<ApiResponse<Map<String, dynamic>>> listSubscriptions() {
    return apiGet<Map<String, dynamic>>(
      '/api/pt/subscriptions',
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> createSubscription({
    required int mediaId,
    int? ruleId,
    bool? enabled,
  }) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/subscriptions',
      body: {
        'media_id': mediaId,
        if (ruleId != null) 'rule_id': ruleId,
        if (enabled != null) 'enabled': enabled,
      },
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> updateSubscription({
    required int id,
    bool? enabled,
    int? ruleId,
  }) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/subscriptions/update',
      body: {
        'id': id,
        if (enabled != null) 'enabled': enabled,
        if (ruleId != null) 'rule_id': ruleId,
      },
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteSubscription(int id) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/subscriptions/delete',
      body: {'id': id},
      dataParser: (json, code) => json,
    );
  }

  // ===== RSS 下载台账 =====
  Future<ApiResponse<Map<String, dynamic>>> listDownloadedLedger({
    String? keyword,
    int? limit,
  }) {
    return apiGet<Map<String, dynamic>>(
      '/api/rss/downloaded',
      queryParams: {
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        if (limit != null) 'limit': '$limit',
      },
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteLedgerItem(int id) {
    return apiPost<Map<String, dynamic>>(
      '/api/rss/downloaded/delete',
      body: {'id': id},
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> clearLedger() {
    return apiPost<Map<String, dynamic>>(
      '/api/rss/downloaded/clear',
      body: const <String, dynamic>{},
      dataParser: (json, code) => json,
    );
  }

  // ===== RSS =====
  Future<ApiResponse<Map<String, dynamic>>> listFeeds() {
    return apiPost<Map<String, dynamic>>(
      '/api/rss/feeds/list',
      body: const <String, dynamic>{},
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> addFeed(Map<String, dynamic> body) {
    return apiPost<Map<String, dynamic>>(
      '/api/rss/feeds/add',
      body: body,
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteFeed(int id) {
    return apiPost<Map<String, dynamic>>(
      '/api/rss/feeds/delete',
      body: {'id': id},
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> refreshFeed(int id) {
    return apiPost<Map<String, dynamic>>(
      '/api/rss/feeds/$id/refresh',
      body: const <String, dynamic>{},
      dataParser: (json, code) => json,
      timeout: const Duration(seconds: 60),
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> setFeedAutoDownload(int id, bool enabled) {
    return apiPost<Map<String, dynamic>>(
      '/api/rss/feeds/$id/auto_download',
      body: {'enabled': enabled},
      dataParser: (json, code) => json,
    );
  }

  /// 源设置：自动加种 / 立刻开始。改完服务端会立刻把该源已在下载器的种子
  /// start / stop，返回值里的 applied 是被改动的任务数。
  Future<ApiResponse<Map<String, dynamic>>> setFeedSettings(
    int id, {
    bool? autoDownload,
    bool? immediate,
  }) {
    return apiPost<Map<String, dynamic>>(
      '/api/rss/feeds/settings',
      body: <String, dynamic>{
        'id': id,
        if (autoDownload != null) 'auto_download': autoDownload,
        if (immediate != null) 'immediate': immediate,
      },
      dataParser: (json, code) => json,
      timeout: const Duration(seconds: 60),
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> listEntries({String? state}) {
    return apiGet<Map<String, dynamic>>(
      '/api/rss/entries',
      queryParams: state != null ? {'state': state} : null,
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> entryAction(int id, String action) {
    return apiPost<Map<String, dynamic>>(
      '/api/rss/entries/$id/$action',
      body: const <String, dynamic>{},
      dataParser: (json, code) => json,
      timeout: const Duration(seconds: 60),
    );
  }

  // ===== 下载筛选 / 收藏 / 设置 =====
  Future<ApiResponse<Map<String, dynamic>>> getFilter() {
    return apiGet<Map<String, dynamic>>('/api/pt/filter', dataParser: (json, code) => json, showLoading: false);
  }

  Future<ApiResponse<Map<String, dynamic>>> setFilter(Map<String, dynamic> body) {
    return apiPost<Map<String, dynamic>>('/api/pt/filter', body: body, dataParser: (json, code) => json);
  }

  Future<ApiResponse<Map<String, dynamic>>> favoriteToggle({required int mediaId, required bool on}) {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/favorites/toggle',
      body: {'media_id': mediaId, 'on': on},
      dataParser: (json, code) => json,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> favoriteScan() {
    return apiPost<Map<String, dynamic>>(
      '/api/pt/favorites/scan',
      body: const <String, dynamic>{},
      dataParser: (json, code) => json,
      timeout: const Duration(seconds: 120),
    );
  }

  /// 收藏列表：state = watching（待下载）| downloaded（已下载）| owned
  Future<ApiResponse<Map<String, dynamic>>> listFavorites({String? state}) {
    return apiGet<Map<String, dynamic>>(
      '/api/pt/favorites',
      queryParams: state != null ? {'state': state} : null,
      dataParser: (json, code) => json,
      showLoading: false,
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> getDiscoverSettings() {
    return apiGet<Map<String, dynamic>>('/api/discover/settings', dataParser: (json, code) => json, showLoading: false);
  }

  Future<ApiResponse<Map<String, dynamic>>> setDiscoverSettings(Map<String, dynamic> body) {
    return apiPost<Map<String, dynamic>>('/api/discover/settings', body: body, dataParser: (json, code) => json);
  }

  /// 测试 TMDB 连通性（返回 ok / 耗时 / 实际使用的代理地址）
  Future<ApiResponse<Map<String, dynamic>>> testDiscoverSettings() {
    return apiPost<Map<String, dynamic>>('/api/discover/settings/test',
        body: const <String, dynamic>{}, dataParser: (json, code) => json);
  }

  /// 测试豆瓣：返回 **两段** 结论 —— site（网站连通）/ cookie（Cookie 登录态）
  /// [cookie] 非空时测这个 cookie（设置页输入框里现填、**尚未保存**的也能直接测）；空则用已保存的
  Future<ApiResponse<Map<String, dynamic>>> testDouban({String cookie = ''}) {
    return apiPost<Map<String, dynamic>>('/api/discover/douban/test',
        body: {'douban_cookie': cookie}, dataParser: (json, code) => json,
        timeout: const Duration(seconds: 60));
  }

  /// 豆瓣榜单（骨架=豆瓣排名/评分；海报/简介/演员用 TMDB 反查结果）
  /// fast=true：首屏占位模式，只返回已缓存条目，未命中的给占位卡片（服务端后台补全）
  Future<ApiResponse<Map<String, dynamic>>> getDoubanCatalog(String kind, String code,
      {int count = 20, bool fast = false}) {
    return apiPost<Map<String, dynamic>>(
      '/api/discover/douban/catalogs/$kind',
      body: {'code': code, 'count': count, if (fast) 'fast': true},
      dataParser: (json, code) => json,
      showLoading: false,
      timeout: const Duration(seconds: 90),
    );
  }

  /// 缓存占用统计（图片落盘占用 + 评分缓存条数）
  Future<ApiResponse<Map<String, dynamic>>> getDiscoverCacheStats() {
    return apiGet<Map<String, dynamic>>('/api/discover/cache/stats',
        dataParser: (json, code) => json, showLoading: false);
  }

  /// 影视库源目录列表（下载目录下拉用；media_type = movie/tv/mixed）
  /// 注意：该接口直接返回数组（与 video 模块同口径），不是 {items: []}
  Future<ApiResponse<List<dynamic>>> listVideoSources() {
    return apiPost<List<dynamic>>('/api/video/source/list',
        body: const <String, dynamic>{}, showLoading: false);
  }
}