import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../shell/app_widgets.dart';

import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_settings.dart';
import '../../core/app_version.dart';
import '../../core/display_labels.dart';
import '../../core/i18n_setup.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'help_page.dart';
import 'style_preview_page.dart';
import '../../shell/mobile_frame.dart';
import '../../shell/app_nav_shell.dart';

/// 设置（配置中心）：左侧二级导航分四组 —— 服务器（服务器配置 + 服务与账号）、
/// 外观（外观 + 语言）、日志（服务端日志）、其他（索引维护 + 关于）。
///
/// 媒体库管理已按既有实现移到各模块（相册来源 / 影视库管理 / 音乐库管理 / 书房），
/// 设置页不再放「媒体库」栏目。
/// 服务器相关区块需要 `system:read` / `system:write`，无权限时显示明确提示。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _urlCtrl = TextEditingController(text: ApiSession.instance.baseUrl);
  final _portCtrl = TextEditingController();
  final _concurrencyCtrl = TextEditingController();
  final _hostnameCtrl = TextEditingController();
  final _welcomeCtrl = TextEditingController();
  final _proxyCtrl = TextEditingController();
  final _httpsPortCtrl = TextEditingController(text: '8443');

  String _activeProxy = '';
  bool _loadingServer = true;
  bool _serverForbidden = false;
  String? _serverError;
  bool _savingServer = false;
  bool _proxyEnabled = false;
  bool _httpsEnabled = false;

  // AI 服务（与播客页共用同一份配置：这里改了，播客页刷新就是新值）
  final _llmKeyCtrl = TextEditingController();
  final _llmBaseCtrl = TextEditingController();
  final _llmModelCtrl = TextEditingController();
  bool _llmEnabled = true;
  bool _llmWebSearch = false;
  String _llmProvider = 'deepseek';
  bool _llmKeyVisible = false;
  SystemTlsInfoResponse? _tls;

  SystemCacheInfoResponse? _cache;
  bool _cacheLoading = true;
  bool _clearingCache = false;
  bool _compactingDb = false;

  String? _updateText;
  bool _checkingUpdate = false;
  bool _restarting = false;

  /// 二级导航当前分组：server / appearance / logs / other
  String _tab = _initialTab();

  static const _tabs = {'server', 'appearance', 'logs', 'other'};

  static String _initialTab() {
    final saved = SettingsStore.instance.getString('ui.settings.tab');
    return saved != null && _tabs.contains(saved) ? saved : 'server';
  }

  /// 二级导航收起状态（沿用各模块一致的持久化键）
  bool _navCollapsed =
      SettingsStore.instance.getBool('ui.nav.collapsed.settings') ?? false;

  SystemLogsResponse? _logs;
  bool _logsLoading = false;
  String? _logsError;
  bool _logsAuto = false;
  Timer? _logsTimer;

  /// 日志级别筛选：errorWarn（默认）/ error / warn / info（由服务端过滤）
  String _logsLevel = 'errorWarn';
  /// 分页：第 1 页是最新日志，往后翻是更旧的内容
  int _logPage = 0;
  int _logPageSize = 50;

  @override
  void initState() {
    super.initState();
    _loadServer();
    _loadCache();
    if (_tab == 'logs') _loadLogs();
  }

  @override
  void dispose() {
    _logsTimer?.cancel();
    _urlCtrl.dispose();
    _portCtrl.dispose();
    _concurrencyCtrl.dispose();
    _hostnameCtrl.dispose();
    _welcomeCtrl.dispose();
    _proxyCtrl.dispose();
    super.dispose();
  }

  String? _hint(Object e) {
    final text = e.toString();
    if (text.contains('403')) return tr('settings.needAdmin');
    return errorMessageOf(e);
  }

  Future<void> _loadServer() async {
    setState(() {
      _loadingServer = true;
      _serverError = null;
      _serverForbidden = false;
    });
    try {
      final res = await ApiSession.instance.client.systemSettingsGet();
      if (!mounted) return;
      final s = res.settings;
      setState(() {
        _activeProxy = res.activeProxy;
        _portCtrl.text = '${s.httpPort}';
        _concurrencyCtrl.text = '${s.apiConcurrency}';
        _hostnameCtrl.text = s.hostname;
        _welcomeCtrl.text = s.welcome;
        _proxyCtrl.text = s.proxy;
        _proxyEnabled = s.proxy.isNotEmpty;
        _httpsEnabled = s.httpsEnabled;
        _httpsPortCtrl.text = '${s.httpsPort}';
        _llmEnabled = s.llm.enabled;
        _llmProvider = switch (s.llm.provider) {
          'openai' => 'openai',
          'deepseek' => 'deepseek',
          'bailian' => 'bailian',
          _ => 'custom',
        };
        _llmWebSearch = s.llm.webSearch;
        _llmKeyCtrl.text = s.llm.apiKey;
        _llmBaseCtrl.text = s.llm.baseUrl;
        _llmModelCtrl.text = s.llm.model;
        _loadingServer = false;
      });
      // 证书状态单独取（老服务端没有该接口时不阻断设置页）
      try {
        final tls = await ApiSession.instance.client.systemTlsInfo();
        if (!mounted) return;
        setState(() => _tls = tls);
      } catch (_) {
        /* 忽略 */
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverForbidden = _hint(e) != null;
        _serverError = _hint(e) ?? e.toString();
        _loadingServer = false;
      });
    }
  }

  Future<void> _saveServer() async {
    setState(() => _savingServer = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.systemSettingsSet(
        body: SystemSettingsBody(
          httpPort: int.tryParse(_portCtrl.text.trim()),
          httpsPort: int.tryParse(_httpsPortCtrl.text.trim()),
          httpsEnabled: _httpsEnabled,
          apiConcurrency: int.tryParse(_concurrencyCtrl.text.trim()),
          hostname: _hostnameCtrl.text.trim(),
          welcome: _welcomeCtrl.text.trim(),
          proxy: _proxyEnabled ? _proxyCtrl.text.trim() : '',
          llm: SystemLlmPatch(
            enabled: _llmEnabled,
            provider: _llmProvider,
            apiKey: _llmKeyCtrl.text.trim(),
            baseUrl: _llmBaseCtrl.text.trim(),
            model: _llmModelCtrl.text.trim(),
            webSearch: _llmWebSearch,
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        _activeProxy = res.activeProxy;
        _proxyCtrl.text = res.settings.proxy;
      });
      NasSnack.showOn(messenger, tr('settings.saved'));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '${_hint(e) ?? e}'}));
    } finally {
      if (mounted) setState(() => _savingServer = false);
    }
  }

  Future<void> _uploadTls() async {
    final certFile = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'cert', extensions: ['pem', 'crt', 'cer']),
      ],
    );
    if (certFile == null) return;
    final keyFile = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'key', extensions: ['pem', 'key']),
      ],
    );
    if (keyFile == null) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final cert = utf8.decode(await certFile.readAsBytes());
      final key = utf8.decode(await keyFile.readAsBytes());
      final info = await ApiSession.instance.client.systemTlsUpload(
        body: SystemTlsUploadBody(cert: cert, key: key),
      );
      if (!mounted) return;
      setState(() {
        _tls = info;
        _httpsPortCtrl.text = '${info.port}';
      });
      NasSnack.showOn(messenger, tr('settings.tlsUploaded'));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '${_hint(e) ?? e}'}));
    }
  }

  Future<void> _clearTls() async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.systemTlsClear();
      final info = await ApiSession.instance.client.systemTlsInfo();
      if (!mounted) return;
      setState(() => _tls = info);
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  Future<void> _loadCache() async {
    setState(() => _cacheLoading = true);
    try {
      final res = await ApiSession.instance.client.systemCacheInfo();
      if (!mounted) return;
      setState(() {
        _cache = res;
        _cacheLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _cacheLoading = false);
    }
  }

  void _selectTab(String id) {
    if (_tab == id) return;
    final leavingLogs = _tab == 'logs';
    setState(() => _tab = id);
    SettingsStore.instance.setString('ui.settings.tab', id);
    if (id == 'logs') {
      _loadLogs();
      if (_logsAuto) _startLogsTimer();
    } else if (leavingLogs) {
      _logsTimer?.cancel();
      _logsTimer = null;
    }
  }

  void _toggleNavCollapsed() {
    setState(() => _navCollapsed = !_navCollapsed);
    SettingsStore.instance.setBool('ui.nav.collapsed.settings', _navCollapsed);
  }

  Future<void> _loadLogs({bool resetPage = false}) async {
    if (!mounted) return;
    setState(() {
      if (resetPage) _logPage = 0;
      _logsLoading = true;
      _logsError = null;
    });
    try {
      // 服务端倒读分页 + 逐行级别过滤：一次只拿本页，不再把 200 行全铺开
      final res = await ApiSession.instance.client.systemLogs(
        limit: _logPageSize,
        offset: _logPage * _logPageSize,
        level: switch (_logsLevel) {
          'error' => 'error',
          'info' => 'info',
          _ => 'warn', // errorWarn：warn + error/fatal
        },
      );
      if (!mounted) return;
      setState(() {
        _logs = res;
        _logsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _logsError = _hint(e) ?? '$e';
        _logsLoading = false;
      });
    }
  }

  void _goLogPage(int page) {
    final next = page < 0 ? 0 : page;
    if (next == _logPage) return;
    // 不动 timer：_startLogsTimer 里按 _logPage == 0 判断，翻回第 1 页会自动恢复追新
    setState(() => _logPage = next);
    _loadLogs();
  }

  void _startLogsTimer() {
    _logsTimer?.cancel();
    _logsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // 只在第 1 页追最新日志；历史页冻结，避免内容在眼前跳
      if (_logPage == 0) _loadLogs();
    });
  }

  void _setLogsAuto(bool on) {
    setState(() => _logsAuto = on);
    if (on) {
      _loadLogs(resetPage: true);
      _startLogsTimer();
    } else {
      _logsTimer?.cancel();
      _logsTimer = null;
    }
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('settings.cacheClear')),
        content: Text(
          tr('settings.cacheUsage', {
            'size': formatBytes(_cache?.bytes ?? 0),
            'files': '${_cache?.files ?? 0}',
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('settings.cacheClear')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    setState(() => _clearingCache = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.systemCacheClear();
      await _loadCache();
      NasSnack.showOn(messenger, 
            tr('settings.cacheCleared', {'size': formatBytes(res.freedBytes)}),
          );
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '${_hint(e) ?? e}'}));
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  Future<void> _compactDb() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('settings.dbCompact')),
        content: Text(tr('settings.dbCompactHint')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('settings.dbCompact')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    setState(() => _compactingDb = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.systemDbCompact();
      if (!mounted) return;
      NasSnack.showOn(
        messenger,
        tr('settings.dbCompacted', {'size': formatBytes(res.freedBytes)}),
      );
    } catch (e) {
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '${_hint(e) ?? e}'}));
    } finally {
      if (mounted) setState(() => _compactingDb = false);
    }
  }

  Future<void> _restart() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('settings.restart')),
        content: Text(tr('settings.restartConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('settings.restart')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    setState(() => _restarting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.systemRestart();
      NasSnack.showOn(messenger, tr('settings.restarting'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _restarting = false);
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '${_hint(e) ?? e}'}));
    }
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      final res = await ApiSession.instance.client.systemUpdateCheck();
      if (!mounted) return;
      setState(() {
        _updateText = res.hasUpdate
            ? tr('settings.updateAvailable', {
                'version': '${res.latestVersion}',
              })
            : tr('settings.updateNone');
        _checkingUpdate = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _updateText = '${_hint(e) ?? e}';
        _checkingUpdate = false;
      });
    }
  }

  void _saveBaseUrl() {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    ApiSession.instance.configure(url);
    _urlCtrl.text = ApiSession.instance.baseUrl;
    NasSnack.show(context, 
          tr('settings.switched', {'url': ApiSession.instance.baseUrl}),
        );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceMd,
        vertical: NasTokens.spaceSm,
      ),
      child: Padding(
        padding: EdgeInsets.all(NasTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: NasTokens.spaceSm),
            ...children,
          ],
        ),
      ),
    );
  }

  /// AI 服务：与「播客 → AI 新闻」页共用同一份 llm 配置（服务端 system.settings#llm）
  Widget _llmSection() {
    return _section(tr('settings.llm.title'), [
      Text(
        tr('settings.llm.hint'),
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          color: context.nasTextSecondary,
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _llmEnabled,
        onChanged: (v) => setState(() => _llmEnabled = v),
        title: Text(tr('settings.llm.enable')),
      ),
      Row(
        children: [
          SizedBox(
            width: 150,
            child: NasDropdown<String>(
              expanded: true,
              value: _llmProvider,
              items: [
                const DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek')),
                DropdownMenuItem(
                  value: 'bailian',
                  child: Text(tr('settings.llm.providerBailian')),
                ),
                const DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                DropdownMenuItem(
                  value: 'custom',
                  child: Text(tr('settings.llm.custom')),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _llmProvider = v);
                if (v == 'deepseek') {
                  _llmBaseCtrl.text = 'https://api.deepseek.com';
                  _llmModelCtrl.text = 'deepseek-flash';
                  _llmWebSearch = false;
                } else if (v == 'bailian') {
                  _llmBaseCtrl.text = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
                  _llmModelCtrl.text = 'deepseek-v3';
                  _llmWebSearch = true;
                } else if (v == 'openai') {
                  _llmBaseCtrl.text = 'https://api.openai.com/v1';
                  _llmModelCtrl.text = 'gpt-4o-mini';
                }
              },
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          Expanded(
            child: TextField(
              controller: _llmModelCtrl,
              decoration: InputDecoration(
                labelText: tr('settings.llm.model'),
                isDense: true,
              ),
            ),
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _llmWebSearch,
        onChanged: (v) => setState(() => _llmWebSearch = v),
        title: Text(tr('settings.llm.webSearch')),
        subtitle: Text(
          tr('settings.llm.webSearchHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _llmKeyCtrl,
        obscureText: !_llmKeyVisible,
        decoration: InputDecoration(
          labelText: tr('settings.llm.key'),
          isDense: true,
          suffixIcon: IconButton(
            tooltip: _llmKeyVisible
                ? tr('settings.llm.hideKey')
                : tr('settings.llm.showKey'),
            icon: Icon(
              _llmKeyVisible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            onPressed: () => setState(() => _llmKeyVisible = !_llmKeyVisible),
          ),
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _llmBaseCtrl,
        decoration: InputDecoration(
          labelText: tr('settings.llm.base'),
          isDense: true,
        ),
      ),
    ]);
  }

  Widget _serverSection() {
    if (_loadingServer) {
      return _section(tr('settings.server'), [const LinearProgressIndicator()]);
    }
    if (_serverForbidden) {
      return _section(tr('settings.server'), [
        Text(
          tr('settings.needAdmin'),
          style: TextStyle(color: context.nasTextSecondary),
        ),
      ]);
    }
    if (_serverError != null) {
      return _section(tr('settings.server'), [
        Text(_serverError!, style: TextStyle(color: context.nasDanger)),
        const SizedBox(height: NasTokens.spaceSm),
        OutlinedButton(onPressed: _loadServer, child: Text(tr('common.retry'))),
      ]);
    }
    return _section(tr('settings.server'), [
      Row(
        children: [
          SizedBox(
            width: 150,
            child: TextField(
              controller: _portCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: tr('settings.port'),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          SizedBox(
            width: 170,
            child: TextField(
              controller: _concurrencyCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: tr('settings.concurrency'),
                isDense: true,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: NasTokens.spaceXs),
      Text(
        tr('settings.restartHint'),
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          color: context.nasTextSecondary,
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _hostnameCtrl,
        maxLength: 10,
        decoration: InputDecoration(
          labelText: tr('settings.hostname'),
          helperText: tr('settings.hostnameHint'),
          isDense: true,
        ),
      ),
      TextField(
        controller: _welcomeCtrl,
        maxLength: 100,
        decoration: InputDecoration(
          labelText: tr('settings.welcome'),
          helperText: tr('settings.welcomeHint'),
          isDense: true,
        ),
      ),
      const Divider(height: 1),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(tr('settings.https')),
        subtitle: Text(
          tr('settings.httpsHint'),
          style: TextStyle(fontSize: NasTokens.fontCaption),
        ),
        value: _httpsEnabled,
        onChanged: (v) => setState(() => _httpsEnabled = v),
      ),
      Row(
        children: [
          SizedBox(
            width: 150,
            child: TextField(
              controller: _httpsPortCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: tr('settings.httpsPort'),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          TextButton.icon(
            onPressed: _uploadTls,
            icon: const Icon(Icons.upload_file, size: 18),
            label: Text(tr('settings.tlsCert')),
          ),
          if (_tls?.hasCert == true)
            TextButton.icon(
              onPressed: _clearTls,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(tr('settings.tlsClear')),
            ),
        ],
      ),
      Text(
        _tls?.hasCert == true
            ? '${tr('settings.tlsSubject', {'subject': _tls!.subject})}\n'
                  '${tr('settings.tlsValid', {'from': _tls!.validFrom, 'to': _tls!.validTo})}'
            : tr('settings.tlsNone'),
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          color: context.nasTextSecondary,
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(tr('settings.proxy')),
        subtitle: Text(
          tr('settings.proxyHint'),
          style: TextStyle(fontSize: NasTokens.fontCaption),
        ),
        value: _proxyEnabled,
        onChanged: (v) => setState(() => _proxyEnabled = v),
      ),
      if (_proxyEnabled)
        TextField(
          controller: _proxyCtrl,
          decoration: const InputDecoration(
            labelText: 'http://127.0.0.1:7890',
            isDense: true,
          ),
        ),
      const SizedBox(height: NasTokens.spaceXs),
      Text(
        _activeProxy.isEmpty
            ? tr('settings.proxyOff')
            : tr('settings.proxyActive', {'proxy': _activeProxy}),
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          color: context.nasTextSecondary,
        ),
      ),

      const SizedBox(height: NasTokens.spaceSm),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          onPressed: _savingServer ? null : _saveServer,
          child: Text(tr('common.save')),
        ),
      ),
    ]);
  }

  Widget _appearance() {
    return _section(tr('settings.appearance'), [
      ValueListenableBuilder<ThemeMode>(
        valueListenable: AppSettings.instance.themeMode,
        builder: (context, mode, _) => SegmentedButton<ThemeMode>(
          segments: [
            ButtonSegment(
              value: ThemeMode.dark,
              label: Text(tr('ui.settings.005')),
              icon: Icon(Icons.dark_mode_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              label: Text(tr('ui.settings.006')),
              icon: Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.system,
              label: Text(tr('ui.settings.007')),
              icon: Icon(Icons.brightness_auto_outlined),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (s) => AppSettings.instance.setThemeMode(s.first),
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: AppSettings.instance.tvMode,
        builder: (context, on, _) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.tv_outlined),
          title: Text(tr('ui.settings.019')),
          subtitle: Text(
            tr('ui.settings.020'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          value: on,
          onChanged: AppSettings.instance.setTvMode,
        ),
      ),
      // 端能力提示：默认关（横幅常驻只会挤占内容），需要排查端差异时在这里开
      ValueListenableBuilder<bool>(
        valueListenable: AppSettings.instance.capabilityNotice,
        builder: (context, on, _) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.devices_other_outlined),
          title: Text(tr('settings.capabilityNotice')),
          subtitle: Text(
            tr('settings.capabilityNoticeHint'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          value: on,
          onChanged: AppSettings.instance.setCapabilityNotice,
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          tr('ui.settings.008'),
          style: TextStyle(color: context.nasTextSecondary),
        ),
      ),
      const SizedBox(height: NasTokens.spaceXs),
      ValueListenableBuilder<String>(
        valueListenable: AppSettings.instance.schemeId,
        builder: (context, id, _) => Wrap(
          spacing: NasTokens.spaceXs,
          runSpacing: NasTokens.spaceXs,
          children: [
            for (final option in NasColorSchemes.options)
              NasChip(
                label: Text(option.label),
                selected: option.id == id,
                avatar: CircleAvatar(backgroundColor: option.color, radius: 8),
                onSelected: (_) => AppSettings.instance.setScheme(option.id),
              ),
          ],
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      ValueListenableBuilder<String>(
        valueListenable: AppSettings.instance.skinId,
        builder: (context, id, _) => Row(
          children: [
            Text(
              tr('ui.settings.009'),
              style: TextStyle(color: context.nasTextSecondary),
            ),
            const SizedBox(width: NasTokens.spaceSm),
            NasDropdown<String>(
              value: id,
              items: [
                for (final skin in NasSkins.options)
                  DropdownMenuItem(value: skin.id, child: Text(skin.label)),
              ],
              onChanged: (v) {
                if (v != null) AppSettings.instance.setSkin(v);
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      Text(
        tr('settings.font'),
        style: TextStyle(color: context.nasTextSecondary),
      ),
      const SizedBox(height: NasTokens.spaceXs),
      ValueListenableBuilder<String>(
        valueListenable: AppSettings.instance.fontId,
        builder: (context, id, _) => Wrap(
          spacing: NasTokens.spaceXs,
          runSpacing: NasTokens.spaceXs,
          children: [
            for (final font in NasFonts.ids)
              NasChip(
                label: Text(tr('settings.font.$font')),
                selected: font == id,
                onSelected: (_) => AppSettings.instance.setFont(font),
              ),
          ],
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      Text(
        tr('style.title'),
        style: TextStyle(color: context.nasTextSecondary),
      ),
      const SizedBox(height: NasTokens.spaceXs),
      ValueListenableBuilder<String>(
        valueListenable: AppSettings.instance.styleId,
        builder: (context, id, _) => Wrap(
          spacing: NasTokens.spaceXs,
          runSpacing: NasTokens.spaceXs,
          children: [
            for (final option in NasStyles.options)
              NasChip(
                label: Text(tr('style.${option.id}')),
                selected: option.id == id,
                onSelected: (_) => AppSettings.instance.setStyle(option.id),
              ),
          ],
        ),
      ),
      const SizedBox(height: NasTokens.spaceXs),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const StylePreviewPage()),
          ),
          icon: const Icon(Icons.grid_view_rounded, size: 18),
          label: Text(tr('style.preview')),
        ),
      ),
      const SizedBox(height: NasTokens.spaceXs),
      Text(
        SettingsStore.instance.persistent
            ? tr('ui.settings.hc591ec')
            : tr('ui.settings.h93f888'),
        style: TextStyle(color: context.nasTextSecondary),
      ),
    ]);
  }

  Widget _language() {
    return _section(tr('settings.language'), [
      ValueListenableBuilder<int>(
        valueListenable: i18nRevision,
        builder: (context, _, _) => NasDropdown<String>(
          value: I18n.instance.locale,
          items: [
            for (final locale in supportedLocales)
              DropdownMenuItem(value: locale.$1, child: Text(locale.$2)),
          ],
          onChanged: (value) {
            if (value != null) setLocale(value);
          },
        ),
      ),
      const SizedBox(height: NasTokens.spaceXs),
      Text(
        SettingsStore.instance.persistent
            ? I18n.instance.locale
            : tr('settings.sessionOnly', {'locale': I18n.instance.locale}),
        style: TextStyle(color: context.nasTextSecondary),
      ),
    ]);
  }

  Widget _connection() {
    return _section(tr('ui.settings.he700d5'), [
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _urlCtrl,
              decoration: InputDecoration(
                labelText: tr('ui.settings.010'),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          FilledButton(
            onPressed: _saveBaseUrl,
            child: Text(tr('ui.settings.011')),
          ),
        ],
      ),
      const SizedBox(height: NasTokens.spaceSm),
      Text(
        tr('settings.account', {
          'name': ApiSession.instance.username ?? tr('settings.notLoggedIn'),
        }),
        style: TextStyle(color: context.nasTextSecondary),
      ),
    ]);
  }

  Widget _maintenance() {
    return _section(tr('ui.settings.h59156f'), [
      InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const HelpPage()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
          child: Row(
            children: [
              const Icon(Icons.help_outline, size: 20),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(child: Text(tr('help.title'))),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: context.nasTextSecondary,
              ),
            ],
          ),
        ),
      ),
      const Divider(height: 1),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('settings.cache')),
                Text(
                  _cacheLoading
                      ? tr('common.loading')
                      : tr('settings.cacheUsage', {
                          'size': formatBytes(_cache?.bytes ?? 0),
                          'files': '${_cache?.files ?? 0}',
                        }),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: _clearingCache ? null : _clearCache,
            icon: const Icon(Icons.cleaning_services_outlined, size: 18),
            label: Text(
              _clearingCache ? tr('common.loading') : tr('settings.cacheClear'),
            ),
          ),
        ],
      ),
      const SizedBox(height: NasTokens.spaceSm),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('settings.dbCompact')),
                Text(
                  tr('settings.dbCompactHint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          OutlinedButton.icon(
            onPressed: _compactingDb ? null : _compactDb,
            icon: const Icon(Icons.storage_outlined, size: 18),
            label: Text(
              _compactingDb ? tr('common.loading') : tr('settings.dbCompact'),
            ),
          ),
        ],
      ),
      const SizedBox(height: NasTokens.spaceSm),
      Row(
        children: [
          Expanded(
            child: Text(
              tr('settings.restart'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _restarting ? null : _restart,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: Text(
              _restarting ? tr('settings.restarting') : tr('settings.restart'),
            ),
          ),
        ],
      ),
    ]);
  }

  String _formatLogTime(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  Widget _logRow(Map<String, dynamic> entry) {
    final level = '${entry['level'] ?? 'info'}';
    final time = _formatLogTime('${entry['time'] ?? ''}');
    final msg = '${entry['msg'] ?? ''}';
    final color = switch (level) {
      'error' || 'fatal' => context.nasDanger,
      'warn' => context.nasWarning,
      _ => context.nasTextSecondary,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (time.isNotEmpty)
            SizedBox(
              width: 64,
              child: Text(
                time,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          SizedBox(
            width: 46,
            child: Text(
              logLevelLabel(level),
              style: TextStyle(
                fontSize: NasTokens.fontMicro,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(fontSize: NasTokens.fontCaption),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logsSection() {
    // 服务端已经按级别过滤过，这里直接渲染本页，不再做二次筛选
    final entries = _logs?.lines ?? const <Map<String, dynamic>>[];
    return _section(tr('settings.nav.logs'), [
      Row(
        children: [
          Expanded(
            child: Text(
              _logs == null
                  ? ''
                  : '${_logs!.file} · ${formatBytes(_logs!.size)}',
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
          if (_logs?.truncated == true)
            Text(
              tr('settings.logsTruncated', {'lines': '${entries.length}'}),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
        ],
      ),
      const SizedBox(height: NasTokens.spaceSm),
      SizedBox(
        width: 200,
        child: NasDropdown<String>(
          initialValue: _logsLevel,
          isDense: true,
          decoration: InputDecoration(
            labelText: tr('settings.logsFilter'),
            isDense: true,
          ),
          items: [
            DropdownMenuItem(
              value: 'errorWarn',
              child: Text(tr('settings.logsLevelErrorWarn')),
            ),
            DropdownMenuItem(
              value: 'error',
              child: Text(tr('settings.logsLevelError')),
            ),
            DropdownMenuItem(
              value: 'warn',
              child: Text(tr('settings.logsLevelWarn')),
            ),
            DropdownMenuItem(
              value: 'info',
              child: Text(tr('settings.logsLevelInfo')),
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _logsLevel = v);
            _loadLogs(resetPage: true);
          },
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        secondary: const Icon(Icons.autorenew_outlined),
        title: Text(tr('settings.logsAutoRefresh')),
        value: _logsAuto,
        onChanged: _setLogsAuto,
      ),
      const SizedBox(height: NasTokens.spaceSm),
      Row(
        children: [
          SizedBox(
            width: 180,
            child: NasDropdown<int>(
              value: _logPageSize,
              isDense: true,
              decoration: InputDecoration(
                labelText: tr('photo.preview.pageSize'),
                isDense: true,
              ),
              items: [
                for (final n in const [20, 50, 100, 200])
                  DropdownMenuItem<int>(
                    value: n,
                    child: Text(tr('blog.episodes.perPage', {'count': '$n'})),
                  ),
              ],
              onChanged: (v) {
                if (v == null || v == _logPageSize) return;
                setState(() => _logPageSize = v);
                _loadLogs(resetPage: true);
              },
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: tr('accounts.fileLog.prev'),
            icon: const Icon(Icons.chevron_left),
            onPressed:
                _logPage > 0 && !_logsLoading ? () => _goLogPage(_logPage - 1) : null,
          ),
          Text('${_logPage + 1}'),
          IconButton(
            tooltip: tr('accounts.fileLog.next'),
            icon: const Icon(Icons.chevron_right),
            onPressed: (_logs?.hasMore ?? false) && !_logsLoading
                ? () => _goLogPage(_logPage + 1)
                : null,
          ),
        ],
      ),
      const Divider(height: 1),
      if (_logsLoading)
        const Padding(
          padding: EdgeInsets.only(top: NasTokens.spaceSm),
          child: LinearProgressIndicator(),
        ),
      if (_logsError != null) ...[
        const SizedBox(height: NasTokens.spaceSm),
        Text(_logsError!, style: TextStyle(color: context.nasDanger)),
        const SizedBox(height: NasTokens.spaceSm),
        OutlinedButton(onPressed: _loadLogs, child: Text(tr('common.retry'))),
      ] else if (entries.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: NasTokens.spaceSm),
          child: Text(
            _logsLoading ? tr('common.loading') : tr('settings.logsEmpty'),
            style: TextStyle(color: context.nasTextSecondary),
          ),
        )
      else
        Container(
          margin: const EdgeInsets.only(top: NasTokens.spaceSm),
          padding: const EdgeInsets.all(NasTokens.spaceSm),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          ),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final entry in entries) _logRow(entry)],
            ),
          ),
        ),
    ]);
  }

  Widget _about() {
    return _section(tr('settings.about'), [
      Text(
        tr('settings.version', {'version': kAppVersion}),
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: NasTokens.spaceXs),
      Text(
        tr('ui.settings.h4b0e3b'),
        style: TextStyle(color: context.nasTextSecondary),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      Wrap(
        spacing: NasTokens.spaceSm,
        runSpacing: NasTokens.spaceXs,
        children: [
          OutlinedButton.icon(
            onPressed: _checkingUpdate ? null : _checkUpdate,
            icon: const Icon(Icons.system_update_alt, size: 18),
            label: Text(
              _checkingUpdate ? tr('common.loading') : tr('settings.update'),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => ApiSession.instance.logout(),
            icon: const Icon(Icons.logout),
            label: Text(tr('ui.settings.016')),
          ),
        ],
      ),
      if (_updateText != null) ...[
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          _updateText!,
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
      ],
      const SizedBox(height: NasTokens.spaceMd),
      Text(
        tr('settings.legal'),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      Text(
        tr('settings.legalHint'),
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          color: context.nasTextSecondary,
        ),
      ),
    ]);
  }

  void _refreshCurrent() {
    if (_tab == 'logs') {
      _loadLogs();
      return;
    }
    if (_tab == 'appearance') return;
    if (_tab == 'other') {
      _loadCache();
      return;
    }
    _loadServer();
  }

  /// 当前分组的内容（二级导航只换这里，不重建整页）
  List<Widget> _tabChildren() {
    switch (_tab) {
      case 'appearance':
        return [
          _appearance(),
          _language(),
          const SizedBox(height: NasTokens.spaceLg),
        ];
      case 'logs':
        return [_logsSection(), const SizedBox(height: NasTokens.spaceLg)];
      case 'other':
        return [
          _maintenance(),
          _about(),
          const SizedBox(height: NasTokens.spaceLg),
        ];
      default:
        return [
          _serverSection(),
          _llmSection(),
          _connection(),
          const SizedBox(height: NasTokens.spaceLg),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = ListView(
      padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
      children: _tabChildren(),
    );
    final tabs = <NasTabItem>[
      NasTabItem(
        id: 'server',
        label: tr('settings.nav.server'),
        icon: Icons.dns_outlined,
      ),
      NasTabItem(
        id: 'appearance',
        label: tr('settings.nav.appearance'),
        icon: Icons.palette_outlined,
      ),
      NasTabItem(
        id: 'logs',
        label: tr('settings.nav.logs'),
        icon: Icons.receipt_long_outlined,
      ),
      NasTabItem(
        id: 'other',
        label: tr('settings.nav.other'),
        icon: Icons.tune_outlined,
      ),
    ];

    // 手机端：设置的 4 个分区从左侧栏搬到下方
    if (isCompactWidth(context)) {
      return NasAppScaffold(
        title: tr('ui.settings.017'),
        onHome: AppNavShell.onExitToHome,
        actions: [
          NasMobileAction(
            icon: Icons.refresh,
            tooltip: tr('common.refresh'),
            onPressed: _refreshCurrent,
          ),
        ],
        items: tabs,
        selectedId: _tab,
        onSelect: _selectTab,
        body: content,
      );
    }

    return Scaffold(
      appBar: nasPageAppBar(
        context,
        title: tr('ui.settings.017'),
        actions: [
          NasRefreshButton(
            tooltip: tr('common.refresh'),
            onPressed: _refreshCurrent,
          ),
        ],
      ),
      body: Row(
        children: [
          NasSideNav(
            groups: [
              NasNavGroup(
                entries: [
                  NasNavEntry(
                    id: 'server',
                    label: tr('settings.nav.server'),
                    icon: Icons.dns_outlined,
                  ),
                  NasNavEntry(
                    id: 'appearance',
                    label: tr('settings.nav.appearance'),
                    icon: Icons.palette_outlined,
                  ),
                  NasNavEntry(
                    id: 'logs',
                    label: tr('settings.nav.logs'),
                    icon: Icons.receipt_long_outlined,
                  ),
                  NasNavEntry(
                    id: 'other',
                    label: tr('settings.nav.other'),
                    icon: Icons.tune_outlined,
                  ),
                ],
              ),
            ],
            selectedId: _tab,
            onSelect: _selectTab,
            width: _navCollapsed ? 56 : 128,
            iconOnly: _navCollapsed,
            title: tr('ui.settings.017'),
            onToggleCollapsed: _toggleNavCollapsed,
            expandTooltip: tr('nav.expand'),
            collapseTooltip: tr('nav.collapse'),
            debugLabel: 'settings',
          ),
          const VerticalDivider(width: 1),
          Expanded(child: content),
        ],
      ),
    );
  }
}
