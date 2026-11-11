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
    if (kIsWeb) {
      final base = Uri.base;
      if (base.hasScheme &&
          base.host.isNotEmpty &&
          base.scheme.startsWith('http')) {
        // 只有 Flutter dev 的 5173 页面是「纯静态壳」，API 得另打到内核端口。
        // 其它情况页面本身就是内核提供的（直连 7788，或经 lucky 反代到 23788/443），
        // **端口必须照抄页面自己的** —— API 与页面同源才连得上。
        //
        // 旧实现不管从哪个口打开，一律改成 7788。于是用 lucky 反代访问
        // https://home.gexuan.net:23788 时，登录框预填成了 https://home.gexuan.net:7788，
        // 而 7788 是内核的**明文 HTTP** 口，浏览器 TLS 握手直接失败，
        // 表现为「Failed to fetch」，看着像服务挂了。
        const flutterDevPort = 5173;
        if (base.port != flutterDevPort && base.port != 0) {
          return base.origin;
        }
        final port = configured.isNotEmpty ? Uri.parse(configured).port : 7788;
        return '${base.scheme}://${base.host}:$port';
      }
    }
    if (configured.isNotEmpty) return configured;
    // 手机上 127.0.0.1 指向手机自己，填了必然连不上，还会让人以为「服务没起」。
    // 留空让用户点登录页的「扫描局域网」（见 server_discovery.dart），选一下就填好。
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return '';
    }
    return 'http://127.0.0.1:7788';
  }

  String baseUrl = defaultBaseUrl();
  String? token;
  String? username;

  /// 当前账号的授权快照（服务端 `/api/v1/auth/me`，故意不进契约）。
  /// `null` = 没配应用白名单，按 scopes 兜底；空集 = 一个应用都不给。
  /// 登录 / 恢复会话时都会刷新，管理员改了授权后子账号重开客户端即生效。
  Set<String>? allowedApps;
  bool isAdminFromServer = false;
  final HttpTransport _accessHttp = HttpTransport(
    timeout: const Duration(seconds: 8),
  );

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
        allowedApps = null;
        isAdminFromServer = false;
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

  /// 启动时恢复会话；返回是否已登录。
  ///
  /// 两级兜底（**所有客户端统一**，Web / 桌面 / Android / iOS）：
  /// 1. 存档里的 token 还在有效期内且服务端认 → 直接进桌面；
  /// 2. token 过期，或被服务端作废（内核换过密钥、账号改过密码、token 被吊销）
  ///    → 用记住的密码**自动登录一次**再进桌面。
  ///
  /// 勾了自动登录就不该再让人手输密码。旧实现只做第 1 步，token 一失效
  /// 就停在登录页，用户每次开客户端都要重新输一遍。
  Future<bool> restore() async {
    if (autoLoginDisabled) return false;
    final url = currentServerUrl();
    if (url.isEmpty) return false;

    final saved = SettingsStore.instance.getString('auth.token');
    if (saved != null && saved.isNotEmpty) {
      final exp = expiryOf(saved);
      final expired = exp != null && DateTime.now().millisecondsSinceEpoch >= exp;
      if (!expired) {
        autoLoginChecking.value = true;
        try {
          configure(url);
          token = saved;
          username = SettingsStore.instance.getString('auth.username');
          authState.value = true;
          // 探一次：token 可能还在有效期内但已被服务端作废。
          // 401 会被 Transport 清掉，这里据此决定要不要走密码兜底。
          if (await _probeSession()) {
            await refreshAccess();
            await loadServerInfo();
            events.start();
            return true;
          }
          token = null;
          authState.value = false;
        } finally {
          autoLoginChecking.value = false;
        }
      } else {
        // token 过期只清 token：记住的账号与密码要留着，用户不必重输
        await _clearToken();
      }
    }
    return _autoLoginWithPassword(url);
  }

  /// 当前应该连的服务器地址。
  ///
  /// Web 端以**地址栏**为准：页面本身就是服务（可能经 lucky 反代换过端口），
  /// API 必须与页面同源，否则登录框会填一个连不上的地址。
  /// 原生端没有地址栏可用，读存档；没有存档才退回默认地址。
  static String currentServerUrl() {
    if (kIsWeb) {
      final base = Uri.base;
      if (base.hasScheme &&
          base.host.isNotEmpty &&
          base.scheme.startsWith('http')) {
        const flutterDevPort = 5173;
        if (base.port != flutterDevPort && base.port != 0) return base.origin;
      }
    }
    final saved = SettingsStore.instance.getString('auth.server');
    if (saved != null && saved.isNotEmpty) return saved;
    return defaultBaseUrl();
  }

  /// 用当前 token 探一次服务端。
  ///
  /// 返回 true = token 有效。**要区分 401 与网络不通**：
  /// 401 说明 token 作废，该走密码兜底；网络不通说明服务端没起来，
  /// 这时反复登录只会报错，应当停在登录页让用户看到真实原因。
  Future<bool> _probeSession() async {
    try {
      await client.healthCheck();
      return true;
    } on ApiError catch (e) {
      return e.statusCode != 401;
    } catch (_) {
      return false;
    }
  }

  /// 用记住的密码自动登录一次。
  /// 没有密码（用户关掉了自动登录 / 从没保存过）时返回 false，交回登录页。
  Future<bool> _autoLoginWithPassword(String url) async {
    final user = SettingsStore.instance.getString('auth.username');
    final pass = SettingsStore.instance.getString('auth.password');
    if (user == null || user.isEmpty || pass == null || pass.isEmpty) {
      return false;
    }
    autoLoginChecking.value = true;
    try {
      configure(url);
      await login(user, pass);
      return token != null;
    } catch (_) {
      // 密码变了 / 账号被锁 / 服务端拒绝：回登录页，页面会显示真实错误
      return false;
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
    if (token != null) {
      await refreshAccess();
      await loadServerInfo();
      events.start();
    }
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

  /// 管理员 = scopes 含 `*`（与内核 `hasScope` 同一口径）；
  /// 访问令牌还要看签发账号是否全权，这一项由 `/me` 的 `isAdmin` 补上。
  bool get isAdmin => scopes.contains('*') || isAdminFromServer;

  /// 拉取当前账号的授权快照。失败不阻断登录：退回 scopes 推导。
  Future<void> refreshAccess() async {
    try {
      final res = await _accessHttp.send(
        'GET',
        Uri.parse('$baseUrl/api/v1/auth/me'),
        headers: authHeaders,
      );
      if (!res.isOk) return;
      final data = res.json;
      if (data is! Map) return;
      final apps = data['allowedApps'];
      allowedApps = apps is List ? apps.map((e) => '$e').toSet() : null;
      isAdminFromServer = data['isAdmin'] == true;
    } catch (_) {
      // 老服务端没有这个接口 / 暂时不可达：保持按 scopes 推导
    }
  }

  /// 主动登出：同时关闭自动登录（用户明确表达了「不要记住我」）
  Future<void> logout() async {
    events.stop();
    token = null;
    username = null;
    allowedApps = null;
    isAdminFromServer = false;
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
