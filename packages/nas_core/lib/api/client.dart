// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/openapi.json
// regenerate: npm run gen:client

import 'dart:convert';

import 'api_error.dart';
import 'models.dart';
import 'transport.dart';

/// 由 OpenAPI 生成的强类型客户端。
/// 鉴权通过 [tokenProvider] 注入，不在客户端保存密钥。
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.transport,
    this.tokenProvider,
  });

  final String baseUrl;
  final Transport transport;
  final Future<String?> Function()? tokenProvider;

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  Future<Map<String, String>> _headers({bool jsonBody = false, bool binaryBody = false}) async {
    final headers = <String, String>{};
    if (jsonBody) headers['content-type'] = 'application/json';
    if (binaryBody) headers['content-type'] = 'application/octet-stream';
    final token = await tokenProvider?.call();
    if (token != null && token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Object? _decode(ApiResponse res) {
    if (!res.isOk) throw ApiError.from(res);
    if (res.body.isEmpty) return null;
    try {
      return res.json;
    } catch (_) {
      return res.text;
    }
  }

  Map<String, dynamic> _asMap(Object? value) =>
      value is Map<String, dynamic> ? value : <String, dynamic>{};

  void close() => transport.close();

  /// 导出 OpenAPI 文档
  Future<Map<String, dynamic>> openapiJson() async {
    final res = await transport.send('GET', _uri('/openapi.json'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 存活检查
  Future<Map<String, dynamic>> healthCheck() async {
    final res = await transport.send('GET', _uri('/health'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 就绪检查
  Future<Map<String, dynamic>> readyCheck() async {
    final res = await transport.send('GET', _uri('/ready'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 开发用临时令牌（仅当 COLANAS_DEV_TOKEN=1 且非 production 时可用）
  Future<Map<String, dynamic>> authDevToken() async {
    final res = await transport.send('POST', _uri('/api/v1/auth/dev-token'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 任务列表与统计
  Future<Map<String, dynamic>> tasksList() async {
    final res = await transport.send('GET', _uri('/api/v1/tasks'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 事件增量拉取（按序号，供客户端局部刷新）
  Future<Map<String, dynamic>> eventsRecent({int? since, int? limit}) async {
    final query = <String, String>{
      if (since != null) 'since': '$since',
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/events/recent', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 单个任务状态与进度
  Future<Map<String, dynamic>> tasksGet({required String id}) async {
    final res = await transport.send('GET', _uri('/api/v1/tasks/${Uri.encodeComponent(id)}'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 取消任务（pending 立即停；running 由 handler 的检查点退出）
  Future<Map<String, dynamic>> tasksCancel() async {
    final res = await transport.send('POST', _uri('/api/v1/tasks/cancel'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 暂停任务（按 id / type，或缺省全部 pending）
  Future<Map<String, dynamic>> tasksPause() async {
    final res = await transport.send('POST', _uri('/api/v1/tasks/pause'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 恢复任务（paused → pending）
  Future<Map<String, dynamic>> tasksResume() async {
    final res = await transport.send('POST', _uri('/api/v1/tasks/resume'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 账号密码登录（可选 TOTP）
  Future<Map<String, dynamic>> authLogin({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/auth/login'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 首次安装状态（库里是否还没有任何账号）
  Future<Map<String, dynamic>> authBootstrapStatus() async {
    final res = await transport.send('GET', _uri('/api/v1/auth/bootstrap'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 首次安装：创建第一个管理员（仅在无任何账号时可用）
  Future<Map<String, dynamic>> authBootstrap({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/auth/bootstrap'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 创建子账号
  Future<Map<String, dynamic>> userCreate({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/users/create'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 账号列表
  Future<Map<String, dynamic>> userList() async {
    final res = await transport.send('GET', _uri('/api/v1/accounts/users'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 读取子账号的应用白名单与路径 ACL
  Future<Map<String, dynamic>> userPolicyGet({required String uid}) async {
    final query = <String, String>{
      'uid': uid,
    };
    final res = await transport.send('GET', _uri('/api/v1/accounts/users/policy', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 设置子账号的应用白名单与路径 ACL（未传字段保持不变）
  Future<Map<String, dynamic>> userPolicySet({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/users/policy'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 启用 / 禁用账号
  Future<Map<String, dynamic>> userDisable({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/users/disable'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 当前用户的长期访问令牌（不含明文）
  Future<Map<String, dynamic>> apiTokenList({String? uid}) async {
    final query = <String, String>{
      if (uid != null) 'uid': uid,
    };
    final res = await transport.send('GET', _uri('/api/v1/accounts/tokens', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 创建长期访问令牌（明文只返回一次）
  Future<Map<String, dynamic>> apiTokenCreate({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/tokens'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 撤销长期访问令牌
  Future<Map<String, dynamic>> apiTokenRevoke({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/tokens/revoke'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 编辑账号（用户名 / 密码 / 手机 / 备注）
  Future<Map<String, dynamic>> userUpdate({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/users/update'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 删除账号（禁止删除自己与最后一个管理员）
  Future<Map<String, dynamic>> userDelete({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/users/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 登录记录（成功 / 失败，按用户与时间倒序）
  Future<Map<String, dynamic>> userLoginRecords({String? uid, String? limit}) async {
    final query = <String, String>{
      if (uid != null) 'uid': uid,
      if (limit != null) 'limit': limit,
    };
    final res = await transport.send('GET', _uri('/api/v1/accounts/users/login-records', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 账号操作审计（创建 / 编辑 / 删除 / 2FA / 权限）
  Future<Map<String, dynamic>> userAuditLogs({String? uid, String? limit}) async {
    final query = <String, String>{
      if (uid != null) 'uid': uid,
      if (limit != null) 'limit': limit,
    };
    final res = await transport.send('GET', _uri('/api/v1/accounts/users/audit-logs', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 生成 TOTP secret（未启用）
  Future<Map<String, dynamic>> userTotpSetup({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/users/2fa/setup'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 用一次验证码启用 2FA
  Future<Map<String, dynamic>> userTotpEnable({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/users/2fa/enable'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 关闭 2FA
  Future<Map<String, dynamic>> userTotpDisable({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/accounts/users/2fa/disable'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 加入 IP 黑名单（IP 或 CIDR）
  Future<Map<String, dynamic>> securityIpAdd({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/security/ip/add'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// IP 黑名单
  Future<Map<String, dynamic>> securityIpList() async {
    final res = await transport.send('GET', _uri('/api/v1/security/ip/list'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 移出 IP 黑名单
  Future<Map<String, dynamic>> securityIpRemove({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/security/ip/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 重建全文索引（书名 / 作者 + txt 正文）
  Future<BookFulltextReindexResponse> bookFulltextReindex({required BookFulltextReindexBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/search/reindex'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookFulltextReindexResponse.fromJson(_asMap(_decode(res)));
  }

  /// 全文检索（FTS5，返回片段）
  Future<BookFulltextResponse> bookFulltextSearch({required String q, int? limit}) async {
    final query = <String, String>{
      'q': q,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/book/search', query), headers: await _headers());
    return BookFulltextResponse.fromJson(_asMap(_decode(res)));
  }

  /// 书库列表
  Future<BookLibraryListResponse> bookLibraryList() async {
    final res = await transport.send('GET', _uri('/api/v1/book/libraries'), headers: await _headers());
    return BookLibraryListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建书库（目录须在 files 根内）
  Future<BookLibraryItem> bookLibraryCreate({required BookLibraryCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/libraries'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookLibraryItem.fromJson(_asMap(_decode(res)));
  }

  /// 改名 / 切换书籍或漫画类型
  Future<BookLibraryItem> bookLibraryUpdate({required BookLibraryUpdateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/libraries/update'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookLibraryItem.fromJson(_asMap(_decode(res)));
  }

  /// 删除书库（级联清理收藏 / 进度 / 归档 / 列表条目）
  Future<BookOkResponse> bookLibraryRemove({required BookLibraryRemoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/libraries/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 扫描索引（epub/cbz 解析元数据；未变文件跳过）
  Future<BookScanResponse> bookScan({required BookScanBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/scan'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookScanResponse.fromJson(_asMap(_decode(res)));
  }

  /// 书架（标题序 + 排序键 cursor；可按格式 / 收藏过滤）
  Future<BookListResponse> bookList({String? libraryId, dynamic type, String? q, String? format, String? favorite, String? archived, String? listId, String? cursor, int? limit}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (type != null) 'type': type,
      if (q != null) 'q': q,
      if (format != null) 'format': format,
      if (favorite != null) 'favorite': favorite,
      if (archived != null) 'archived': archived,
      if (listId != null) 'listId': listId,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/book/list', query), headers: await _headers());
    return BookListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 书籍详情（含当前用户收藏与进度）
  Future<BookItem> bookItem({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/book/item', query), headers: await _headers());
    return BookItem.fromJson(_asMap(_decode(res)));
  }

  /// 书库 / 藏书 / 当前用户收藏数
  Future<BookStatsResponse> bookStats() async {
    final res = await transport.send('GET', _uri('/api/v1/book/stats'), headers: await _headers());
    return BookStatsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 封面（epub / cbz 内嵌图，首次访问提取并缓存）
  Future<Map<String, dynamic>> bookCover({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/book/cover', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 内置阅读器目录（epub spine / txt 分章 / cbz 图片页）
  Future<BookTocResponse> bookToc({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/book/toc', query), headers: await _headers());
    return BookTocResponse.fromJson(_asMap(_decode(res)));
  }

  /// 内置阅读器单页（文本页返回纯文本，图片页返回 base64）
  Future<BookPageResponse> bookPage({required String id, required int index}) async {
    final query = <String, String>{
      'id': id,
      'index': '$index',
    };
    final res = await transport.send('GET', _uri('/api/v1/book/page', query), headers: await _headers());
    return BookPageResponse.fromJson(_asMap(_decode(res)));
  }

  /// 生成带短期令牌的阅读地址（可直接交给外部阅读器）
  Future<BookFileUrlResponse> bookFileUrl({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/book/file-url', query), headers: await _headers());
    return BookFileUrlResponse.fromJson(_asMap(_decode(res)));
  }

  /// 阅读 / 下载（支持 Range / ETag）
  Future<Map<String, dynamic>> bookFile({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/book/file', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 封面 / PDF 页图缓存占用
  Future<BookCacheStatsResponse> bookCacheStats() async {
    final res = await transport.send('GET', _uri('/api/v1/book/cache'), headers: await _headers());
    return BookCacheStatsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 清空封面 / PDF 页图缓存
  Future<BookCacheClearResponse> bookCacheClear() async {
    final res = await transport.send('POST', _uri('/api/v1/book/cache/clear'), headers: await _headers());
    return BookCacheClearResponse.fromJson(_asMap(_decode(res)));
  }

  /// 收藏
  Future<BookOkResponse> bookFavoriteAdd({required BookFavoriteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/favorites/add'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 取消收藏
  Future<BookOkResponse> bookFavoriteRemove({required BookFavoriteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/favorites/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 当前用户阅读进度（无记录返回 0）
  Future<BookProgress> bookProgress({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/book/progress', query), headers: await _headers());
    return BookProgress.fromJson(_asMap(_decode(res)));
  }

  /// 保存阅读进度
  Future<BookProgress> bookProgressSave({required BookProgressBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/progress/save'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookProgress.fromJson(_asMap(_decode(res)));
  }

  /// 设置 / 清除书籍所属合集与序号
  Future<BookOkResponse> bookCollectionSet({required BookCollectionBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/collection'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 合集列表（按合集名聚合，带书数与封面书 id）
  Future<BookCollectionsResponse> bookCollections({String? q, String? cursor, int? limit}) async {
    final query = <String, String>{
      if (q != null) 'q': q,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/book/collections', query), headers: await _headers());
    return BookCollectionsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 合集内的书（按序号、标题排序）
  Future<BookListResponse> bookCollectionItems({required String name, String? cursor, int? limit}) async {
    final query = <String, String>{
      'name': name,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/book/collections/items', query), headers: await _headers());
    return BookListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 归档 / 取消归档（按当前用户隔离）
  Future<BookOkResponse> bookArchive({required BookArchiveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/archive'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 当前用户的自定义列表（按名称排序）
  Future<BookListsResponse> bookLists() async {
    final res = await transport.send('GET', _uri('/api/v1/book/lists'), headers: await _headers());
    return BookListsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建自定义列表（同用户重名 409）
  Future<BookListItem> bookListCreate({required BookListCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/lists'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookListItem.fromJson(_asMap(_decode(res)));
  }

  /// 重命名自定义列表
  Future<BookListItem> bookListRename({required BookListRenameBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/lists/rename'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookListItem.fromJson(_asMap(_decode(res)));
  }

  /// 删除自定义列表（级联清条目）
  Future<BookOkResponse> bookListRemove({required BookListRemoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/lists/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 把书加入自定义列表（重复加入跳过）
  Future<BookOkResponse> bookListAdd({required BookListRefBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/lists/add'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 把书移出自定义列表
  Future<BookOkResponse> bookListRemoveItem({required BookListRefBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/lists/items/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 自定义列表内的书（按加入顺序）
  Future<BookListItemsResponse> bookListItems({required String listId}) async {
    final query = <String, String>{
      'listId': listId,
    };
    final res = await transport.send('GET', _uri('/api/v1/book/lists/items', query), headers: await _headers());
    return BookListItemsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 阅读历史（最近读的在最前）
  Future<BookListResponse> bookHistory({int? limit}) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/book/history', query), headers: await _headers());
    return BookListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 清空当前用户的阅读历史（不影响阅读进度）
  Future<BookOkResponse> bookHistoryClear() async {
    final res = await transport.send('POST', _uri('/api/v1/book/history/clear'), headers: await _headers());
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 当前用户的图书合集（含书数与封面）
  Future<BookUserCollectionListResponse> bookUserCollectionList() async {
    final res = await transport.send('GET', _uri('/api/v1/book/user-collections'), headers: await _headers());
    return BookUserCollectionListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建图书合集
  Future<BookUserCollection> bookUserCollectionCreate({required BookUserCollectionBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/user-collections'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookUserCollection.fromJson(_asMap(_decode(res)));
  }

  /// 改名 / 换目录
  Future<BookUserCollection> bookUserCollectionUpdate({required BookUserCollectionUpdateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/user-collections/update'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookUserCollection.fromJson(_asMap(_decode(res)));
  }

  /// 删除合集（不动书与索引）
  Future<BookOkResponse> bookUserCollectionRemove({required BookLibraryRemoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/book/user-collections/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return BookOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 合集里的书
  Future<BookListResponse> bookUserCollectionItems({required String id, int? limit}) async {
    final query = <String, String>{
      'id': id,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/book/user-collections/items', query), headers: await _headers());
    return BookListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 豆瓣榜单（热门/选电影等 tag）
  Future<Map<String, dynamic>> discoverDouban({String? tag, String? limit}) async {
    final query = <String, String>{
      if (tag != null) 'tag': tag,
      if (limit != null) 'limit': limit,
    };
    final res = await transport.send('GET', _uri('/api/v1/discover/douban', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 按标题（+年份）查豆瓣评分
  Future<Map<String, dynamic>> discoverDoubanRating({required String title, String? year}) async {
    final query = <String, String>{
      'title': title,
      if (year != null) 'year': year,
    };
    final res = await transport.send('GET', _uri('/api/v1/discover/douban/rating', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 读取豆瓣配置（Cookie 明文回传）
  Future<Map<String, dynamic>> discoverDoubanSettingsGet() async {
    final res = await transport.send('GET', _uri('/api/v1/discover/douban/settings'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 设置豆瓣 Cookie（可选）
  Future<Map<String, dynamic>> discoverDoubanSettings({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/discover/douban/settings'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 测试豆瓣连通性（用当前 Cookie）
  Future<Map<String, dynamic>> discoverDoubanTest({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/discover/douban/test'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 影视发现设置（只回是否已配置 key，不回 key 本身）
  Future<DiscoverSettings> discoverSettingsGet() async {
    final res = await transport.send('GET', _uri('/api/v1/discover/settings'), headers: await _headers());
    return DiscoverSettings.fromJson(_asMap(_decode(res)));
  }

  /// 保存影视发现设置（apiKey 留空 = 不改）
  Future<DiscoverSettings> discoverSettingsSet({required DiscoverSettingsBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/discover/settings'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return DiscoverSettings.fromJson(_asMap(_decode(res)));
  }

  /// 发现目录（trending / popular / top_rated / upcoming / now_playing / on_air）
  Future<DiscoverCatalogResponse> discoverCatalog({String? kind, String? media, int? page, String? genre, int? year, int? yearFrom, int? yearTo, String? language, String? sort, String? country, double? minVote}) async {
    final query = <String, String>{
      if (kind != null) 'kind': kind,
      if (media != null) 'media': media,
      if (page != null) 'page': '$page',
      if (genre != null) 'genre': genre,
      if (year != null) 'year': '$year',
      if (yearFrom != null) 'yearFrom': '$yearFrom',
      if (yearTo != null) 'yearTo': '$yearTo',
      if (language != null) 'language': language,
      if (sort != null) 'sort': sort,
      if (country != null) 'country': country,
      if (minVote != null) 'minVote': '$minVote',
    };
    final res = await transport.send('GET', _uri('/api/v1/discover/catalog', query), headers: await _headers());
    return DiscoverCatalogResponse.fromJson(_asMap(_decode(res)));
  }

  /// 搜索影视
  Future<DiscoverCatalogResponse> discoverSearch({required String q, String? media, int? page}) async {
    final query = <String, String>{
      'q': q,
      if (media != null) 'media': media,
      if (page != null) 'page': '$page',
    };
    final res = await transport.send('GET', _uri('/api/v1/discover/search', query), headers: await _headers());
    return DiscoverCatalogResponse.fromJson(_asMap(_decode(res)));
  }

  /// 收藏 / 取消收藏发现条目（每用户独立）
  Future<DiscoverFavoriteResponse> discoverFavoriteSet({required DiscoverFavoriteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/discover/favorites/set'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return DiscoverFavoriteResponse.fromJson(_asMap(_decode(res)));
  }

  /// 当前账号的发现收藏（id + mediaType）
  Future<DiscoverFavoriteListResponse> discoverFavorites() async {
    final res = await transport.send('GET', _uri('/api/v1/discover/favorites'), headers: await _headers());
    return DiscoverFavoriteListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 影视详情（简介 / 类型 / 时长 / 主要演员）
  Future<DiscoverDetailResponse> discoverDetail({required int id, String? media}) async {
    final query = <String, String>{
      'id': '$id',
      if (media != null) 'media': media,
    };
    final res = await transport.send('GET', _uri('/api/v1/discover/detail', query), headers: await _headers());
    return DiscoverDetailResponse.fromJson(_asMap(_decode(res)));
  }

  /// 海报 / 剧照代理（磁盘缓存；客户端不需要知道图片域）
  Future<Map<String, dynamic>> discoverImage({required String path, String? size}) async {
    final query = <String, String>{
      'path': path,
      if (size != null) 'size': size,
    };
    final res = await transport.send('GET', _uri('/api/v1/discover/image', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 图片地址（本机代理路径）
  Future<Map<String, dynamic>> discoverImageUrl({required String path, String? size}) async {
    final query = <String, String>{
      'path': path,
      if (size != null) 'size': size,
    };
    final res = await transport.send('GET', _uri('/api/v1/discover/image-url', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 榜单快照清单（含 age / fresh，不含 payload）
  Future<DiscoverCatalogSnapshotList> discoverCatalogSnapshots() async {
    final res = await transport.send('GET', _uri('/api/v1/discover/catalog/snapshots'), headers: await _headers());
    return DiscoverCatalogSnapshotList.fromJson(_asMap(_decode(res)));
  }

  /// 清理超过保留期的榜单快照
  Future<DiscoverCatalogPruneResponse> discoverCatalogPrune() async {
    final res = await transport.send('POST', _uri('/api/v1/discover/catalog/prune'), headers: await _headers());
    return DiscoverCatalogPruneResponse.fromJson(_asMap(_decode(res)));
  }

  /// 扫描同目录 NFO（离线刮削）
  Future<DiscoverScrapeResponse> discoverScrape({required DiscoverScrapeBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/discover/scrape'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return DiscoverScrapeResponse.fromJson(_asMap(_decode(res)));
  }

  /// 已刮削的条目（简介 / 年份 / 类型 / 评分）
  Future<DiscoverMetaList> discoverMeta({String? libraryId, int? limit}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/discover/meta', query), headers: await _headers());
    return DiscoverMetaList.fromJson(_asMap(_decode(res)));
  }

  /// 列出目录（单层，目录优先）
  Future<FilesListResponse> filesList({String? path, String? cursor, int? limit}) async {
    final query = <String, String>{
      if (path != null) 'path': path,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/files/list', query), headers: await _headers());
    return FilesListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 可浏览的根（盘符 / 文件根 / 来源根）
  Future<FilesRootsResponse> filesRoots() async {
    final res = await transport.send('GET', _uri('/api/v1/files/roots'), headers: await _headers());
    return FilesRootsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 分片上传预检（秒传判定 + 已收分片）
  Future<FilesCheckResponse> filesCheck({required FilesCheckBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/files/check'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return FilesCheckResponse.fromJson(_asMap(_decode(res)));
  }

  /// 上传单个分片（application/octet-stream）
  Future<FilesChunkResponse> filesChunk({required String path, required int index, int? total, required List<int> body}) async {
    final query = <String, String>{
      'path': path,
      'index': '$index',
      if (total != null) 'total': '$total',
    };
    final res = await transport.send('POST', _uri('/api/v1/files/chunk', query), headers: await _headers(binaryBody: true), body: body);
    return FilesChunkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 合并分片（幂等）
  Future<FilesMergeResponse> filesMerge({required FilesMergeBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/files/merge'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return FilesMergeResponse.fromJson(_asMap(_decode(res)));
  }

  /// 下载文件（Range / ETag）
  Future<List<int>> filesDownload({required String path, String? inline}) async {
    final query = <String, String>{
      'path': path,
      if (inline != null) 'inline': inline,
    };
    final res = await transport.send('GET', _uri('/api/v1/files/download', query), headers: await _headers());
    if (!res.isOk) throw ApiError.from(res);
    return res.body;
  }

  /// 图片缩略图（JPEG；懒生成 + 文件缓存，缺 ffmpeg 时 503）
  Future<List<int>> filesThumb({required String path, int? size}) async {
    final query = <String, String>{
      'path': path,
      if (size != null) 'size': '$size',
    };
    final res = await transport.send('GET', _uri('/api/v1/files/thumb', query), headers: await _headers());
    if (!res.isOk) throw ApiError.from(res);
    return res.body;
  }

  /// 触发索引（入队，返回任务 id；同一时刻只跑一轮）
  Future<Map<String, dynamic>> filesIndex() async {
    final res = await transport.send('POST', _uri('/api/v1/files/index'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 索引进度（已索引条数 / 断点序号 / 最近事务耗时）
  Future<Map<String, dynamic>> filesIndexStatus() async {
    final res = await transport.send('GET', _uri('/api/v1/files/index/status'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 按路径关键词搜索已索引文件（先 POST /files/index）
  Future<Map<String, dynamic>> filesSearch({required String q, int? limit}) async {
    final query = <String, String>{
      'q': q,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/files/search', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 新建目录（中间层自动补齐）
  Future<FilesMkdirResponse> filesMkdir({required FilesOpPathBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/files/mkdir'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return FilesMkdirResponse.fromJson(_asMap(_decode(res)));
  }

  /// 重命名（同目录改名，名称不允许含分隔符）
  Future<FilesRenameResponse> filesRename({required FilesRenameBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/files/rename'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return FilesRenameResponse.fromJson(_asMap(_decode(res)));
  }

  /// 移动 / 复制（批量，单条失败不影响其它条）
  Future<FilesOpResult> filesMove({required FilesMoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/files/move'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return FilesOpResult.fromJson(_asMap(_decode(res)));
  }

  /// 删除（默认移入回收站；permanent=true 才真删）
  Future<FilesOpResult> filesDelete({required FilesDeleteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/files/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return FilesOpResult.fromJson(_asMap(_decode(res)));
  }

  /// 回收站批次与条目
  Future<FilesTrashListResponse> filesTrashList() async {
    final res = await transport.send('GET', _uri('/api/v1/files/trash'), headers: await _headers());
    return FilesTrashListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 从回收站还原到原路径（目标已存在时该条失败）
  Future<FilesOpResult> filesTrashRestore({required FilesTrashRestoreBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/files/trash/restore'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return FilesOpResult.fromJson(_asMap(_decode(res)));
  }

  /// 清空回收站（可指定批次）
  Future<FilesTrashEmptyResponse> filesTrashEmpty({required FilesTrashEmptyBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/files/trash/empty'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return FilesTrashEmptyResponse.fromJson(_asMap(_decode(res)));
  }

  /// 文件操作日志（按用户 / 类型 / 状态 / 关键词过滤，分页）
  Future<FilesOpLogListResponse> filesOpLogs({String? uid, String? action, dynamic status, String? q, int? limit, int? offset}) async {
    final query = <String, String>{
      if (uid != null) 'uid': uid,
      if (action != null) 'action': action,
      if (status != null) 'status': status,
      if (q != null) 'q': q,
      if (limit != null) 'limit': '$limit',
      if (offset != null) 'offset': '$offset',
    };
    final res = await transport.send('GET', _uri('/api/v1/files/op-logs', query), headers: await _headers());
    return FilesOpLogListResponse.fromJson(_asMap(_decode(res)));
  }

  /// Webhook 列表（不含 secret）
  Future<Map<String, dynamic>> webhookList() async {
    final res = await transport.send('GET', _uri('/api/v1/integration/webhooks'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 创建 Webhook（secret 仅本次返回）
  Future<Map<String, dynamic>> webhookCreate({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/integration/webhooks'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 删除 Webhook
  Future<Map<String, dynamic>> webhookRemove({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/integration/webhooks/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 发送 test 事件
  Future<Map<String, dynamic>> webhookTest({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/integration/webhooks/test'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 触发事件（内部/调试）
  Future<Map<String, dynamic>> integrationEmit({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/integration/emit'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 投递记录
  Future<Map<String, dynamic>> webhookDeliveries({String? hookId}) async {
    final query = <String, String>{
      if (hookId != null) 'hookId': hookId,
    };
    final res = await transport.send('GET', _uri('/api/v1/integration/deliveries', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 媒体工具任务列表（按账号隔离）
  Future<MediaToolTaskListResponse> mediaToolTaskList({String? kind, String? status, String? limit}) async {
    final query = <String, String>{
      if (kind != null) 'kind': kind,
      if (status != null) 'status': status,
      if (limit != null) 'limit': limit,
    };
    final res = await transport.send('GET', _uri('/api/v1/media-tool/tasks', query), headers: await _headers());
    return MediaToolTaskListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 读取单个媒体任务
  Future<MediaToolTaskItem> mediaToolTaskGet({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/media-tool/tasks/get', query), headers: await _headers());
    return MediaToolTaskItem.fromJson(_asMap(_decode(res)));
  }

  /// 创建 / 编辑媒体任务（除单图压缩外需管理员）
  Future<MediaToolTaskItem> mediaToolTaskUpsert({required MediaToolTaskUpsertBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/media-tool/tasks/upsert'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MediaToolTaskItem.fromJson(_asMap(_decode(res)));
  }

  /// 删除媒体任务（不动磁盘文件）
  Future<MediaToolTaskOkResponse> mediaToolTaskDelete({required MediaToolTaskIdBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/media-tool/tasks/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MediaToolTaskOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 开始 / 续跑任务
  Future<MediaToolTaskOkResponse> mediaToolTaskStart({required MediaToolTaskIdBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/media-tool/tasks/start'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MediaToolTaskOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 停止任务（运行中的在下一批检查点停）
  Future<MediaToolTaskOkResponse> mediaToolTaskStop({required MediaToolTaskIdBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/media-tool/tasks/stop'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MediaToolTaskOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 媒体工具任务列表（state / 进度 / 失败数）
  Future<MediaToolJobListResponse> mediaToolJobs({dynamic status, int? limit}) async {
    final query = <String, String>{
      if (status != null) 'status': status,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/media-tool/jobs', query), headers: await _headers());
    return MediaToolJobListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 批量生成缩略图（目录 → JPEG，保留子目录结构）
  Future<MediaToolJobCreated> mediaToolThumbnails({required MediaToolThumbnailsBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/media-tool/thumbnails'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MediaToolJobCreated.fromJson(_asMap(_decode(res)));
  }

  /// 单文件转码（audio AAC / web720 / copy）
  Future<MediaToolJobCreated> mediaToolTranscode({required MediaToolTranscodeBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/media-tool/transcode'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MediaToolJobCreated.fromJson(_asMap(_decode(res)));
  }

  /// 取消任务（运行中的在下一批检查点停）
  Future<MediaToolOkResponse> mediaToolJobCancel({required MediaToolIdBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/media-tool/jobs/cancel'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MediaToolOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 发送站内消息
  Future<Map<String, dynamic>> messageSend({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/messages/send'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 我的消息（可按未读过滤）
  Future<Map<String, dynamic>> messageList({bool? unreadOnly, int? limit}) async {
    final query = <String, String>{
      if (unreadOnly != null) 'unreadOnly': unreadOnly.toString(),
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/messages', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 未读数
  Future<Map<String, dynamic>> messageUnread() async {
    final res = await transport.send('GET', _uri('/api/v1/messages/unread-count'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 标记已读（仅自己的消息）
  Future<Map<String, dynamic>> messageRead({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/messages/read'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 全部已读
  Future<Map<String, dynamic>> messageReadAll() async {
    final res = await transport.send('POST', _uri('/api/v1/messages/read-all'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 删除自己的消息
  Future<Map<String, dynamic>> messageRemove({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/messages/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 挂载列表（不含密码）
  Future<MountListResponse> mountList() async {
    final res = await transport.send('GET', _uri('/api/v1/mount/mounts'), headers: await _headers());
    return MountListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建远程挂载（WebDAV / rclone）
  Future<MountItem> mountCreate({required MountCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/mount/mounts'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MountItem.fromJson(_asMap(_decode(res)));
  }

  /// 删除挂载（只删配置，不动远程数据）
  Future<MountOkResponse> mountRemove({required MountRemoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/mount/mounts/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MountOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 连接测试（同时更新 status / lastError）
  Future<MountItem> mountTest({required MountTestBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/mount/mounts/test'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MountItem.fromJson(_asMap(_decode(res)));
  }

  /// 浏览远程目录（相对挂载根）
  Future<MountBrowseResponse> mountBrowse({required String id, String? path}) async {
    final query = <String, String>{
      'id': id,
      if (path != null) 'path': path,
    };
    final res = await transport.send('GET', _uri('/api/v1/mount/list', query), headers: await _headers());
    return MountBrowseResponse.fromJson(_asMap(_decode(res)));
  }

  /// 生成带短期令牌的下载地址（可直接交给外部下载器）
  Future<MountDownloadUrlResponse> mountDownloadUrl({required String id, required String path, String? token}) async {
    final query = <String, String>{
      'id': id,
      'path': path,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/mount/download-url', query), headers: await _headers());
    return MountDownloadUrlResponse.fromJson(_asMap(_decode(res)));
  }

  /// 下载远程文件（WebDAV 透传 Range）
  Future<Map<String, dynamic>> mountDownload({required String id, required String path, String? token}) async {
    final query = <String, String>{
      'id': id,
      'path': path,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/mount/download', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 上传（application/x-colanas-upload 原始流）
  Future<MountOkResponse> mountUpload({required String id, required String path, int? size, required Map<String, dynamic> body}) async {
    final query = <String, String>{
      'id': id,
      'path': path,
      if (size != null) 'size': '$size',
    };
    final res = await transport.send('POST', _uri('/api/v1/mount/upload', query), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return MountOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建远程目录
  Future<MountOkResponse> mountMkdir({required MountPathBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/mount/mkdir'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MountOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 删除远程文件（不删目录）
  Future<MountOkResponse> mountDelete({required MountPathBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/mount/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MountOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 收藏 / 取消收藏曲目（按用户隔离）
  Future<MusicStateOk> musicFavorite({required MusicFavoriteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/favorite'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicStateOk.fromJson(_asMap(_decode(res)));
  }

  /// 我的收藏（按收藏时间倒序，返回完整曲目）
  Future<MusicListResponse> musicFavorites() async {
    final res = await transport.send('GET', _uri('/api/v1/music/favorites'), headers: await _headers());
    return MusicListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 记录一次播放（写历史）
  Future<MusicStateOk> musicPlay({required MusicTrackRefBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/play'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicStateOk.fromJson(_asMap(_decode(res)));
  }

  /// 播放历史（按时间倒序，返回完整曲目）
  Future<MusicListResponse> musicHistory({int? limit}) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/music/history', query), headers: await _headers());
    return MusicListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 音乐库列表
  Future<MusicLibraryListResponse> musicLibraryList() async {
    final res = await transport.send('GET', _uri('/api/v1/music/libraries'), headers: await _headers());
    return MusicLibraryListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建音乐库（目录须在 files 根内）
  Future<MusicLibraryItem> musicLibraryCreate({required MusicLibraryCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/libraries'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicLibraryItem.fromJson(_asMap(_decode(res)));
  }

  /// 删除音乐库（级联清理曲目与歌单引用）
  Future<MusicOkResponse> musicLibraryRemove({required MusicLibraryRemoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/libraries/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 扫描索引（ffmpeg 解析 tags / 时长；未变文件跳过）
  Future<MusicScanResponse> musicScan({required MusicScanBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/scan'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicScanResponse.fromJson(_asMap(_decode(res)));
  }

  /// 入队扫描（立即返回任务 id；进度与失败记录见 /tasks）
  Future<Map<String, dynamic>> musicScanEnqueue({required MusicScanBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/scan/enqueue'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return _asMap(_decode(res));
  }

  /// 音乐转码缓存占用
  Future<MusicCacheStatsResponse> musicCacheStats() async {
    final res = await transport.send('GET', _uri('/api/v1/music/cache'), headers: await _headers());
    return MusicCacheStatsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 清空音乐转码缓存
  Future<MusicCacheClearResponse> musicCacheClear() async {
    final res = await transport.send('POST', _uri('/api/v1/music/cache/clear'), headers: await _headers());
    return MusicCacheClearResponse.fromJson(_asMap(_decode(res)));
  }

  /// 曲目列表（可排序 + 排序键 cursor）
  Future<MusicListResponse> musicList({String? libraryId, String? q, String? artist, String? album, String? albumArtist, String? genre, int? year, dynamic sort, dynamic order, String? cursor, int? limit}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (q != null) 'q': q,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (albumArtist != null) 'albumArtist': albumArtist,
      if (genre != null) 'genre': genre,
      if (year != null) 'year': '$year',
      if (sort != null) 'sort': sort,
      if (order != null) 'order': order,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/music/list', query), headers: await _headers());
    return MusicListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 专辑聚合（张数 / 总时长 / 代表封面）
  Future<MusicAlbumListResponse> musicAlbums({String? libraryId, String? q, dynamic sort, int? limit}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (q != null) 'q': q,
      if (sort != null) 'sort': sort,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/music/albums', query), headers: await _headers());
    return MusicAlbumListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 艺人聚合（曲目数 / 专辑数 / 代表封面）
  Future<MusicArtistListResponse> musicArtists({String? libraryId, String? q, dynamic sort, int? limit}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (q != null) 'q': q,
      if (sort != null) 'sort': sort,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/music/artists', query), headers: await _headers());
    return MusicArtistListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 曲目详情
  Future<MusicTrack> musicItem({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/music/item', query), headers: await _headers());
    return MusicTrack.fromJson(_asMap(_decode(res)));
  }

  /// 曲目 / 专辑 / 艺术家 / 总时长
  Future<MusicStatsResponse> musicStats() async {
    final res = await transport.send('GET', _uri('/api/v1/music/stats'), headers: await _headers());
    return MusicStatsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 歌词（旁挂 .lrc 优先，其次内嵌；可选 <base>.<lang>.lrc 双语对照）
  Future<MusicLyricsResponse> musicLyrics({required String id, String? token, String? lang}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
      if (lang != null) 'lang': lang,
    };
    final res = await transport.send('GET', _uri('/api/v1/music/lyrics', query), headers: await _headers());
    return MusicLyricsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 内嵌封面（首次访问生成，之后走文件缓存）
  Future<Map<String, dynamic>> musicCover({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/music/cover', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 生成带短期令牌的播放地址（format=auto 时 Web 端按需转 AAC）
  Future<MusicStreamUrlResponse> musicStreamUrl({required String id, String? token, String? format}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
      if (format != null) 'format': format,
    };
    final res = await transport.send('GET', _uri('/api/v1/music/stream-url', query), headers: await _headers());
    return MusicStreamUrlResponse.fromJson(_asMap(_decode(res)));
  }

  /// 播放 / 下载（支持 Range / ETag；format=transcoded 读 AAC 缓存）
  Future<Map<String, dynamic>> musicStream({required String id, String? token, String? format}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
      if (format != null) 'format': format,
    };
    final res = await transport.send('GET', _uri('/api/v1/music/stream', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 当前用户的歌单
  Future<MusicPlaylistListResponse> musicPlaylistList() async {
    final res = await transport.send('GET', _uri('/api/v1/music/playlists'), headers: await _headers());
    return MusicPlaylistListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建歌单（可按 id 批量加入）
  Future<MusicPlaylist> musicPlaylistCreate({required MusicPlaylistCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/playlists'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicPlaylist.fromJson(_asMap(_decode(res)));
  }

  /// 歌单曲目（按加入顺序）
  Future<MusicListResponse> musicPlaylistItems({required String playlistId, int? limit}) async {
    final query = <String, String>{
      'playlistId': playlistId,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/music/playlists/items', query), headers: await _headers());
    return MusicListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 向歌单加入曲目
  Future<MusicOkResponse> musicPlaylistAdd({required MusicPlaylistMembersBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/playlists/add'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 从歌单移出曲目
  Future<MusicOkResponse> musicPlaylistRemove({required MusicPlaylistMembersBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/playlists/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 重命名歌单
  Future<MusicOkResponse> musicPlaylistRename({required MusicPlaylistRenameBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/playlists/rename'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 删除歌单
  Future<MusicOkResponse> musicPlaylistDelete({required MusicPlaylistDeleteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/playlists/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 自动歌单概览（最近添加 / 最近播放 / 最常播放 / 从未播放）
  Future<MusicAutoPlaylistListResponse> musicAutoPlaylists() async {
    final res = await transport.send('GET', _uri('/api/v1/music/auto-playlists'), headers: await _headers());
    return MusicAutoPlaylistListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 自动歌单曲目（kind = recent_added / recently_played / most_played / never_played）
  Future<MusicAutoPlaylistTracksResponse> musicAutoPlaylist({required String kind, int? limit}) async {
    final query = <String, String>{
      'kind': kind,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/music/auto-playlist', query), headers: await _headers());
    return MusicAutoPlaylistTracksResponse.fromJson(_asMap(_decode(res)));
  }

  /// 当前用户的音乐合集（含曲目数与封面）
  Future<MusicCollectionListResponse> musicCollectionList() async {
    final res = await transport.send('GET', _uri('/api/v1/music/collections'), headers: await _headers());
    return MusicCollectionListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建音乐合集
  Future<MusicCollection> musicCollectionCreate({required MusicCollectionBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/collections'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicCollection.fromJson(_asMap(_decode(res)));
  }

  /// 改名 / 换目录
  Future<MusicCollection> musicCollectionUpdate({required MusicCollectionUpdateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/collections/update'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicCollection.fromJson(_asMap(_decode(res)));
  }

  /// 删除合集（不动磁盘文件与曲库索引）
  Future<MusicOkResponse> musicCollectionRemove({required MusicLibraryRemoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/music/collections/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return MusicOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 合集里的曲目
  Future<MusicListResponse> musicCollectionItems({required String id, int? limit}) async {
    final query = <String, String>{
      'id': id,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/music/collections/items', query), headers: await _headers());
    return MusicListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建笔记
  Future<Map<String, dynamic>> noteCreate({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/notes/create'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 笔记列表（关键词 / 标签 / 置顶优先）
  Future<Map<String, dynamic>> noteList({String? q, String? tag, int? limit}) async {
    final query = <String, String>{
      if (q != null) 'q': q,
      if (tag != null) 'tag': tag,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/notes', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 笔记详情
  Future<Map<String, dynamic>> noteGet({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/notes/get', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 更新笔记（先存历史版本；baseVersion 不一致返回 409）
  Future<Map<String, dynamic>> noteUpdate({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/notes/update'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 版本历史（新→旧）
  Future<Map<String, dynamic>> noteVersions({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/notes/versions', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 恢复到历史版本（生成新版本）
  Future<Map<String, dynamic>> noteRestore({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/notes/restore'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 软删除笔记
  Future<Map<String, dynamic>> noteRemove({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/notes/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 分批分析照片（人脸 / 场景 / embedding，可选 OCR 与活动）
  Future<PhotoAiAnalyzeResponse> photoAiAnalyze({required PhotoAiAnalyzeBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/analyze'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiAnalyzeResponse.fromJson(_asMap(_decode(res)));
  }

  /// 整库后台识别（入队，重启后可续跑）
  Future<PhotoAiScanResponse> photoAiScan({required PhotoAiScanBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/scan'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiScanResponse.fromJson(_asMap(_decode(res)));
  }

  /// 分批做文字识别（票夹与语义搜索的原料）
  Future<PhotoAiAnalyzeResponse> photoAiOcr({required PhotoAiBatchBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/ocr'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiAnalyzeResponse.fromJson(_asMap(_decode(res)));
  }

  /// 分批做活动识别（SigLIP2 零样本，τ=0.078）
  Future<PhotoAiAnalyzeResponse> photoAiActivities({required PhotoAiBatchBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/activities'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiAnalyzeResponse.fromJson(_asMap(_decode(res)));
  }

  /// 某个活动下的照片
  Future<PhotoAiPhotoRefList> photoActivities({required String label, int? limit}) async {
    final query = <String, String>{
      'label': label,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/activities', query), headers: await _headers());
    return PhotoAiPhotoRefList.fromJson(_asMap(_decode(res)));
  }

  /// 活动分布（按张数倒序）
  Future<PhotoSceneSummary> photoActivitySummary() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/activities/summary'), headers: await _headers());
    return PhotoSceneSummary.fromJson(_asMap(_decode(res)));
  }

  /// 场景分布（按照片数倒序）
  Future<PhotoSceneSummary> photoSceneSummary() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/scenes/summary'), headers: await _headers());
    return PhotoSceneSummary.fromJson(_asMap(_decode(res)));
  }

  /// 场景多标签分布：张数 + confident/ambiguous 分层 + 封面
  Future<PhotoSceneTagSummary> photoSceneTagSummary() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/scene-tags/summary'), headers: await _headers());
    return PhotoSceneTagSummary.fromJson(_asMap(_decode(res)));
  }

  /// 某个场景标签下的照片（带 gate，可按高置信过滤）
  Future<PhotoSceneTagList> photoSceneTags({required String label, int? limit, bool? onlyConfident}) async {
    final query = <String, String>{
      'label': label,
      if (limit != null) 'limit': '$limit',
      if (onlyConfident != null) 'onlyConfident': onlyConfident.toString(),
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/scene-tags', query), headers: await _headers());
    return PhotoSceneTagList.fromJson(_asMap(_decode(res)));
  }

  /// 单张照片的全部场景标签（含 gate），详情页「这张像什么」用
  Future<PhotoSceneTagList> photoSceneTagsOfPhoto({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/scene-tags/photo', query), headers: await _headers());
    return PhotoSceneTagList.fromJson(_asMap(_decode(res)));
  }

  /// 某个场景下的照片
  Future<PhotoAiPhotoRefList> photoScenes({required String label, int? limit}) async {
    final query = <String, String>{
      'label': label,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/scenes', query), headers: await _headers());
    return PhotoAiPhotoRefList.fromJson(_asMap(_decode(res)));
  }

  /// 以图搜图（CLIP 余弦，内存内 top-k）
  Future<PhotoAiPhotoRefList> photoSimilar({required String id, int? limit, double? minScore}) async {
    final query = <String, String>{
      'id': id,
      if (limit != null) 'limit': '$limit',
      if (minScore != null) 'minScore': '$minScore',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/similar', query), headers: await _headers());
    return PhotoAiPhotoRefList.fromJson(_asMap(_decode(res)));
  }

  /// 人脸聚类列表（按人数倒序；少于 minCount 的碎片组不显示，具名组豁免）
  Future<PhotoFaceClusterList> photoFaceClusters({int? minCount}) async {
    final query = <String, String>{
      if (minCount != null) 'minCount': '$minCount',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/faces/clusters', query), headers: await _headers());
    return PhotoFaceClusterList.fromJson(_asMap(_decode(res)));
  }

  /// 某个人脸簇下的照片
  Future<PhotoFaceList> photoFaces({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/faces', query), headers: await _headers());
    return PhotoFaceList.fromJson(_asMap(_decode(res)));
  }

  /// 人脸裁剪图（JPEG；无 bbox 的老数据回退整图缩略图）
  Future<Map<String, dynamic>> photoFaceImage({required String id, int? size}) async {
    final query = <String, String>{
      'id': id,
      if (size != null) 'size': '$size',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/face/image', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 只补人脸框（不重算场景/嵌入，保留簇归属）
  Future<PhotoFaceBackfillResponse> photoFaceBackfill({required PhotoFaceBackfillBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/backfill'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFaceBackfillResponse.fromJson(_asMap(_decode(res)));
  }

  /// 解散人脸簇（脸放回未分组，不删数据）
  Future<PhotoFaceOk> photoFaceDissolve({required PhotoFaceDissolveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/dissolve'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFaceOk.fromJson(_asMap(_decode(res)));
  }

  /// 给人脸簇命名（空串 = 取消命名）
  Future<PhotoFaceOk> photoFaceName({required PhotoFaceNameBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/name'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFaceOk.fromJson(_asMap(_decode(res)));
  }

  /// 把一个人脸簇并入另一个（from → to）
  Future<PhotoFaceMergeResponse> photoFaceMerge({required PhotoFaceMergeBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/merge'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFaceMergeResponse.fromJson(_asMap(_decode(res)));
  }

  /// 把单张人脸移到另一个簇（toClusterId=null 表示移出成未分组）
  Future<PhotoFaceMoveResponse> photoFaceMove({required PhotoFaceMoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/move'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFaceMoveResponse.fromJson(_asMap(_decode(res)));
  }

  /// 跨照片二次合并的候选簇对（只读，逐对确认后调 /faces/merge）
  Future<PhotoFaceMergeCandidateList> photoFaceMergeCandidates({required PhotoFaceMergeCandidateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/merge-candidates'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFaceMergeCandidateList.fromJson(_asMap(_decode(res)));
  }

  /// 撤消人脸合并（按审计记录还原被并掉的簇与成员）
  Future<PhotoFaceMergeUndoResponse> photoFaceMergeUndo({required PhotoFaceMergeUndoBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/merge-undo'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFaceMergeUndoResponse.fromJson(_asMap(_decode(res)));
  }

  /// 全库重算人脸簇（先快照，可用 rollback 还原）
  Future<PhotoFaceRebuildResponse> photoFaceRebuild({required PhotoFaceRebuildBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/rebuild'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFaceRebuildResponse.fromJson(_asMap(_decode(res)));
  }

  /// 回滚一次全库重建
  Future<PhotoFaceOk> photoFaceRollback({required PhotoFaceRollbackBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/rollback'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFaceOk.fromJson(_asMap(_decode(res)));
  }

  /// 语义查询解析：中文短语 → 场景标签（含未识别片段，便于提示）
  Future<PhotoSemanticParse> photoSemanticParse({required String q}) async {
    final query = <String, String>{
      'q': q,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/semantic/parse', query), headers: await _headers());
    return PhotoSemanticParse.fromJson(_asMap(_decode(res)));
  }

  /// 语义搜索：短语绑定标签（有序）+ OCR 文本融合；词表不可用时降级为文字搜索
  Future<PhotoSemanticSearchResponse> photoSemanticSearch({required String q}) async {
    final query = <String, String>{
      'q': q,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/semantic/search', query), headers: await _headers());
    return PhotoSemanticSearchResponse.fromJson(_asMap(_decode(res)));
  }

  /// AI 设置（配置 / 进度 / 任务队列）
  Future<PhotoAiSettings> photoAiConfig() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/ai/config'), headers: await _headers());
    return PhotoAiSettings.fromJson(_asMap(_decode(res)));
  }

  /// 保存 AI 设置（部分字段）
  Future<PhotoAiConfig> photoAiConfigSet({required PhotoAiConfigBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/config'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiConfig.fromJson(_asMap(_decode(res)));
  }

  /// 暂停 / 恢复 AI 任务队列
  Future<PhotoAiConfig> photoAiQueuePause({required PhotoAiQueuePauseBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/queue/pause'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiConfig.fromJson(_asMap(_decode(res)));
  }

  /// 清空某一类识别结果（OCR / 场景 / 活动 / 去重）
  Future<PhotoAiOpResponse> photoAiReset({required PhotoAiResetBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/reset'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiOpResponse.fromJson(_asMap(_decode(res)));
  }

  /// 保存人脸聚类参数（认人严格度 / 参考数 / 线程数）
  Future<PhotoAiTuningResponse> photoFaceTuning({required PhotoAiTuningBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/tuning'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiTuningResponse.fromJson(_asMap(_decode(res)));
  }

  /// 补齐漏检：对已分析但没有检出人脸的照片重新检测
  Future<PhotoAiOpResponse> photoFaceRescanMissing({required PhotoFaceRescanBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/rescan-missing'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiOpResponse.fromJson(_asMap(_decode(res)));
  }

  /// 自动合并相似人物（同框冲突跳过）
  Future<PhotoAiOpResponse> photoFaceMergeSimilar({required PhotoFaceMergeSimilarBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/merge-similar'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiOpResponse.fromJson(_asMap(_decode(res)));
  }

  /// 全部重新识别人脸（清空现有聚类与人脸记录）
  Future<PhotoAiOpResponse> photoFaceResetAll() async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/reset'), headers: await _headers());
    return PhotoAiOpResponse.fromJson(_asMap(_decode(res)));
  }

  /// 清理误检人脸（低分 / 无归属）
  Future<PhotoAiOpResponse> photoFacePurge() async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/purge'), headers: await _headers());
    return PhotoAiOpResponse.fromJson(_asMap(_decode(res)));
  }

  /// MCP 开放平台状态
  Future<PhotoMcpStatus> photoMcpStatus() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/ai/mcp/status'), headers: await _headers());
    return PhotoMcpStatus.fromJson(_asMap(_decode(res)));
  }

  /// 保存 MCP 配置（开关 / 挂载用户）
  Future<PhotoMcpStatus> photoMcpConfigSet({required PhotoMcpConfigBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/mcp/config'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoMcpStatus.fromJson(_asMap(_decode(res)));
  }

  /// 轮换 MCP 访问令牌（明文只返回一次）
  Future<PhotoMcpTokenResponse> photoMcpTokenRotate() async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/mcp/token/rotate'), headers: await _headers());
    return PhotoMcpTokenResponse.fromJson(_asMap(_decode(res)));
  }

  /// 可视范围内的 geohash 格代表点（客户端按世界像素聚簇）
  Future<PhotoMapBoundsResponse> photoMapBounds({required double minLat, required double minLng, required double maxLat, required double maxLng, double? zoom, int? limit, String? libraryId}) async {
    final query = <String, String>{
      'minLat': '$minLat',
      'minLng': '$minLng',
      'maxLat': '$maxLat',
      'maxLng': '$maxLng',
      if (zoom != null) 'zoom': '$zoom',
      if (limit != null) 'limit': '$limit',
      if (libraryId != null) 'libraryId': libraryId,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/map/bounds', query), headers: await _headers());
    return PhotoMapBoundsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 行程连线（有 GPS 的照片按拍摄时间串成若干段）
  Future<PhotoMapJourneyResponse> photoMapJourney({int? from, int? to, String? libraryId, int? gapHours, int? maxPoints}) async {
    final query = <String, String>{
      if (from != null) 'from': '$from',
      if (to != null) 'to': '$to',
      if (libraryId != null) 'libraryId': libraryId,
      if (gapHours != null) 'gapHours': '$gapHours',
      if (maxPoints != null) 'maxPoints': '$maxPoints',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/map/journey', query), headers: await _headers());
    return PhotoMapJourneyResponse.fromJson(_asMap(_decode(res)));
  }

  /// 点开一个簇：按格集合精确取回照片（total 与角标同源）
  Future<PhotoMapCellsResponse> photoMapCells({required String keys, required int precision, int? limit, String? cursor}) async {
    final query = <String, String>{
      'keys': keys,
      'precision': '$precision',
      if (limit != null) 'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/map/cells', query), headers: await _headers());
    return PhotoMapCellsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 按真实距离取最近地名（30km 闸门，单语言）
  Future<PhotoMapPlaceResponse> photoMapPlace({required String geohash, double? lat, double? lng, String? locale}) async {
    final query = <String, String>{
      'geohash': geohash,
      if (lat != null) 'lat': '$lat',
      if (lng != null) 'lng': '$lng',
      if (locale != null) 'locale': locale,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/map/place', query), headers: await _headers());
    return PhotoMapPlaceResponse.fromJson(_asMap(_decode(res)));
  }

  /// 可用底图源（默认 + 自定义）
  Future<PhotoMapTileServerList> photoMapTileServers() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/map/tile-servers'), headers: await _headers());
    return PhotoMapTileServerList.fromJson(_asMap(_decode(res)));
  }

  /// 切换底图源（内置或自定义 URL 模板）
  Future<PhotoMapTileServer> photoMapTileServerSet({required PhotoMapTileServerBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/map/tile-servers/current'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoMapTileServer.fromJson(_asMap(_decode(res)));
  }

  /// 搜索联想（人物/场景/活动/相机/文件名/OCR/年份，计数按可见库重算）
  Future<Map<String, dynamic>> photoSearchSuggest({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/search/suggest'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 人物关系图：同框共现边 + 证据张数
  Future<Map<String, dynamic>> photoFaceRelations({String? limit}) async {
    final query = <String, String>{
      if (limit != null) 'limit': limit,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/faces/relations', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 批量删除预演（只读：张数与占用字节）
  Future<Map<String, dynamic>> photoTrashPreview({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/trash/preview'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 执行批量删除（写入操作日志，可撤销）
  Future<Map<String, dynamic>> photoTrashApply({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/trash/apply'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 撤销一次操作（重复撤销返回 409）
  Future<Map<String, dynamic>> photoOperationUndo({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/operation/undo'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 最近的可撤销操作（当前用户）
  Future<Map<String, dynamic>> photoOperationRecent({String? limit}) async {
    final query = <String, String>{
      if (limit != null) 'limit': limit,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/operation/recent', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 人脸重扫预演：只算差异，不写库
  Future<Map<String, dynamic>> photoFaceRescanPreview() async {
    final res = await transport.send('POST', _uri('/api/v1/photo/faces/rescan/preview'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 单张重新识别：face / place / ocr / activity 分项清除，等下一轮 analyze 重算
  Future<Map<String, dynamic>> photoAiRerun({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/ai/rerun'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 清理预演：内容重复 / 同名同大小 / 相似（只读，不改库）
  Future<PhotoCleanupPreviewResponse> photoCleanupPreview({required PhotoCleanupPreviewBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/cleanup/preview'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoCleanupPreviewResponse.fromJson(_asMap(_decode(res)));
  }

  /// 执行清理（移入回收站，可按批次撤销）
  Future<PhotoCleanupApplyResponse> photoCleanupApply({required PhotoCleanupApplyBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/cleanup/apply'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoCleanupApplyResponse.fromJson(_asMap(_decode(res)));
  }

  /// 撤销一个清理批次（恢复回收站状态）
  Future<PhotoCleanupUndoResponse> photoCleanupUndo({required PhotoCleanupUndoBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/cleanup/undo'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoCleanupUndoResponse.fromJson(_asMap(_decode(res)));
  }

  /// 最近的清理批次
  Future<PhotoCleanupBatchList> photoCleanupBatches() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/cleanup/batches'), headers: await _headers());
    return PhotoCleanupBatchList.fromJson(_asMap(_decode(res)));
  }

  /// 补齐候选照片的 content_md5（只算 size 撞车的那批）
  Future<PhotoCleanupBackfillResponse> photoCleanupBackfillMd5({required PhotoCleanupBackfillBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/cleanup/md5'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoCleanupBackfillResponse.fromJson(_asMap(_decode(res)));
  }

  /// 回收站（清理与删除的照片）
  Future<Map<String, dynamic>> photoTrashList({int? limit, String? cursor, String? batchId}) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
      if (batchId != null) 'batchId': batchId,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/trash', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 回收站按删除批次分组
  Future<Map<String, dynamic>> photoTrashBatches() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/trash/batches'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 从回收站恢复
  Future<PhotoCleanupUndoResponse> photoTrashRestore({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/trash/restore'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return PhotoCleanupUndoResponse.fromJson(_asMap(_decode(res)));
  }

  /// 清空回收站（只删索引，不动磁盘文件）；传 batchId 只清一个批次
  Future<PhotoCleanupOk> photoTrashEmpty({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/trash/empty'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return PhotoCleanupOk.fromJson(_asMap(_decode(res)));
  }

  /// 一日一帧：每天挑一张代表作（配当日标签与地点）
  Future<PhotoDayFrameList> photoDayFrames({int? days, String? locale}) async {
    final query = <String, String>{
      if (days != null) 'days': '$days',
      if (locale != null) 'locale': locale,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/memories/day-frames', query), headers: await _headers());
    return PhotoDayFrameList.fromJson(_asMap(_decode(res)));
  }

  /// 人生章节：按年成书，一页 = 一天（左页大图 + 精选，右页影像日记）
  Future<PhotoChapterBook> photoChapterBook({int? year, String? locale, int? limitDays}) async {
    final query = <String, String>{
      if (year != null) 'year': '$year',
      if (locale != null) 'locale': locale,
      if (limitDays != null) 'limitDays': '$limitDays',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/memories/chapters', query), headers: await _headers());
    return PhotoChapterBook.fromJson(_asMap(_decode(res)));
  }

  /// 票夹：识别火车票 / 机票 / 门票，按行程归组
  Future<PhotoTicketResponse> photoTickets({int? limit}) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/memories/tickets', query), headers: await _headers());
    return PhotoTicketResponse.fromJson(_asMap(_decode(res)));
  }

  /// 年度记录：张数 / 地点 / 活跃人物 / 常用场景，地点可跨年对照
  Future<PhotoYearReport> photoYearReport({int? year, String? locale}) async {
    final query = <String, String>{
      if (year != null) 'year': '$year',
      if (locale != null) 'locale': locale,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/memories/year-report', query), headers: await _headers());
    return PhotoYearReport.fromJson(_asMap(_decode(res)));
  }

  /// 记忆：候选 / 已确认 / 已忽略 + 年度章节
  Future<PhotoMemoryList> photoMemories({int? days, int? minPhotos, int? limit}) async {
    final query = <String, String>{
      if (days != null) 'days': '$days',
      if (minPhotos != null) 'minPhotos': '$minPhotos',
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/memories', query), headers: await _headers());
    return PhotoMemoryList.fromJson(_asMap(_decode(res)));
  }

  /// 确认一条记忆（可带备注）
  Future<PhotoAiOpResponse> photoMemorySave({required PhotoMemorySaveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/memories/save'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiOpResponse.fromJson(_asMap(_decode(res)));
  }

  /// 忽略一条记忆候选
  Future<PhotoAiOpResponse> photoMemoryIgnore({required PhotoMemoryTargetBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/memories/ignore'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiOpResponse.fromJson(_asMap(_decode(res)));
  }

  /// 把忽略的记忆恢复为已确认
  Future<PhotoAiOpResponse> photoMemoryRestore({required PhotoMemoryTargetBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/memories/restore'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiOpResponse.fromJson(_asMap(_decode(res)));
  }

  /// 删除一条已确认记忆
  Future<PhotoAiOpResponse> photoMemoryRemove({required PhotoMemoryTargetBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/memories/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAiOpResponse.fromJson(_asMap(_decode(res)));
  }

  /// 备份前置比对：哪些文件库里已经有了（MD5 优先，其次同名同大小）
  Future<PhotoBackupCheckResponse> photoBackupCheck({required PhotoBackupCheckBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/backup/check'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoBackupCheckResponse.fromJson(_asMap(_decode(res)));
  }

  /// 登记一次备份结果
  Future<PhotoBackupCommitResponse> photoBackupCommit({required PhotoBackupCommitBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/backup/commit'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoBackupCommitResponse.fromJson(_asMap(_decode(res)));
  }

  /// 最近的备份记录
  Future<PhotoBackupStatusResponse> photoBackupStatus() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/backup/status'), headers: await _headers());
    return PhotoBackupStatusResponse.fromJson(_asMap(_decode(res)));
  }

  /// 相册库列表
  Future<PhotoLibraryListResponse> photoLibraryList() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/libraries'), headers: await _headers());
    return PhotoLibraryListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建相册库（目录须在 files 根内）
  Future<PhotoLibraryItem> photoLibraryCreate({required PhotoLibraryCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/libraries'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoLibraryItem.fromJson(_asMap(_decode(res)));
  }

  /// 设置当前用户相册库的来源目录
  Future<PhotoLibraryItem> photoLibraryUpdate({required PhotoLibraryUpdateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/libraries/update'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoLibraryItem.fromJson(_asMap(_decode(res)));
  }

  /// 删除相册库（级联清理索引与相册成员）
  Future<PhotoOkResponse> photoLibraryRemove({required PhotoLibraryRemoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/libraries/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 扫描索引（缺省扫描全部库；已索引且未变的文件跳过）
  Future<PhotoScanResponse> photoScan({required PhotoScanBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/scan'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoScanResponse.fromJson(_asMap(_decode(res)));
  }

  /// 扫描索引（入队，立即返回任务 id；同一时刻只跑一轮）
  Future<PhotoScanTask> photoScanTask({required PhotoScanBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/scan/task'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoScanTask.fromJson(_asMap(_decode(res)));
  }

  /// 本机盘符 / 根目录
  Future<PhotoFsRoots> photoFsRoots() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/fs/roots'), headers: await _headers());
    return PhotoFsRoots.fromJson(_asMap(_decode(res)));
  }

  /// 列出本机目录（选择来源目录）
  Future<PhotoFsList> photoFsList({String? path}) async {
    final query = <String, String>{
      if (path != null) 'path': path,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/fs/list', query), headers: await _headers());
    return PhotoFsList.fromJson(_asMap(_decode(res)));
  }

  /// 时间轴（taken_at 倒序，排序键 cursor）
  Future<PhotoTimelineResponse> photoTimeline({String? libraryId, bool? favorite, String? folder, dynamic order, String? cursor, int? limit}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (favorite != null) 'favorite': favorite.toString(),
      if (folder != null) 'folder': folder,
      if (order != null) 'order': order,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/timeline', query), headers: await _headers());
    return PhotoTimelineResponse.fromJson(_asMap(_decode(res)));
  }

  /// 批量收藏 / 取消收藏
  Future<PhotoFavoriteResponse> photoFavoriteSet({required PhotoFavoriteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/favorite'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFavoriteResponse.fromJson(_asMap(_decode(res)));
  }

  /// 单张照片详情
  Future<PhotoItem> photoItem({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/item', query), headers: await _headers());
    return PhotoItem.fromJson(_asMap(_decode(res)));
  }

  /// 照片属性与 EXIF（按需解析文件头；无 EXIF 字段返回 null）
  Future<Map<String, dynamic>> photoExif({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/exif', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 按路径关键词与时间范围搜索
  Future<PhotoTimelineResponse> photoSearch({String? q, int? from, int? to, String? libraryId, String? folder, dynamic order, String? cursor, int? limit}) async {
    final query = <String, String>{
      if (q != null) 'q': q,
      if (from != null) 'from': '$from',
      if (to != null) 'to': '$to',
      if (libraryId != null) 'libraryId': libraryId,
      if (folder != null) 'folder': folder,
      if (order != null) 'order': order,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/search', query), headers: await _headers());
    return PhotoTimelineResponse.fromJson(_asMap(_decode(res)));
  }

  /// 混合检索：场景/活动标签 + OCR + 路径，按相关度排序（offset 分页）
  Future<PhotoHybridSearchResponse> photoSearchHybrid({required String q, int? offset, int? limit}) async {
    final query = <String, String>{
      'q': q,
      if (offset != null) 'offset': '$offset',
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/search/hybrid', query), headers: await _headers());
    return PhotoHybridSearchResponse.fromJson(_asMap(_decode(res)));
  }

  /// 总量与时间跨度
  Future<PhotoStatsResponse> photoStats() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/stats'), headers: await _headers());
    return PhotoStatsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 某年各月的张数与封面（年视图下钻）
  Future<PhotoCalendarResponse> photoCalendar({int? year}) async {
    final query = <String, String>{
      if (year != null) 'year': '$year',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/calendar', query), headers: await _headers());
    return PhotoCalendarResponse.fromJson(_asMap(_decode(res)));
  }

  /// 每年一张「有人像」的代表图（年视图卡片封面）
  Future<PhotoYearCoversResponse> photoYearCovers() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/year-covers'), headers: await _headers());
    return PhotoYearCoversResponse.fromJson(_asMap(_decode(res)));
  }

  /// 文件视图：按目录聚合照片
  Future<PhotoFolderList> photoFolders({String? path}) async {
    final query = <String, String>{
      if (path != null) 'path': path,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/folders', query), headers: await _headers());
    return PhotoFolderList.fromJson(_asMap(_decode(res)));
  }

  /// 文件视图根：当前用户的相册来源目录
  Future<PhotoFolderRoots> photoFolderRoots() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/folders/roots'), headers: await _headers());
    return PhotoFolderRoots.fromJson(_asMap(_decode(res)));
  }

  /// 模型目录（只读）
  Future<PhotoModelList> photoModels() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/ai/models'), headers: await _headers());
    return PhotoModelList.fromJson(_asMap(_decode(res)));
  }

  /// 当前用户的相册列表
  Future<PhotoAlbumListResponse> photoAlbumList() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/albums'), headers: await _headers());
    return PhotoAlbumListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建相册（可按 id 批量加入）
  Future<PhotoAlbum> photoAlbumCreate({required PhotoAlbumCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/albums'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAlbum.fromJson(_asMap(_decode(res)));
  }

  /// 编辑相册（名称 / 简介 / 封面 / 排序）
  Future<PhotoAlbum> photoAlbumUpdate({required PhotoAlbumUpdateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/albums/update'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoAlbum.fromJson(_asMap(_decode(res)));
  }

  /// 相册成员（时间轴序）
  Future<PhotoTimelineResponse> photoAlbumItems({required String albumId, String? cursor, int? limit}) async {
    final query = <String, String>{
      'albumId': albumId,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/albums/items', query), headers: await _headers());
    return PhotoTimelineResponse.fromJson(_asMap(_decode(res)));
  }

  /// 向相册加入照片
  Future<PhotoOkResponse> photoAlbumAdd({required PhotoAlbumMembersBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/albums/add'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 从相册移出照片
  Future<PhotoOkResponse> photoAlbumRemove({required PhotoAlbumMembersBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/albums/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 删除相册
  Future<PhotoOkResponse> photoAlbumDelete({required PhotoAlbumDeleteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/albums/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 集合列表
  Future<PhotoCollectionListResponse> photoCollectionList() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/collections'), headers: await _headers());
    return PhotoCollectionListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建集合
  Future<PhotoCollection> photoCollectionCreate({required PhotoCollectionCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/collections'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoCollection.fromJson(_asMap(_decode(res)));
  }

  /// 删除集合（只删集合关系，不动照片）
  Future<PhotoOkResponse> photoCollectionDelete({required PhotoCollectionDeleteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/collections/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 把照片加入集合
  Future<PhotoOkResponse> photoCollectionAdd({required PhotoCollectionMembersBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/collections/add'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 把照片移出集合
  Future<PhotoOkResponse> photoCollectionRemove({required PhotoCollectionMembersBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/collections/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 集合里的照片（按加入时间倒序）
  Future<PhotoTimelineResponse> photoCollectionItems({required String collectionId, String? cursor, int? limit}) async {
    final query = <String, String>{
      'collectionId': collectionId,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/collections/items', query), headers: await _headers());
    return PhotoTimelineResponse.fromJson(_asMap(_decode(res)));
  }

  /// 智能规则列表（含命中张数与封面）
  Future<PhotoSmartRuleListResponse> photoSmartRuleList() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/smart-rules'), headers: await _headers());
    return PhotoSmartRuleListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建智能规则
  Future<PhotoSmartRule> photoSmartRuleCreate({required PhotoSmartRuleCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/smart-rules'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoSmartRule.fromJson(_asMap(_decode(res)));
  }

  /// 修改智能规则（改名 / 改条件）
  Future<PhotoSmartRule> photoSmartRuleUpdate({required PhotoSmartRuleUpdateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/smart-rules/update'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoSmartRule.fromJson(_asMap(_decode(res)));
  }

  /// 删除智能规则（只删规则，不动照片）
  Future<PhotoOkResponse> photoSmartRuleDelete({required PhotoSmartRuleDeleteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/smart-rules/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 智能规则命中的照片（时间轴序）
  Future<PhotoTimelineResponse> photoSmartRuleItems({required String id, String? cursor, int? limit}) async {
    final query = <String, String>{
      'id': id,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/smart-rules/items', query), headers: await _headers());
    return PhotoTimelineResponse.fromJson(_asMap(_decode(res)));
  }

  /// 按条件组合筛选照片（与智能规则同一套判据，不落库）
  Future<PhotoFilterResponse> photoFilter({required PhotoFilterBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/filter'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoFilterResponse.fromJson(_asMap(_decode(res)));
  }

  /// 缺 GPS 的照片
  Future<PhotoTimelineResponse> photoGeoMissing({int? limit, String? cursor}) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/geo/missing', query), headers: await _headers());
    return PhotoTimelineResponse.fromJson(_asMap(_decode(res)));
  }

  /// 给照片补经纬度（同时物化 geohash）
  Future<PhotoGeoSetResponse> photoGeoSet({required PhotoGeoSetBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/geo/set'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoGeoSetResponse.fromJson(_asMap(_decode(res)));
  }

  /// 最近带 GPS 的照片（GPS 补全的参考图）
  Future<PhotoGeoReferenceList> photoGeoReferences({int? limit, String? cursor}) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/geo/references', query), headers: await _headers());
    return PhotoGeoReferenceList.fromJson(_asMap(_decode(res)));
  }

  /// GPS 视觉候选生成进度
  Future<PhotoGeoVisionStatus> photoGeoVisionStatus() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/geo/vision/status'), headers: await _headers());
    return PhotoGeoVisionStatus.fromJson(_asMap(_decode(res)));
  }

  /// GPS 视觉候选（相似照片的坐标作为锚点）
  Future<PhotoGeoVisionList> photoGeoVisionCandidates({int? limit, String? cursor}) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/geo/vision/candidates', query), headers: await _headers());
    return PhotoGeoVisionList.fromJson(_asMap(_decode(res)));
  }

  /// 开始生成 GPS 视觉候选（CLIP 最近邻）
  Future<PhotoGeoVisionStatus> photoGeoVisionScan() async {
    final res = await transport.send('POST', _uri('/api/v1/photo/geo/vision/scan'), headers: await _headers());
    return PhotoGeoVisionStatus.fromJson(_asMap(_decode(res)));
  }

  /// 确认视觉候选：写入坐标（可微调）
  Future<PhotoGeoSetResponse> photoGeoVisionApply({required PhotoGeoVisionApplyBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/geo/vision/apply'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoGeoSetResponse.fromJson(_asMap(_decode(res)));
  }

  /// 忽略一个 GPS 视觉候选
  Future<PhotoGeoSetResponse> photoGeoVisionReject({required PhotoGeoVisionRejectBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/geo/vision/reject'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoGeoSetResponse.fromJson(_asMap(_decode(res)));
  }

  /// 相册首页看板（统计 / 足迹 / 人物 / 那年今日）
  Future<PhotoHomeSummary> photoHomeSummary() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/home/summary'), headers: await _headers());
    return PhotoHomeSummary.fromJson(_asMap(_decode(res)));
  }

  /// 那年今日：所有年份同月同日的照片（按年分组）
  Future<PhotoOnThisDayResponse> photoOnThisDay({int? month, int? day, int? perYear}) async {
    final query = <String, String>{
      if (month != null) 'month': '$month',
      if (day != null) 'day': '$day',
      if (perYear != null) 'perYear': '$perYear',
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/on-this-day', query), headers: await _headers());
    return PhotoOnThisDayResponse.fromJson(_asMap(_decode(res)));
  }

  /// getApiMcp
  Future<Map<String, dynamic>> getApiMcp() async {
    final res = await transport.send('GET', _uri('/api/mcp'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// postApiMcp
  Future<Map<String, dynamic>> postApiMcp() async {
    final res = await transport.send('POST', _uri('/api/mcp'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 相似照片感知哈希扫描进度
  Future<PhotoPhashStatus> photoPhashStatus() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/cleanup/phash/status'), headers: await _headers());
    return PhotoPhashStatus.fromJson(_asMap(_decode(res)));
  }

  /// 开始相似照片扫描（pHash 扫描 → 比对）
  Future<PhotoPhashScanResponse> photoPhashScan() async {
    final res = await transport.send('POST', _uri('/api/v1/photo/cleanup/phash/scan'), headers: await _headers());
    return PhotoPhashScanResponse.fromJson(_asMap(_decode(res)));
  }

  /// 相册扫描策略（自动监视 / 周期校验 / 跳过隐藏文件）
  Future<PhotoScanPolicy> photoScanPolicy() async {
    final res = await transport.send('GET', _uri('/api/v1/photo/scan-policy'), headers: await _headers());
    return PhotoScanPolicy.fromJson(_asMap(_decode(res)));
  }

  /// 更新相册扫描策略（立即生效）
  Future<PhotoScanPolicy> photoScanPolicySet({required PhotoScanPolicyUpdateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/scan-policy'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoScanPolicy.fromJson(_asMap(_decode(res)));
  }

  /// 上传照片到相册来源（application/x-colanas-upload 原始流）
  Future<Map<String, dynamic>> photoUpload({required String libraryId, String? dir, required String fileName, required Map<String, dynamic> body}) async {
    final query = <String, String>{
      'libraryId': libraryId,
      if (dir != null) 'dir': dir,
      'fileName': fileName,
    };
    final res = await transport.send('POST', _uri('/api/v1/photo/upload', query), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 底图瓦片（本地缓存代理，30 天）
  Future<Map<String, dynamic>> photoMapTile({required int z, required int x, required int y, String? server}) async {
    final query = <String, String>{
      'z': '$z',
      'x': '$x',
      'y': '$y',
      if (server != null) 'server': server,
    };
    final res = await transport.send('GET', _uri('/api/v1/photo/map/tile', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 批量删除（可选放入回收站）
  Future<PhotoDeleteResponse> photoDelete({required PhotoDeleteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/photo/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PhotoDeleteResponse.fromJson(_asMap(_decode(res)));
  }

  /// PT 站点列表（不返回 cookie 明文）
  Future<Map<String, dynamic>> ptSiteList() async {
    final res = await transport.send('GET', _uri('/api/v1/pt/sites'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 新增 / 更新 PT 站点（cookie 密文落库）
  Future<Map<String, dynamic>> ptSiteUpsert({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/pt/sites/upsert'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 删除站点
  Future<Map<String, dynamic>> ptSiteDelete({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/pt/sites/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 按媒体信息搜索所有启用站点（串行）
  Future<Map<String, dynamic>> ptSearch({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/pt/search'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 我的订阅
  Future<Map<String, dynamic>> ptSubscriptionList() async {
    final res = await transport.send('GET', _uri('/api/v1/pt/subscriptions'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 新增 / 更新订阅
  Future<Map<String, dynamic>> ptSubscriptionUpsert({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/pt/subscriptions/upsert'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 删除订阅
  Future<Map<String, dynamic>> ptSubscriptionDelete({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/pt/subscriptions/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 立即执行一条订阅
  Future<Map<String, dynamic>> ptSubscriptionRun({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/pt/subscriptions/run'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 下载留痕（最近 200 条）
  Future<Map<String, dynamic>> ptDownloads() async {
    final res = await transport.send('GET', _uri('/api/v1/pt/downloads'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 暂停 / 恢复 / 移除下载任务（移除不删本地数据）
  Future<Map<String, dynamic>> ptDownloadAction({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/pt/downloads/action'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 下载目录与筛选设置（发现设置页）
  Future<PtDownloadSettingsResponse> ptDownloadSettingsGet() async {
    final res = await transport.send('GET', _uri('/api/v1/pt/download/settings'), headers: await _headers());
    return PtDownloadSettingsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 保存下载目录与筛选（自动下载 / 扫描间隔立即生效）
  Future<PtDownloadSettingsResponse> ptDownloadSettingsSet({required PtDownloadSettingsBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/pt/download/settings'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PtDownloadSettingsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 设置 transmission（url / 账号）
  Future<Map<String, dynamic>> ptSettingsSet({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/pt/settings'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 探测 transmission 连通性
  Future<Map<String, dynamic>> ptTransmissionTest() async {
    final res = await transport.send('POST', _uri('/api/v1/pt/transmission/test'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 订阅列表
  Future<Map<String, dynamic>> rssListFeeds() async {
    final res = await transport.send('GET', _uri('/api/v1/rss/feeds'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 添加订阅（url 或直接给 xml）
  Future<Map<String, dynamic>> rssAddFeed({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/rss/feeds'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 刷新订阅（抓取 url 或解析传入 xml）
  Future<Map<String, dynamic>> rssRefresh({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/rss/feeds/refresh'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 条目列表（发布时间倒序）
  Future<Map<String, dynamic>> rssItems({String? feedId, int? limit}) async {
    final query = <String, String>{
      if (feedId != null) 'feedId': feedId,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/rss/items', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 取消订阅（级联删条目）
  Future<Map<String, dynamic>> rssRemoveFeed({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/rss/feeds/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// RSS 自动下载规则（按账号隔离）
  Future<Map<String, dynamic>> rssRuleList() async {
    final res = await transport.send('GET', _uri('/api/v1/rss/rules'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 新增 / 编辑 RSS 自动下载规则
  Future<Map<String, dynamic>> rssRuleUpsert({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/rss/rules/upsert'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 删除 RSS 自动下载规则
  Future<Map<String, dynamic>> rssRuleDelete({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/rss/rules/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 立即扫描一条规则（命中后自动建 PT 订阅）
  Future<Map<String, dynamic>> rssRuleRun({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/rss/rules/run'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 备份一个目录（逐文件 sha256 清单）
  Future<Map<String, dynamic>> backupRun({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/backup/run'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 列出备份
  Future<Map<String, dynamic>> backupList() async {
    final res = await transport.send('GET', _uri('/api/v1/backup/list'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 从备份恢复（先校验 sha256）
  Future<Map<String, dynamic>> backupRestore({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/backup/restore'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 创建加密空间
  Future<Map<String, dynamic>> vaultCreate({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/vault/create'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 写入一个文件（AES-256-GCM）
  Future<Map<String, dynamic>> vaultPut({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/vault/put'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 读取并解密一个文件
  Future<Map<String, dynamic>> vaultGet({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/vault/get'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 列出加密空间条目
  Future<Map<String, dynamic>> vaultList({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/vault/list'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 解密导出到 files 根内的目录（保留相对路径）
  Future<Map<String, dynamic>> vaultExport({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/vault/export'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 删除加密空间条目
  Future<Map<String, dynamic>> vaultDelete({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/vault/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 创建分享链接（可选过期与密码）
  Future<Map<String, dynamic>> shareCreate({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/share/create'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 列出分享链接
  Future<Map<String, dynamic>> shareList() async {
    final res = await transport.send('GET', _uri('/api/v1/share/list'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 撤销分享链接
  Future<Map<String, dynamic>> shareRevoke({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/share/revoke'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 查看分享链接信息（公开）
  Future<Map<String, dynamic>> shareInfo({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/share/info', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 通过分享链接下载（公开，支持 Range）
  Future<Map<String, dynamic>> shareDownload({required String id, String? password}) async {
    final query = <String, String>{
      'id': id,
      if (password != null) 'password': password,
    };
    final res = await transport.send('GET', _uri('/api/v1/share/download', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 差异预览（只读）
  Future<Map<String, dynamic>> syncDiff({required String source, required String target}) async {
    final query = <String, String>{
      'source': source,
      'target': target,
    };
    final res = await transport.send('GET', _uri('/api/v1/sync/diff', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 执行一次同步（merge，不删除目标多余文件）
  Future<Map<String, dynamic>> syncRun({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/run'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 同步任务历史
  Future<Map<String, dynamic>> syncJobs() async {
    final res = await transport.send('GET', _uri('/api/v1/sync/jobs'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 冲突列表
  Future<Map<String, dynamic>> syncConflicts({String? jobId}) async {
    final query = <String, String>{
      if (jobId != null) 'jobId': jobId,
    };
    final res = await transport.send('GET', _uri('/api/v1/sync/conflicts', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 冲突裁决：source 用源覆盖目标，target 保留目标
  Future<Map<String, dynamic>> syncResolve({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/conflicts/resolve'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 创建 / 更新同步任务（目录都在 files 根内）
  Future<Map<String, dynamic>> syncTaskUpsert({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/tasks/upsert'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 同步任务列表（当前用户）
  Future<Map<String, dynamic>> syncTaskList() async {
    final res = await transport.send('GET', _uri('/api/v1/sync/tasks'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 删除同步任务（保留基线以备审计，不删远端文件）
  Future<Map<String, dynamic>> syncTaskDelete({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/tasks/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 三向比对：返回本轮要执行的动作（只读，不改文件）
  Future<Map<String, dynamic>> syncPlan({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/plan'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 上报执行结果：刷新远端基线并落一次运行记录
  Future<Map<String, dynamic>> syncReport({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/report'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 同步运行记录
  Future<Map<String, dynamic>> syncRuns({String? taskId, String? limit}) async {
    final query = <String, String>{
      if (taskId != null) 'taskId': taskId,
      if (limit != null) 'limit': limit,
    };
    final res = await transport.send('GET', _uri('/api/v1/sync/runs', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 按相对路径删除远端文件（仅文件，不删目录）
  Future<Map<String, dynamic>> syncDeleteRemote({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/deleteRemote'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 在远端目录下创建子目录
  Future<Map<String, dynamic>> syncMkdir({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/mkdir'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 探测远端目录（存在 / 可写 / 是否越界）
  Future<Map<String, dynamic>> syncProbe({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/probe'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 同步任务汇总（按状态 / 设备）
  Future<Map<String, dynamic>> syncSummary() async {
    final res = await transport.send('POST', _uri('/api/v1/sync/summary'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 客户端回写任务状态（idle / running / paused / error）
  Future<Map<String, dynamic>> syncStatus({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/status'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 认领升级前的无主任务（uid 为空的同设备任务）
  Future<Map<String, dynamic>> syncClaimLegacy({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/sync/device/claimLegacy'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 缓存命中统计（进程内累计，重启清零）
  Future<Map<String, dynamic>> systemCacheStats() async {
    final res = await transport.send('GET', _uri('/api/v1/system/cache/stats'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 整机监控（CPU / 内存 / 磁盘 / 负载）
  Future<Map<String, dynamic>> systemMonitor() async {
    final res = await transport.send('GET', _uri('/api/v1/system/monitor'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 进程列表
  Future<Map<String, dynamic>> systemProcesses({int? limit, String? filter}) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
      if (filter != null) 'filter': filter,
    };
    final res = await transport.send('GET', _uri('/api/v1/system/processes', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 受限命令执行（白名单 + 无 shell + 5 s 超时）
  Future<Map<String, dynamic>> systemExec({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/system/exec'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 终止进程（拒绝 pid<=4 与自身）
  Future<Map<String, dynamic>> systemProcessKill({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/system/processes/kill'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 全局设置（端口 / 并发 / 主机名 / 欢迎语 / 代理 / 日系兜底）
  Future<SystemSettingsResponse> systemSettingsGet() async {
    final res = await transport.send('GET', _uri('/api/v1/system/settings'), headers: await _headers());
    return SystemSettingsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 保存全局设置（端口/并发重启后生效；代理立即生效）
  Future<SystemSettingsResponse> systemSettingsSet({required SystemSettingsBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/system/settings'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return SystemSettingsResponse.fromJson(_asMap(_decode(res)));
  }

  /// HTTPS 证书状态（用户上传证书方案）
  Future<SystemTlsInfoResponse> systemTlsInfo() async {
    final res = await transport.send('GET', _uri('/api/v1/system/tls'), headers: await _headers());
    return SystemTlsInfoResponse.fromJson(_asMap(_decode(res)));
  }

  /// 上传 HTTPS 证书与私钥（PEM；重启后启用）
  Future<SystemTlsInfoResponse> systemTlsUpload({required SystemTlsUploadBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/system/tls'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return SystemTlsInfoResponse.fromJson(_asMap(_decode(res)));
  }

  /// 删除已上传的 HTTPS 证书
  Future<SystemRestartResponse> systemTlsClear() async {
    final res = await transport.send('POST', _uri('/api/v1/system/tls/clear'), headers: await _headers());
    return SystemRestartResponse.fromJson(_asMap(_decode(res)));
  }

  /// 缓存占用（缩略图 / 封面 / PDF 渲染）
  Future<SystemCacheInfoResponse> systemCacheInfo() async {
    final res = await transport.send('GET', _uri('/api/v1/system/cache/info'), headers: await _headers());
    return SystemCacheInfoResponse.fromJson(_asMap(_decode(res)));
  }

  /// 清理缩略图 / 封面 / PDF 渲染缓存并清零命中计数（不动媒体库文件）
  Future<SystemCacheClearResponse> systemCacheClear() async {
    final res = await transport.send('POST', _uri('/api/v1/system/cache/clear'), headers: await _headers());
    return SystemCacheClearResponse.fromJson(_asMap(_decode(res)));
  }

  /// 数据库碎片整理（VACUUM，重写数据文件回收空洞空间）
  Future<SystemDbCompactResponse> systemDbCompact() async {
    final res = await transport.send('POST', _uri('/api/v1/system/db/compact'), headers: await _headers());
    return SystemDbCompactResponse.fromJson(_asMap(_decode(res)));
  }

  /// 重启内核（桌面端由外壳自动拉起；浏览器需手动刷新）
  Future<SystemRestartResponse> systemRestart() async {
    final res = await transport.send('POST', _uri('/api/v1/system/restart'), headers: await _headers());
    return SystemRestartResponse.fromJson(_asMap(_decode(res)));
  }

  /// 检查本地版本目录（当前版本 / 最新版本）
  Future<SystemUpdateCheckResponse> systemUpdateCheck() async {
    final res = await transport.send('GET', _uri('/api/v1/system/update/check'), headers: await _headers());
    return SystemUpdateCheckResponse.fromJson(_asMap(_decode(res)));
  }

  /// 服务端日志尾部（logs/kernel.log，按时间正序返回最后 N 行）
  Future<SystemLogsResponse> systemLogs({int? lines, String? file, dynamic level}) async {
    final query = <String, String>{
      if (lines != null) 'lines': '$lines',
      if (file != null) 'file': file,
      if (level != null) 'level': level,
    };
    final res = await transport.send('GET', _uri('/api/v1/system/logs', query), headers: await _headers());
    return SystemLogsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 上报一条客户端日志（前端错误 / 警告）
  Future<Map<String, dynamic>> systemClientLog({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/system/client-log'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 开关日本片自动字幕（打开时异步补一轮，不等下次扫描）
  Future<Map<String, dynamic>> videoAutoSubtitle({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/library/auto_subtitle'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 手动抓取一条日本片的字幕（avsubtitles 五步链路）
  Future<Map<String, dynamic>> videoSubtitleFetch({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/subtitle/fetch'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 演员档案（JavDB 确认身份 + 日文维基补三围；失败返回空档案）
  Future<Map<String, dynamic>> videoJpActorProfile({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/jp_actor/profile'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 演员列表（影片数 / 未看数 / 热度 / 封面片 / 收藏 / 档案）
  Future<Map<String, dynamic>> videoJpActorList({String? libraryId, String? limit}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (limit != null) 'limit': limit,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/jp_actor/list', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 收藏 / 取消收藏演员
  Future<Map<String, dynamic>> videoJpActorFavorite({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/jp_actor/favorite'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 我的演员收藏
  Future<Map<String, dynamic>> videoJpActorFavorites() async {
    final res = await transport.send('GET', _uri('/api/v1/video/jp_actor/favorites'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 某演员在库的作品（未看优先，再按入库时间倒序）
  Future<Map<String, dynamic>> videoJpActorWorks({String? key, String? name, String? limit}) async {
    final query = <String, String>{
      if (key != null) 'key': key,
      if (name != null) 'name': name,
      if (limit != null) 'limit': limit,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/jp_actor/works', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 从 nfo_actors 重建演员作品关联（老库补齐用）
  Future<Map<String, dynamic>> videoJpActorRebuild({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/jp_actor/rebuild'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 日本片榜单（日/周/月），标出已在库
  Future<Map<String, dynamic>> videoJpRankMovie({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/jp_rank/movie'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 日本演员榜单（日/周/月）
  Future<Map<String, dynamic>> videoJpRankActor({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/jp_rank/actor'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 清空日系榜单缓存（内存 + 快照）
  Future<Map<String, dynamic>> videoJpRankClear() async {
    final res = await transport.send('POST', _uri('/api/v1/video/jp_rank/clear'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 影视库列表（含全部来源）
  Future<VideoLibraryListResponse> videoLibraryList() async {
    final res = await transport.send('GET', _uri('/api/v1/video/libraries'), headers: await _headers());
    return VideoLibraryListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 新建影视库（可一次给多个来源目录）
  Future<VideoLibraryItem> videoLibraryCreate({required VideoLibraryCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/libraries'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoLibraryItem.fromJson(_asMap(_decode(res)));
  }

  /// 修改影视库（名称 / 类型 / 来源集合）
  Future<VideoLibraryItem> videoLibraryUpdate({required VideoLibraryUpdateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/libraries/update'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoLibraryItem.fromJson(_asMap(_decode(res)));
  }

  /// 修改库级开关（首页可见 / 排序 / 响度归一 / 刮削 / 入库即刮 / 自动字幕）
  Future<VideoLibraryItem> videoLibraryFlags({required VideoLibraryFlagsBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/libraries/flags'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoLibraryItem.fromJson(_asMap(_decode(res)));
  }

  /// 探测 SMB 来源可达性并刷新在线状态
  Future<VideoSourceProbeResponse> videoSourceProbe({required VideoSourceProbeBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/sources/probe'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoSourceProbeResponse.fromJson(_asMap(_decode(res)));
  }

  /// 删除影视库（级联清理索引与来源）
  Future<VideoOkResponse> videoLibraryRemove({required VideoLibraryRemoveBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/libraries/remove'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 入队扫描（立即返回任务 id；进度与失败记录见 /tasks）
  Future<Map<String, dynamic>> videoScanEnqueue({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/scan/enqueue'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 扫描索引（ffmpeg 提取元数据；未变文件跳过）
  Future<VideoScanResponse> videoScan({required VideoScanBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/scan'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoScanResponse.fromJson(_asMap(_decode(res)));
  }

  /// 刮削进度（每日快照，含按库明细；最新的在前）
  Future<Map<String, dynamic>> videoScrapeProgress({int? days}) async {
    final query = <String, String>{
      if (days != null) 'days': '$days',
    };
    final res = await transport.send('GET', _uri('/api/v1/video/scrape/progress', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 立即重算一次刮削进度（入队，不阻塞请求）
  Future<Map<String, dynamic>> videoScrapeProgressRefresh() async {
    final res = await transport.send('POST', _uri('/api/v1/video/scrape/progress/refresh'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 影片列表（标题序 + 排序键 cursor）
  Future<VideoListResponse> videoList({String? libraryId, String? q, String? mediaType, String? series, String? cursor, int? limit, String? sortBy, String? sortOrder, String? years, String? genres, String? regions, String? actor, String? director, String? watched, String? scraped, String? flag, String? folderPath, String? folderMode, String? letter}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (q != null) 'q': q,
      if (mediaType != null) 'mediaType': mediaType,
      if (series != null) 'series': series,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
      if (sortBy != null) 'sortBy': sortBy,
      if (sortOrder != null) 'sortOrder': sortOrder,
      if (years != null) 'years': years,
      if (genres != null) 'genres': genres,
      if (regions != null) 'regions': regions,
      if (actor != null) 'actor': actor,
      if (director != null) 'director': director,
      if (watched != null) 'watched': watched,
      if (scraped != null) 'scraped': scraped,
      if (flag != null) 'flag': flag,
      if (folderPath != null) 'folderPath': folderPath,
      if (folderMode != null) 'folderMode': folderMode,
      if (letter != null) 'letter': letter,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/list', query), headers: await _headers());
    return VideoListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 剧集列表（剧名序 + 排序键 cursor；只含能解析出季 / 集号的文件）
  Future<VideoSeriesListResponse> videoSeriesList({String? libraryId, String? q, String? cursor, int? limit}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (q != null) 'q': q,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/video/series', query), headers: await _headers());
    return VideoSeriesListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 某部剧的全部季 / 集（按季号、集号、标题排序）
  Future<VideoSeriesItemsResponse> videoSeriesItems({required String name, String? libraryId, int? limit}) async {
    final query = <String, String>{
      'name': name,
      if (libraryId != null) 'libraryId': libraryId,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/video/series/items', query), headers: await _headers());
    return VideoSeriesItemsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 影片详情
  Future<VideoItem> videoItem({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/item', query), headers: await _headers());
    return VideoItem.fromJson(_asMap(_decode(res)));
  }

  /// 当前用户在某条影片 / 剧集上的观看进度
  Future<VideoProgress> videoProgress({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/progress', query), headers: await _headers());
    return VideoProgress.fromJson(_asMap(_decode(res)));
  }

  /// 保存观看进度（0-100，按用户隔离）
  Future<VideoProgress> videoProgressSave({required VideoProgressBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/progress/save'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoProgress.fromJson(_asMap(_decode(res)));
  }

  /// 本用户的观看进度（按更新时间倒序；可按剧名 / 库过滤）
  Future<VideoProgressListResponse> videoProgressList({String? series, String? libraryId, dynamic state, int? limit}) async {
    final query = <String, String>{
      if (series != null) 'series': series,
      if (libraryId != null) 'libraryId': libraryId,
      if (state != null) 'state': state,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/video/progress/list', query), headers: await _headers());
    return VideoProgressListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 清空观看历史（可只清"已看完"，可按剧）
  Future<VideoProgressClearResponse> videoProgressClear({required VideoProgressClearBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/progress/clear'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoProgressClearResponse.fromJson(_asMap(_decode(res)));
  }

  /// 片数与总时长（可按库过滤，缺省为全部库合计）
  Future<VideoStatsResponse> videoStats({String? libraryId}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/stats', query), headers: await _headers());
    return VideoStatsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 条目数（总数 / 已刮削数），筛选口径与 /video/list 一致
  Future<VideoListCountResponse> videoListCount({String? libraryId, String? series, String? mediaType, String? q, String? folderPath, String? folderMode, String? letter}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (series != null) 'series': series,
      if (mediaType != null) 'mediaType': mediaType,
      if (q != null) 'q': q,
      if (folderPath != null) 'folderPath': folderPath,
      if (folderMode != null) 'folderMode': folderMode,
      if (letter != null) 'letter': letter,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/list/count', query), headers: await _headers());
    return VideoListCountResponse.fromJson(_asMap(_decode(res)));
  }

  /// 标记已观看 / 未观看（电视剧可一次展开到全部集）
  Future<VideoWatchResponse> videoWatchMark({required VideoWatchBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/watch'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoWatchResponse.fromJson(_asMap(_decode(res)));
  }

  /// 影视首页：来源 / 推荐 / 继续观看 / 每库最近添加
  Future<VideoHomeResponse> videoHome({int? recommendLimit, int? recentPlayLimit, int? recentAddLimit}) async {
    final query = <String, String>{
      if (recommendLimit != null) 'recommendLimit': '$recommendLimit',
      if (recentPlayLimit != null) 'recentPlayLimit': '$recentPlayLimit',
      if (recentAddLimit != null) 'recentAddLimit': '$recentAddLimit',
    };
    final res = await transport.send('GET', _uri('/api/v1/video/home', query), headers: await _headers());
    return VideoHomeResponse.fromJson(_asMap(_decode(res)));
  }

  /// 批量收藏 / 取消收藏
  Future<VideoFavoriteResponse> videoFavoriteSet({required VideoFavoriteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/favorites/set'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoFavoriteResponse.fromJson(_asMap(_decode(res)));
  }

  /// 我收藏的影片
  Future<VideoListResponse> videoFavorites({String? libraryId, String? q, String? mediaType, String? series, String? cursor, int? limit, String? sortBy, String? sortOrder, String? years, String? genres, String? regions, String? actor, String? director, String? watched, String? scraped, String? flag, String? folderPath, String? folderMode, String? letter}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (q != null) 'q': q,
      if (mediaType != null) 'mediaType': mediaType,
      if (series != null) 'series': series,
      if (cursor != null) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
      if (sortBy != null) 'sortBy': sortBy,
      if (sortOrder != null) 'sortOrder': sortOrder,
      if (years != null) 'years': years,
      if (genres != null) 'genres': genres,
      if (regions != null) 'regions': regions,
      if (actor != null) 'actor': actor,
      if (director != null) 'director': director,
      if (watched != null) 'watched': watched,
      if (scraped != null) 'scraped': scraped,
      if (flag != null) 'flag': flag,
      if (folderPath != null) 'folderPath': folderPath,
      if (folderMode != null) 'folderMode': folderMode,
      if (letter != null) 'letter': letter,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/favorites', query), headers: await _headers());
    return VideoListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 收藏 / 取消收藏一部剧
  Future<VideoSeriesFavoriteResponse> videoSeriesFavoriteSet({required VideoSeriesFavoriteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/series/favorites/set'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoSeriesFavoriteResponse.fromJson(_asMap(_decode(res)));
  }

  /// 我收藏的剧集（按最近收藏倒序）
  Future<VideoSeriesFavoriteListResponse> videoSeriesFavorites() async {
    final res = await transport.send('GET', _uri('/api/v1/video/series/favorites'), headers: await _headers());
    return VideoSeriesFavoriteListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 按演员名批量取头像与档案（详情页演职人员区用）
  Future<Map<String, dynamic>> videoActorAvatars({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/actor/avatars'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 影片海报（首次访问生成，之后走文件缓存）
  Future<Map<String, dynamic>> videoPoster({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/poster', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 源文件的音轨清单（语言 / 音轨名 / 声道），供播放器音轨菜单使用
  Future<VideoAudioTracksResponse> videoAudioTracks({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/audio-tracks', query), headers: await _headers());
    return VideoAudioTracksResponse.fromJson(_asMap(_decode(res)));
  }

  /// 生成带短期令牌的播放地址（可直接交给外部播放器）
  Future<VideoStreamUrlResponse> videoStreamUrl({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/stream-url', query), headers: await _headers());
    return VideoStreamUrlResponse.fromJson(_asMap(_decode(res)));
  }

  /// 外挂字幕列表（与影片同目录、同主名）
  Future<VideoSubtitleListResponse> videoSubtitles({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/subtitles', query), headers: await _headers());
    return VideoSubtitleListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 读取一条外挂字幕（srt / ass / ssa / vtt → WebVTT）
  Future<VideoSubtitleResponse> videoSubtitle({required String id, required String name}) async {
    final query = <String, String>{
      'id': id,
      'name': name,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/subtitle', query), headers: await _headers());
    return VideoSubtitleResponse.fromJson(_asMap(_decode(res)));
  }

  /// 播放 / 下载（支持 Range / ETag）
  Future<Map<String, dynamic>> videoStream({required String id, String? token}) async {
    final query = <String, String>{
      'id': id,
      if (token != null) 'token': token,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/stream', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 按库补全字幕（入队 video.subtitle.fetch）
  Future<Map<String, dynamic>> videoSubtitleFetchLibrary({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/subtitle/fetch-library'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 我的合集（按更新时间倒序，带条目数）
  Future<VideoCollectionListResponse> videoCollectionList() async {
    final res = await transport.send('GET', _uri('/api/v1/video/collections'), headers: await _headers());
    return VideoCollectionListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 创建 / 编辑合集（名称 / 简介 / 封面 / 顺序）
  Future<VideoCollection> videoCollectionUpsert({required VideoCollectionUpsertBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/collections/upsert'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoCollection.fromJson(_asMap(_decode(res)));
  }

  /// 删除合集（只删合集与其条目关系，不删影片）
  Future<VideoOkResponse> videoCollectionDelete({required VideoCollectionIdBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/collections/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 合并两个合集（来源的影片并入目标，来源合集被删除）
  Future<VideoCollection> videoCollectionMerge({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/collections/merge'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return VideoCollection.fromJson(_asMap(_decode(res)));
  }

  /// 合集内影片（按加入时间倒序）
  Future<VideoCollectionItemsResponse> videoCollectionItems({required String id}) async {
    final query = <String, String>{
      'id': id,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/collections/items', query), headers: await _headers());
    return VideoCollectionItemsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 批量加入 / 移出合集
  Future<VideoCollectionItemsResponse> videoCollectionItemsSet({required VideoCollectionItemsBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/collections/items'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoCollectionItemsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 按库目录浏览（文件夹 / 图片 / 视频）
  Future<VideoBrowseResponse> videoBrowse({required String libraryId, String? path}) async {
    final query = <String, String>{
      'libraryId': libraryId,
      if (path != null) 'path': path,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/browse', query), headers: await _headers());
    return VideoBrowseResponse.fromJson(_asMap(_decode(res)));
  }

  /// 重复视频（豆瓣 / IMDB / 番号 / 标题+年份 四把钥匙，并查集分组）
  Future<VideoDuplicatesResponse> videoDuplicates({String? libraryId, int? limit, String? excludeActors}) async {
    final query = <String, String>{
      if (libraryId != null) 'libraryId': libraryId,
      if (limit != null) 'limit': '$limit',
      if (excludeActors != null) 'excludeActors': excludeActors,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/duplicates', query), headers: await _headers());
    return VideoDuplicatesResponse.fromJson(_asMap(_decode(res)));
  }

  /// 演员候选（从 NFO 演员聚合，供查重页排除指定演员）
  Future<Map<String, dynamic>> videoActors({String? q, int? limit}) async {
    final query = <String, String>{
      if (q != null) 'q': q,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/video/actors', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 删除视频（移入回收站，并清掉索引 / 观看进度 / 收藏）
  Future<VideoDeleteItemsResponse> videoItemsDelete({required VideoDeleteItemsBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/items/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoDeleteItemsResponse.fromJson(_asMap(_decode(res)));
  }

  /// 删除视频（后台任务，返回 taskId，用 /tasks/:id 看进度）
  Future<Map<String, dynamic>> videoItemsDeleteTask({required VideoDeleteItemsBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/items/delete-task'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return _asMap(_decode(res));
  }

  /// 图片库 / 混合库的文件夹层级（子文件夹 / 封面 / 数量）
  Future<VideoImageFolderResponse> videoImageFolders({required String libraryId, String? folderPath}) async {
    final query = <String, String>{
      'libraryId': libraryId,
      if (folderPath != null) 'folderPath': folderPath,
    };
    final res = await transport.send('GET', _uri('/api/v1/video/image/folders', query), headers: await _headers());
    return VideoImageFolderResponse.fromJson(_asMap(_decode(res)));
  }

  /// 删除图片库 / 混合库的一个文件夹（移入回收站）
  Future<VideoImageFolderDeleteResponse> videoImageFolderDelete({required VideoImageFolderDeleteBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/image/folders/delete'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoImageFolderDeleteResponse.fromJson(_asMap(_decode(res)));
  }

  /// 智能合集（预设规则）与各自条数
  Future<VideoSmartAlbumListResponse> videoSmartAlbums() async {
    final res = await transport.send('GET', _uri('/api/v1/video/smart-albums'), headers: await _headers());
    return VideoSmartAlbumListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 智能合集条目（与计数同一份规则）
  Future<VideoListResponse> videoSmartAlbumItems({required String key, String? libraryId, int? limit}) async {
    final query = <String, String>{
      'key': key,
      if (libraryId != null) 'libraryId': libraryId,
      if (limit != null) 'limit': '$limit',
    };
    final res = await transport.send('GET', _uri('/api/v1/video/smart-albums/items', query), headers: await _headers());
    return VideoListResponse.fromJson(_asMap(_decode(res)));
  }

  /// 刮削单条（番号优先，失败回退 TMDB）
  Future<VideoScrapeResponse> videoScrapeStart({required VideoScrapeBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/scrape/start'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoScrapeResponse.fromJson(_asMap(_decode(res)));
  }

  /// 批量刮削（缺省只刮还没元数据的条目）
  Future<VideoScrapeBatchResponse> videoScrapeBatch({required VideoScrapeBatchBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/scrape/batch'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoScrapeBatchResponse.fromJson(_asMap(_decode(res)));
  }

  /// 清空一条的刮削结果
  Future<VideoScrapeCleanupResponse> videoScrapeCleanup({required VideoScrapeCleanupBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/scrape/cleanup'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoScrapeCleanupResponse.fromJson(_asMap(_decode(res)));
  }

  /// 设置该条目是否参与自动刮削
  Future<VideoOkResponse> videoScrapeMatch({required VideoMatchNfoBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/scrape/match'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoOkResponse.fromJson(_asMap(_decode(res)));
  }

  /// 手动搜索 TMDB 条目（用于「匹配到别的片子」时纠正）
  Future<VideoTmdbSearchResponse> videoTmdbSearch({required VideoTmdbSearchBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/tmdb/search'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoTmdbSearchResponse.fromJson(_asMap(_decode(res)));
  }

  /// 刮削设置（Key / 语言 / 是否写 .nfo / 置信度阈值）
  Future<VideoTmdbSettings> videoTmdbSettingsGet() async {
    final res = await transport.send('GET', _uri('/api/v1/video/tmdb/settings'), headers: await _headers());
    return VideoTmdbSettings.fromJson(_asMap(_decode(res)));
  }

  /// 写刮削设置（Key 传空字符串表示沿用发现页的 Key）
  Future<VideoTmdbSettings> videoTmdbSettingsSet({required VideoTmdbSettingsBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/tmdb/settings'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return VideoTmdbSettings.fromJson(_asMap(_decode(res)));
  }

  /// 测试 TMDB 连通性（用当前配置的 Key）
  Future<Map<String, dynamic>> videoTmdbTest({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/tmdb/test'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 刮削海报 / 剧照（本地文件读流，远端 URL 302 跳转）
  Future<Map<String, dynamic>> videoArt({required String id, dynamic kind, int? size}) async {
    final query = <String, String>{
      'id': id,
      if (kind != null) 'kind': kind,
      if (size != null) 'size': '$size',
    };
    final res = await transport.send('GET', _uri('/api/v1/video/art', query), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 影视设置（字幕抓取 + 转码）
  Future<Map<String, dynamic>> videoSettingsGet() async {
    final res = await transport.send('GET', _uri('/api/v1/video/settings'), headers: await _headers());
    return _asMap(_decode(res));
  }

  /// 写影视设置（只传要改的段 / 字段）
  Future<Map<String, dynamic>> videoSettingsSet({required Map<String, dynamic> body}) async {
    final res = await transport.send('PUT', _uri('/api/v1/video/settings'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 测试各字幕源链接（连通性，不下载）
  Future<Map<String, dynamic>> videoSubtitleSourcesTest({required Map<String, dynamic> body}) async {
    final res = await transport.send('POST', _uri('/api/v1/video/subtitle/test-sources'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body)));
    return _asMap(_decode(res));
  }

  /// 查询转码会话状态与播放地址
  Future<PlayerSessionItem> playerSessionGet({required String id, double? pos}) async {
    final query = <String, String>{
      'id': id,
      if (pos != null) 'pos': '$pos',
    };
    final res = await transport.send('GET', _uri('/api/v1/player/sessions', query), headers: await _headers());
    return PlayerSessionItem.fromJson(_asMap(_decode(res)));
  }

  /// 建 HLS 转码会话（可选字幕烧录）
  Future<PlayerSessionCreated> playerSessionCreate({required PlayerSessionCreateBody body}) async {
    final res = await transport.send('POST', _uri('/api/v1/player/sessions'), headers: await _headers(jsonBody: true), body: utf8.encode(jsonEncode(body.toJson())));
    return PlayerSessionCreated.fromJson(_asMap(_decode(res)));
  }

}