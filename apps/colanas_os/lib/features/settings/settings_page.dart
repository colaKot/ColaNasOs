import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_settings.dart';
import '../../core/i18n_setup.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'style_preview_page.dart';

/// 设置（配置中心）：服务器 / 主机名 / 欢迎语 / 代理在前，外观 / 语言 / 维护 / 关于在后。
///
/// 媒体库管理已按参考实现移到各模块（相册来源 / 影视库管理 / 音乐库管理 / 书房）。
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
  bool _javFallback = false;
  bool _httpsEnabled = false;
  SystemTlsInfoResponse? _tls;

  SystemCacheInfoResponse? _cache;
  bool _cacheLoading = true;
  bool _clearingCache = false;

  String? _updateText;
  bool _checkingUpdate = false;
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    _loadServer();
    _loadCache();
  }

  @override
  void dispose() {
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
    return null;
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
        _javFallback = s.javFallback;
        _httpsEnabled = s.httpsEnabled;
        _httpsPortCtrl.text = '${s.httpsPort}';
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
          javFallback: _javFallback,
        ),
      );
      if (!mounted) return;
      setState(() {

        _activeProxy = res.activeProxy;
        _proxyCtrl.text = res.settings.proxy;
      });
      messenger.showSnackBar(SnackBar(content: Text(tr('settings.saved'))));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('common.saveFailed', {'error': '${_hint(e) ?? e}'}))),
      );
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
      messenger.showSnackBar(
        SnackBar(content: Text(tr('settings.tlsUploaded'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('common.saveFailed', {'error': '${_hint(e) ?? e}'}))),
      );
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
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('settings.cacheClear')),
        content: Text(tr('settings.cacheUsage', {
          'size': formatBytes(_cache?.bytes ?? 0),
          'files': '${_cache?.files ?? 0}',
        })),
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
      messenger.showSnackBar(
        SnackBar(content: Text(tr('settings.cacheCleared', {'size': formatBytes(res.freedBytes)}))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('common.errorWith', {'error': '${_hint(e) ?? e}'}))),
      );
    } finally {
      if (mounted) setState(() => _clearingCache = false);
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
      messenger.showSnackBar(SnackBar(content: Text(tr('settings.restarting'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _restarting = false);
      messenger.showSnackBar(
        SnackBar(content: Text(tr('common.errorWith', {'error': '${_hint(e) ?? e}'}))),
      );
    }
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      final res = await ApiSession.instance.client.systemUpdateCheck();
      if (!mounted) return;
      setState(() {
        _updateText = res.hasUpdate
            ? tr('settings.updateAvailable', {'version': '${res.latestVersion}'})
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('settings.switched', {'url': ApiSession.instance.baseUrl}))),
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

  Widget _serverSection() {
    if (_loadingServer) {
      return _section(tr('settings.server'), [
        const LinearProgressIndicator(),
      ]);
    }
    if (_serverForbidden) {
      return _section(tr('settings.server'), [
        Text(tr('settings.needAdmin'), style: TextStyle(color: context.nasTextSecondary)),
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
              decoration: InputDecoration(labelText: tr('settings.port'), isDense: true),
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          SizedBox(
            width: 170,
            child: TextField(
              controller: _concurrencyCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('settings.concurrency'), isDense: true),
            ),
          ),
        ],
      ),
      const SizedBox(height: NasTokens.spaceXs),
      Text(
        tr('settings.restartHint'),
        style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _hostnameCtrl,
        maxLength: 10,
        decoration: InputDecoration(labelText: tr('settings.hostname'), helperText: tr('settings.hostnameHint'), isDense: true),
      ),
      TextField(
        controller: _welcomeCtrl,
        maxLength: 100,
        decoration: InputDecoration(labelText: tr('settings.welcome'), helperText: tr('settings.welcomeHint'), isDense: true),
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
        style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(tr('settings.javFallback')),
        subtitle: Text(
          tr('settings.javFallbackHint'),
          style: TextStyle(fontSize: NasTokens.fontCaption),
        ),
        value: _javFallback,
        onChanged: (v) => setState(() => _javFallback = v),
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
              ChoiceChip(
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
            DropdownButton<String>(
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
              ChoiceChip(
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
              ChoiceChip(
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
        builder: (context, _, _) => DropdownButton<String>(
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
        tr('settings.account', {'name': ApiSession.instance.username ?? tr('settings.notLoggedIn')}),
        style: TextStyle(color: context.nasTextSecondary),
      ),
    ]);
  }

  Widget _maintenance() {
    return _section(tr('ui.settings.h59156f'), [
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
                  style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: _clearingCache ? null : _clearCache,
            icon: const Icon(Icons.cleaning_services_outlined, size: 18),
            label: Text(_clearingCache ? tr('common.loading') : tr('settings.cacheClear')),
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
            label: Text(_restarting ? tr('settings.restarting') : tr('settings.restart')),
          ),
        ],
      ),
      const SizedBox(height: NasTokens.spaceMd),
      OutlinedButton.icon(
        onPressed: _reindexBook,
        icon: const Icon(Icons.manage_search),
        label: Text(tr('ui.settings.015')),
      ),
      const SizedBox(height: NasTokens.spaceXs),
      Text(
        tr('ui.settings.h6536fe'),
        style: TextStyle(color: context.nasTextSecondary),
      ),
    ]);
  }

  Future<void> _reindexBook() async {
    try {
      final res = await ApiSession.instance.client.bookFulltextReindex(
        body: const BookFulltextReindexBody(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('settings.reindexDone', {'indexed': '${res.indexed}', 'skipped': '${res.skipped}'}))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('settings.rebuildFailed', {'error': '${_hint(e) ?? e}'}))));
    }
  }

  Widget _about() {
    return _section(tr('settings.about'), [
      Text(tr('settings.version', {'version': '1.0.0'}), style: Theme.of(context).textTheme.bodyLarge),
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
            label: Text(_checkingUpdate ? tr('common.loading') : tr('settings.update')),
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
          style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
        ),
      ],
      const SizedBox(height: NasTokens.spaceMd),
      Text(
        tr('settings.legal'),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      Text(
        tr('settings.legalHint'),
        style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('ui.settings.017')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr('ui.settings.018'),
            onPressed: () {
              _loadServer();
              _loadCache();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
        children: [
          _serverSection(),
          _appearance(),
          _language(),
          _connection(),
          _maintenance(),
          _section(tr('settings.mediaSection'), [
            Text(
              tr('settings.librariesMoved'),
              style: TextStyle(color: context.nasTextSecondary),
            ),
          ]),
          _about(),
          const SizedBox(height: NasTokens.spaceLg),
        ],
      ),
    );
  }
}