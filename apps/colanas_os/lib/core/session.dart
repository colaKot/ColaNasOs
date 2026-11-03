import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nas_core/nas_core.dart';

import 'http_transport.dart';
import 'settings_store.dart';

/// 全局会话：baseUrl + token + 预构建的 ApiClient。
///
/// 自动登录：登录成功后把 **服务端 / 账号 / token** 落盘；启动时 `restore()` 直接恢复，
/// token 过期则静默回到登录页。用户主动登出会置 `auth.autoLoginDisabled = true`
/// （不再自动登录），在登录页勾选「下次自动登录」可重新开启。
class ApiSession {
  ApiSession._();

  static final ApiSession instance = ApiSession._();

  final ValueNotifier<bool> authState = ValueNotifier<bool>(false);

  /// 启动期「正在尝试自动登录」：让首帧显示转圈，而不是先闪一下登录表单
  final ValueNotifier<bool> autoLoginChecking = ValueNotifier<bool>(false);

  /// 页面所在来源优先：内核换端口 / 用内网 IP 打开时，前端不会再去打 7788。
  /// `dev.bat`（Flutter 5173 热重载 + 内核 7788）用 `--dart-define=COLANAS_API_BASE` 显式指定。
  static String defaultBaseUrl() {
    const configured = String.fromEnvironment('COLANAS_API_BASE');
    if (configured.isNotEmpty) return configured;
    if (kIsWeb) {
      final base = Uri.base;
      if (base.hasScheme &&
          base.host.isNotEmpty &&
          base.scheme.startsWith('http')) {
        return base.origin;
      }
    }
    return 'http://127.0.0.1:7788';
  }

  String baseUrl = defaultBaseUrl();
  String? token;
  String? username;

  /// 图片/封面这类**不走 ApiClient** 的请求要自己带 token
  /// （`Image.network` / `NasCoverImage` 的 `headers` 参数）。
  ///
  /// 以前 14 个页面各写一份同样的 getter，token 规则要改就得改 14 处。
  Map<String, String> get authHeaders =>
      token == null ? const {} : {'Authorization': 'Bearer $token'};

  /// 模块封面地址（`GET /api/v1/<module>/cover?id=<id>`）。
  ///
  /// 之前 book / music 各自拼一份（大小写、编码方式还不完全一样），
  /// 统一到这里：改动路由只改一处。
  String coverUrl(String module, String id) =>
      '$baseUrl/api/v1/$module/cover?id=${Uri.encodeComponent(id)}';

  /// 服务端公开展示信息（`/health`）：欢迎语 / 自定义主机名
  String welcome = '';
  String hostName = '';

  late ApiClient client = _build();

  /// 扫描/索引事件增量拉取：页面据此局部刷新（蓝图 §56）
  late EventPoller events;

  bool _eventsReady = false;

  ApiClient _build() {
    // 换服务器 / 重新登录会重建 client：旧轮询器必须先停，否则它会继续用旧 baseUrl 打请求
    if (_eventsReady) events.stop();
    // 统一的 401 处理放在 Transport 层：生成文件（client.dart）不能手改，
    // 每次 `npm run gen:client` 都会覆盖。
    final transport = CallbackTransport(
      HttpTransport(),
      onResponse: (res) {
        if (res.statusCode != 401 || token == null) return;
        // token 失效（过期 / 被吊销）：清凭证让 authState 回登录页，
        // 避免每个页面都显示一条「ApiError(401 …)」。
        token = null;
        username = null;
        authState.value = false;
        events.stop();
        _clearToken();
      },
    );
    final built = ApiClient(
      baseUrl: baseUrl,
      transport: transport,
      tokenProvider: () async => token,
    );
    events = EventPoller(built);
    _eventsReady = true;
    return built;
  }

  bool get authed => token != null;

  bool get autoLoginDisabled =>
      SettingsStore.instance.getBool('auth.autoLoginDisabled') ?? false;

  Future<bool> setAutoLoginEnabled(bool enabled) async {
    await SettingsStore.instance.setBool('auth.autoLoginDisabled', !enabled);
    if (!enabled) await _clearSavedToken();
    return enabled;
  }

  /// 启动时恢复会话；返回是否已登录
  Future<bool> restore() async {
    if (autoLoginDisabled) return false;
    final url = SettingsStore.instance.getString('auth.server');
    final saved = SettingsStore.instance.getString('auth.token');
    if (url == null || url.isEmpty || saved == null || saved.isEmpty) {
      return false;
    }

    final exp = expiryOf(saved);
    if (exp != null && DateTime.now().millisecondsSinceEpoch >= exp) {
      // token 过期只清 token：记住的账号与密码要留着，用户不必重输
      await _clearToken();
      return false;
    }

    autoLoginChecking.value = true;
    try {
      configure(url);
      token = saved;
      username = SettingsStore.instance.getString('auth.username');
      authState.value = true;
      await loadServerInfo();
      events.start();
      return true;
    } finally {
      autoLoginChecking.value = false;
    }
  }

  void configure(String url) {
    baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    client = _build();
  }

  Future<void> login(String user, String password, {String? totp}) async {
    final res = await client.authLogin(
      body: {
        'username': user,
        'password': password,
        if (totp != null && totp.isNotEmpty) 'totp': totp,
      },
    );
    token = res['token'] as String?;
    username = user;
    authState.value = token != null;

    if (token != null) {
      // 账号无条件保存（登录页预填），密码与 token 只在开启自动登录时保存
      await SettingsStore.instance.setString('auth.server', baseUrl);
      await SettingsStore.instance.setString('auth.username', user);
      await SettingsStore.instance.setInt('auth.expiresAt', expiryOf(token!));
      if (!autoLoginDisabled) {
        await SettingsStore.instance.setString('auth.token', token);
        await SettingsStore.instance.setString('auth.password', password);
      }
    }
    if (token != null) await loadServerInfo();
    if (token != null) events.start();
  }

  /// 读取服务端公开展示信息（欢迎语 / 主机名）；失败不阻断登录
  Future<void> loadServerInfo() async {
    try {
      final res = await client.healthCheck();
      welcome = '${res['welcome'] ?? ''}';
      hostName = '${res['hostname'] ?? ''}';
    } catch (_) {
      // 老服务端没有这些字段 / 暂时不可达：保持默认
    }
  }

  /// 当前 token 的 scopes（JWT payload）；未登录 / 解析失败为空集
  Set<String> get scopes {
    final raw = token;
    if (raw == null) return const {};
    try {
      final parts = raw.split('.');
      if (parts.length != 3) return const {};
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final list = (payload as Map)['scopes'];
      return list is List ? list.map((e) => '$e').toSet() : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 管理员 = scopes 含 `*`（与内核 `hasScope` 同一口径）
  bool get isAdmin => scopes.contains('*');

  /// 主动登出：同时关闭自动登录（用户明确表达了「不要记住我」）
  Future<void> logout() async {
    events.stop();
    token = null;
    username = null;
    authState.value = false;
    // 登出只清凭证，不改「自动登录」偏好：下次打开仍应预填账号，用户勾过就继续记住
    await _clearSavedToken();
  }

  Future<void> _clearToken() async {
    await SettingsStore.instance.setString('auth.token', null);
    await SettingsStore.instance.setInt('auth.expiresAt', null);
  }

  Future<void> _clearSavedToken() async {
    await _clearToken();
    await SettingsStore.instance.setString('auth.password', null);
  }

  /// 从 JWT 里读 `exp`（毫秒）；解析失败返回 null（不阻断登录）
  static int? expiryOf(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final exp = payload is Map ? payload['exp'] : null;
      return exp is int ? exp * 1000 : null;
    } catch (_) {
      return null;
    }
  }
}
