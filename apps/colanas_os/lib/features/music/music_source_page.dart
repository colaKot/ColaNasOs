import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import 'music_settings_pages.dart';
import '../sync/sync_remote_dir_picker.dart';

/// 音乐来源管理：列出已添加的目录，能「添加 / 扫描 / 删除」。
///
/// 一个目录就是一个来源，用户在这里点「添加来源」选目录即可，不需要理解「库」的概念。
/// 之前这个入口只有「扫描」，没有任何地方能加目录 —— 新装机器上音乐页永远是空的。
class MusicSourcePage extends StatefulWidget {
  const MusicSourcePage({super.key});

  @override
  State<MusicSourcePage> createState() => _MusicSourcePageState();
}

class _MusicSourcePageState extends State<MusicSourcePage> {
  bool _loading = true;
  String? _error;
  bool _busy = false;
  List<MusicLibraryItem> _sources = const [];

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
      final res = await ApiSession.instance.client.musicLibraryList();
      if (!mounted) return;
      setState(() {
        _sources = res.items;
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

  Future<void> _add() async {
    final path = await showSyncRemoteDirPicker(context);
    if (path == null || path.isEmpty || !mounted) return;
    final name = await _promptName(path);
    if (name == null || name.isEmpty || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    String createdId;
    try {
      final created = await ApiSession.instance.client.musicLibraryCreate(
        body: MusicLibraryCreateBody(name: name, path: path),
      );
      createdId = created.id;
    } catch (e) {
      if (mounted) {
        NasSnack.showOn(messenger, '${tr('common.error')}：$e');
        setState(() => _busy = false);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    NasSnack.showOn(messenger, tr('music.source.added'));

    // 加完立刻扫一遍：以前只建库不扫描，用户加完来源看到 0 首，
    // 以为「什么都没发生」——扫描本来就是这个操作的后半截，不该再让人手动点。
    await _scan(createdId, announce: true);
  }

  Future<String?> _promptName(String path) {
    final fallback = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
    final ctrl = TextEditingController(text: fallback);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('music.source.name')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('music.source.nameHint')),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('common.confirm')),
          ),
        ],
      ),
    );
  }

  Future<void> _scan(String? libraryId, {bool announce = false}) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      // 走任务队列而不是同步扫描：整库动辄几千首，同步接口会超过客户端 30s
      // 超时并表现成「扫描失败」，服务端其实还在跑。进度统一在「任务」里看。
      final res = await ApiSession.instance.client.musicScanEnqueue(
        body: MusicScanBody(
          // 扫描策略来自「音乐设置」：清理已删曲目 / 单次上限
          libraryId: libraryId,
          limit: MusicAppSettingsPage.readLimit(),
          prune: MusicAppSettingsPage.readPrune(),
        ),
      );
      final tasks = (res['tasks'] as List?) ?? const [];
      final reused = tasks.isNotEmpty && (tasks.first as Map)['reused'] == true;
      if (!mounted) return;
      NasSnack.showOn(
        messenger,
        tr(reused ? 'music.scanAlreadyRunning' : 'music.scanQueued'),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.showOn(messenger, '${tr('common.error')}：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(MusicLibraryItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('music.source.remove')),
        content: Text(tr('music.source.removeConfirm', {'name': item.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.musicLibraryRemove(
        body: MusicLibraryRemoveBody(id: item.id),
      );
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('music.source.removed'));
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.showOn(messenger, '${tr('common.error')}：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);

    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr('music.source.title'),
                style: const TextStyle(
                  fontSize: NasTokens.fontSubtitle,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _busy || _sources.isEmpty ? null : () => _scan(null),
              icon: const Icon(Icons.sync, size: 18),
              label: Text(tr('common.scanAll')),
            ),
            NasRefreshButton(onPressed: _busy ? null : _load),
          ],
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          tr('music.source.hint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        // 扫描是同步请求（大库要几十秒），没有进度条的话界面像卡死
        if (_busy) ...[
          const SizedBox(height: NasTokens.spaceSm),
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            tr('music.source.scanning'),
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
        ],
        const SizedBox(height: NasTokens.spaceMd),
        if (_sources.isEmpty)
          NasEmptyState(
            title: tr('music.source.empty'),
            message: tr('music.source.emptyHint'),
            icon: Icons.library_music_outlined,
          ),
        for (final item in _sources) ...[
          _sourceCard(item),
          const SizedBox(height: NasTokens.spaceSm),
        ],
        const SizedBox(height: NasTokens.spaceSm),
        _addCard(),
      ],
    );
  }

  Widget _sourceCard(MusicLibraryItem item) {
    final scheme = Theme.of(context).colorScheme;
    final scanned = item.lastScanAt == null
        ? tr('music.source.neverScanned')
        : tr('music.source.scannedAt', {
            'date': _formatTime(item.lastScanAt!),
          });
    return NasCard(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, color: scheme.primary),
          const SizedBox(width: NasTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NasTokens.fontMicro,
                    color: context.nasTextSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${tr('music.source.tracks', {'n': '${item.items}'})} · $scanned',
                  style: TextStyle(
                    fontSize: NasTokens.fontMicro,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: tr('common.scan'),
            onPressed: _busy ? null : () => _scan(item.id),
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: tr('music.source.remove'),
            onPressed: _busy ? null : () => _remove(item),
            icon: Icon(Icons.delete_outline, color: scheme.error),
          ),
        ],
      ),
    );
  }

  Widget _addCard() {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _busy ? null : _add,
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: NasTokens.spaceMd,
          vertical: NasTokens.spaceLg,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          border: Border.all(
            color: scheme.outlineVariant,
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 20, color: scheme.primary),
            const SizedBox(width: NasTokens.spaceXs),
            Text(
              tr('music.source.add'),
              style: TextStyle(
                fontSize: NasTokens.fontBody,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    final y = d.year;
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}
