import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';

/// 音乐设置（服务端侧）：扫描策略。
///
/// 这两项直接影响「扫描」这个动作本身，所以放在服务端设置里而不是客户端设置：
/// 换台设备连同一台 NAS，扫描行为应该一致。
class MusicAppSettingsPage extends StatefulWidget {
  const MusicAppSettingsPage({super.key});

  /// 扫描后是否把「磁盘上已不存在」的曲目从索引里清掉
  static const String pruneKey = 'music.scan.prune';

  /// 单次扫描最多收多少首（兜住误选整个盘的场景）
  static const String limitKey = 'music.scan.limit';
  static const int defaultLimit = 20000;

  static bool readPrune() =>
      SettingsStore.instance.getBool(pruneKey) ?? true;

  static int readLimit() =>
      SettingsStore.instance.getInt(limitKey) ?? defaultLimit;

  @override
  State<MusicAppSettingsPage> createState() => _MusicAppSettingsPageState();
}

class _MusicAppSettingsPageState extends State<MusicAppSettingsPage> {
  late bool _prune = MusicAppSettingsPage.readPrune();
  late final TextEditingController _limitCtrl = TextEditingController(
    text: '${MusicAppSettingsPage.readLimit()}',
  );

  @override
  void dispose() {
    _limitCtrl.dispose();
    super.dispose();
  }

  Future<void> _setPrune(bool value) async {
    setState(() => _prune = value);
    await SettingsStore.instance.setBool(MusicAppSettingsPage.pruneKey, value);
  }

  Future<void> _setLimit(String raw) async {
    final n = int.tryParse(raw.trim());
    if (n == null || n <= 0) return;
    await SettingsStore.instance.setInt(MusicAppSettingsPage.limitKey, n);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        Text(
          tr('music.settings.scanTitle'),
          style: const TextStyle(
            fontSize: NasTokens.fontSubtitle,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: NasTokens.spaceSm),
        NasCard(
          padding: EdgeInsets.zero,
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                SwitchListTile(
                  value: _prune,
                  onChanged: _setPrune,
                  title: Text(tr('music.settings.prune')),
                  subtitle: Text(
                    tr('music.settings.pruneHint'),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: Text(tr('music.settings.limit')),
                  trailing: SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _limitCtrl,
                      textAlign: TextAlign.end,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(isDense: true),
                      onSubmitted: _setLimit,
                      onEditingComplete: () => _setLimit(_limitCtrl.text),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 客户端设置（本机）：播放缓存占用与清理。
///
/// 缓存是本机的（同一台 NAS 在不同设备上各有一份），所以归到客户端侧。
/// 清掉不影响曲库索引，下次播放会重新转码。
class MusicClientSettingsPage extends StatefulWidget {
  const MusicClientSettingsPage({super.key});

  @override
  State<MusicClientSettingsPage> createState() =>
      _MusicClientSettingsPageState();
}

class _MusicClientSettingsPageState extends State<MusicClientSettingsPage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _files = 0;
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.musicCacheStats();
      if (!mounted) return;
      setState(() {
        _files = res.files;
        _bytes = res.bytes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.musicCacheClear();
      if (!mounted) return;
      NasSnack.showOn(
        messenger,
        tr('music.client.cleared', {'size': formatBytes(res.bytes)}),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.showOn(messenger, '${tr('common.error')}：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        Text(
          tr('music.client.cacheTitle'),
          style: const TextStyle(
            fontSize: NasTokens.fontSubtitle,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: NasTokens.spaceSm),
        NasCard(
          padding: const EdgeInsets.all(NasTokens.spaceMd),
          child: Row(
            children: [
              const Icon(Icons.sd_storage_outlined),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('music.client.cacheUsed', {
                        'files': '$_files',
                        'size': formatBytes(_bytes),
                      }),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('music.client.cacheHint'),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              TextButton(
                onPressed: _busy || _files == 0 ? null : _clear,
                child: Text(tr('music.client.clearCache')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
