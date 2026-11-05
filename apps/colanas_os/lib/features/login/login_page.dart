import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';

/// 登录分两步：先连服务器，连上才知道该「登录」还是「创建管理员」。
enum _LoginStage { server, auth }

/// 登录页。启动时先探测服务端是否「还没初始化」（`GET /auth/bootstrap`）：
///
/// - `needsSetup: true` → 切到「首次安装」表单，创建第一个管理员（蓝图 §50）；
/// - 其余情况（含探测失败）→ 正常登录表单。探测失败不弹错，用户仍可手动登录
///   （服务端可能还没起来，或者已经初始化过）。
///
/// 2026-11-04：改成两步。第一步只填服务器地址 + 「连接」，
/// 连上之后再决定显示登录还是创建管理员 —— 之前地址和账号密码挤在一屏，
/// 而且空库时会直接铺出「创建管理员」，看起来像默认让人开账号。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  /// 测试注入口：覆盖第一步「连服务器」的探测，返回 `needsSetup`。
  ///
  /// 生产恒为 null，走真实请求。`testWidgets` 会把 HttpClient 换成返回 400 的
  /// 假实现，测试里没法用本地 HttpServer 进第二步，所以留这一个钩子。
  @visibleForTesting
  static Future<bool> Function(String url)? debugProbe;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController(text: ApiSession.defaultBaseUrl());
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _totp = TextEditingController();

  bool _busy = false;
  bool _autoLogin = true;

  /// 密码是否明文显示：默认隐藏，点右侧小眼睛临时看一眼（不持久化）。
  bool _showPassword = false;

  /// 是否要提交两步验证码：默认关闭，勾选后才显示验证码输入框。
  bool _twoFactor = false;

  bool _checking = true;
  bool _setupMode = false;
  String? _error;
  String? _hint;

  /// 当前步骤：先连服务器，连上才显示登录 / 创建管理员
  _LoginStage _stage = _LoginStage.server;
  bool _connecting = false;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    final store = SettingsStore.instance;
    final server = store.getString('auth.server');
    if (server != null && server.isNotEmpty) _server.text = server;
    final user = store.getString('auth.username');
    if (user != null && user.isNotEmpty) _user.text = user;
    // 记住的密码直接预填（用户要求「账号密码都要保存」），点登录即可
    final savedPassword = store.getString('auth.password');
    if (savedPassword != null && savedPassword.isNotEmpty) {
      _password.text = savedPassword;
    }
    // 服务端公开信息（自定义主机名 / 欢迎语）：登录页先读一次，读到就刷新标题
    ApiSession.instance.loadServerInfo().then((_) {
      if (mounted) setState(() {});
    });
    _autoLogin = (savedPassword != null && savedPassword.isNotEmpty) ||
        !(store.getBool('auth.autoLoginDisabled') ?? false);
    // 已保存过地址：自动试连一次，连上就直接进登录/创建步骤；
    // 没保存地址（或连不上）就停在「填地址」这一步。
    if (_server.text.trim().isNotEmpty) {
      unawaited(_connect(auto: true));
    } else {
      _checking = false;
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    _confirm.dispose();
    _totp.dispose();
    super.dispose();
  }

  /// 第一步：连服务器。连上之后才知道该显示「登录」还是「创建管理员」。
  ///
  /// [auto] = 启动时用上次保存的地址自动重连，失败不铺错误（用户直接改地址即可）。
  Future<void> _connect({bool auto = false}) async {
    final url = _server.text.trim();
    if (url.isEmpty) {
      setState(() {
        _connecting = false;
        _checking = false;
        _serverError = tr('login.serverRequired');
      });
      return;
    }
    setState(() {
      _connecting = true;
      _serverError = null;
      _error = null;
    });
    ApiSession.instance.configure(url);
    try {
      final probe = LoginPage.debugProbe;
      final res = probe != null
          ? <String, dynamic>{'needsSetup': await probe(url)}
          : await ApiSession.instance.client.authBootstrapStatus();
      if (!mounted) return;
      SettingsStore.instance.setString('auth.server', url);
      setState(() {
        _setupMode = res['needsSetup'] == true;
        _stage = _LoginStage.auth;
        _connecting = false;
        _checking = false;
      });
    } catch (e) {
      debugPrint('[login] connect failed: $e');
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _checking = false;
        _serverError = auto ? null : _describe(e);
      });
    }
  }

  /// 回到第一步（换一台服务器）
  void _backToServer() {
    setState(() {
      _stage = _LoginStage.server;
      _serverError = null;
      _error = null;
      _hint = null;
    });
  }

  Future<void> _submitLogin() async {
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });
    try {
      await ApiSession.instance.setAutoLoginEnabled(_autoLogin);
      ApiSession.instance.configure(_server.text.trim());
      final totp = _twoFactor ? _totp.text.trim() : '';
      await ApiSession.instance.login(
        _user.text.trim(),
        _password.text,
        totp: totp.isEmpty ? null : totp,
      );
    } catch (e) {
      final text = e.toString();
      if (!mounted) return;
      setState(() {
        _error = _describe(e);
        // 服务端要求两步验证：直接打开开关，省一次手动勾选
        if (text.contains('totp_required')) _twoFactor = true;
      });
      // 连不上服务端（常见于先开窗口、内核还没起来）→ 重新探测：空库就切到「首次安装」
      if (_isConnectionError(text)) await _connect();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isConnectionError(String text) =>
      text.contains('SocketException') ||
      text.contains('connection') ||
      text.contains('Connection');

  /// 首次安装：创建管理员 → 直接用同一密码登录。
  Future<void> _submitSetup() async {
    final user = _user.text.trim();
    final pwd = _password.text;
    if (user.isEmpty) {
      setState(() => _error = tr('setup.usernameRequired'));
      return;
    }
    if (pwd.length < 8) {
      setState(() => _error = tr('setup.tooShort'));
      return;
    }
    if (pwd != _confirm.text) {
      setState(() => _error = tr('setup.mismatch'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });
    try {
      ApiSession.instance.configure(_server.text.trim());
      await ApiSession.instance.client.authBootstrap(
        body: {'username': user, 'password': pwd},
      );
      await ApiSession.instance.setAutoLoginEnabled(_autoLogin);
      await ApiSession.instance.login(user, pwd);
    } catch (e) {
      final text = e.toString();
      if (text.contains('already initialized') || text.contains('conflict')) {
        // 别人已经初始化过：切回登录，不把用户卡在引导页
        if (!mounted) return;
        setState(() {
          _setupMode = false;
          _hint = tr('setup.alreadyDone');
          _error = null;
        });
      } else if (text.contains('connection') ||
          text.contains('SocketException')) {
        if (!mounted) return;
        setState(() => _error = tr('setup.failed'));
      } else {
        if (!mounted) return;
        setState(() => _error = '${tr('setup.failed')}：$text');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe(Object e) {
    final text = e.toString();
    if (text.contains('totp_required')) return tr('ui.login.h1b8cb2');
    if (text.contains('unauthorized') || text.contains('401')) {
      return tr('ui.login.hfbaa29');
    }
    return tr('login.failed', {'reason': text});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(NasTokens.spaceLg),
            child: _stage == _LoginStage.server
                ? _serverForm(context)
                : _authForm(context),
          ),
        ),
      ),
    );
  }

  /// 第一步：只有服务器地址。连上之后才进登录/创建。
  Widget _serverForm(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'ColaNasOs',
          style: TextStyle(fontSize: NasTokens.fontHeadline),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          tr('login.serverStep'),
          style: TextStyle(
            fontSize: NasTokens.fontBody,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          tr('login.serverStepHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: NasTokens.spaceLg),
        TextField(
          controller: _server,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: tr('login.server'),
            prefixIcon: const Icon(Icons.dns_outlined, size: 18),
          ),
          onSubmitted: (_) => _connecting ? null : _connect(),
        ),
        if (_serverError != null) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Text(_serverError!, style: TextStyle(color: context.nasDanger)),
        ],
        const SizedBox(height: NasTokens.spaceMd),
        FilledButton(
          onPressed: _connecting ? null : () => _connect(),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
            child: _connecting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(tr('login.connect')),
          ),
        ),
      ],
    );
  }

  /// 第二步：登录或创建管理员（取决于服务端是否已有账号）。
  Widget _authForm(BuildContext context) {
    final setup = _setupMode;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'ColaNasOs',
          style: TextStyle(fontSize: NasTokens.fontHeadline),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          setup
              ? tr('setup.hint')
              : (ApiSession.instance.hostName.isEmpty
                  ? tr('login.title')
                  : '${tr('login.title')} · ${ApiSession.instance.hostName}'),
          style: TextStyle(
            fontSize: NasTokens.fontBody,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: NasTokens.spaceLg),
        Row(
          children: [
            Icon(
              Icons.dns_outlined,
              size: 15,
              color: context.nasTextSecondary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr('login.connectedTo', {
                  'host': ApiSession.instance.hostName.isEmpty
                      ? _server.text.trim()
                      : ApiSession.instance.hostName,
                }),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _backToServer,
              child: Text(tr('login.changeServer')),
            ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceSm),
        TextField(
          controller: _user,
          decoration: InputDecoration(
            labelText: setup
                ? tr('setup.username')
                : tr('login.username'),
          ),
        ),
        const SizedBox(height: NasTokens.spaceMd),
        TextField(
          controller: _password,
          obscureText: !_showPassword,
          decoration: InputDecoration(
            labelText: setup
                ? tr('setup.password')
                : tr('login.password'),
            suffixIcon: IconButton(
              tooltip: tr(
                _showPassword
                    ? 'login.hidePassword'
                    : 'login.showPassword',
              ),
              icon: Icon(
                _showPassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () =>
                  setState(() => _showPassword = !_showPassword),
            ),
          ),
          onSubmitted: (_) => setup ? _submitSetup() : _submitLogin(),
        ),
        if (setup) ...[
          const SizedBox(height: NasTokens.spaceMd),
          TextField(
            controller: _confirm,
            obscureText: true,
            decoration: InputDecoration(labelText: tr('setup.confirm')),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  value: _autoLogin,
                  onChanged: (v) =>
                      setState(() => _autoLogin = v ?? true),
                  title: Text(tr('login.autoLogin')),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              Expanded(
                child: CheckboxListTile(
                  value: _twoFactor,
                  onChanged: (v) => setState(() {
                    _twoFactor = v ?? false;
                    if (!_twoFactor) _totp.clear();
                  }),
                  title: Text(tr('login.twoFactor')),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          if (_twoFactor)
            TextField(
              controller: _totp,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(labelText: tr('login.totp')),
            ),
        ],
        if (_hint != null) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Text(
            _hint!,
            style: TextStyle(color: context.nasTextSecondary),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Text(_error!, style: TextStyle(color: context.nasDanger)),
        ],
        const SizedBox(height: NasTokens.spaceMd),
        FilledButton(
          onPressed: _busy || _checking
              ? null
              : (setup ? _submitSetup : _submitLogin),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: NasTokens.spaceSm,
            ),
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(setup ? tr('setup.submit') : tr('login.submit')),
          ),
        ),
        if (setup) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Text(
            tr('setup.title'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ],
    );
  }
}
