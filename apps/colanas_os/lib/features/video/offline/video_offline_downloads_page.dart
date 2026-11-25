import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../player_page.dart';
import 'offline_download_manager.dart';
import 'offline_models.dart';
import 'offline_preferences.dart';
import 'offline_store.dart';

/// 影视 → 合集 → 下载管理。
///
/// 三个页签对应任务生命周期的三段：
///   进行中 —— 排队 / 转码 / 下载 / 等 WiFi / 已暂停，可暂停、继续、取消；
///   失败 —— 自动重试耗尽或编码失败，可重试（新的一次机会）或删掉任务；
///   已完成 —— 直接从本地库读（任务记录在入库时就删了），可播放或删文件。
///
/// 为什么不给已完成单独存一份任务历史：本地库里的条目本来就带着规格、体积和
/// 下载时间，再造一份「历史任务」只会让两边的数据打架。
class VideoOfflineDownloadsPage extends StatefulWidget {
  const VideoOfflineDownloadsPage({super.key});

  @override
  State<VideoOfflineDownloadsPage> createState() => _VideoOfflineDownloadsPageState();
}

class _VideoOfflineDownloadsPageState extends State<VideoOfflineDownloadsPage> {
  OfflineStore? _store;
  bool _loading = true;
  int _tab = 0;

  /// 正在查占用 / 跑清理：按钮转圈并禁用，避免连点
  bool _cleaning = false;

  /// 每条正在下载的任务上一次采样（算实时速度用）
  final Map<String, _SpeedSample> _speedSamples = {};

  @override
  void initState() {
    super.initState();
    OfflineDownloadManager.instance.tasks.addListener(_onChanged);
    OfflineDownloadManager.instance.libraryRevision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    OfflineDownloadManager.instance.tasks.removeListener(_onChanged);
    OfflineDownloadManager.instance.libraryRevision.removeListener(_load);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final store = await OfflineDownloadManager.instance.ensureStore();
      if (!mounted) return;
      setState(() {
        _store = store;
        _loading = false;
      });
    } catch (_) {
      // 目录拿不到（测试环境没有 path_provider / 磁盘被拔）：
      // 按空列表显示，别把整页炸掉
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final manager = OfflineDownloadManager.instance;
    final tasks = manager.tasks.value;
    final active = tasks.where((t) => t.active).toList();
    final failed = tasks.where((t) => t.state == OfflineTaskState.failed).toList();
    final done = (_store?.items.values.toList() ?? <LocalMediaItem>[])
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(NasTokens.spaceMd, 10, NasTokens.spaceMd, 6),
          child: Row(
            children: [
              Expanded(
                child: NasPillTabs(
                  labels: [
                    tr('video.offline.tabActive'),
                    tr('video.offline.tabFailed'),
                    tr('video.offline.tabDone'),
                  ],
                  counts: [
                    active.isEmpty ? null : active.length,
                    failed.isEmpty ? null : failed.length,
                    done.isEmpty ? null : done.length,
                  ],
                  selectedIndex: _tab,
                  onSelect: (i) => setState(() => _tab = i),
                ),
              ),
              // 下载设置：仅 WiFi / 限速 / 多连接加速，以及「清理服务端产物」
              // （清理原来直接放在这里，占一个文字按钮太显眼，收进设置里更合理）
              IconButton(
                tooltip: tr('video.offline.downloadSettings'),
                onPressed: _cleaning ? null : _openDownloadSettings,
                icon: _cleaning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.tune, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (_tab) {
            1 => _failedList(failed),
            2 => _doneList(done),
            _ => _activeList(active),
          },
        ),
      ],
    );
  }

  Widget _empty(String text) => Center(
    child: Text(text, style: TextStyle(color: context.nasTextSecondary)),
  );

  /// 「清理服务端产物」：先报占用，再让用户选保留多久，最后报释放了多少。
  ///
  /// 服务端那份转码产物只是「下载用的中转副本」：留着是为了同参数再下一次时
  /// 免重编，不清就会一直堆在 NAS 盘上，所以给一个显式出口。
  /// 下载设置的入口：面板里的「清理服务端产物」关掉面板后回这里开清理对话框。
  Future<void> _openDownloadSettings() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _DownloadSettingsSheet(),
    );
    if (!mounted || action != 'cleanup') return;
    await _openServerCleanup();
  }

  /// 实时速度：每 700ms 采一次「已下字节」的差，太快采样会被抖动带偏。
  double _sampleSpeed(OfflineTaskRecord task) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final prev = _speedSamples[task.itemId];
    if (prev == null) {
      _speedSamples[task.itemId] = _SpeedSample(task.downloadedBytes, now, 0);
      return 0;
    }
    if (now - prev.at < 700) return prev.bps;
    final dt = (now - prev.at) / 1000.0;
    final delta = task.downloadedBytes - prev.bytes;
    final bps = (dt > 0 && delta > 0) ? delta / dt : 0.0;
    _speedSamples[task.itemId] = _SpeedSample(task.downloadedBytes, now, bps);
    return bps;
  }

  Future<void> _openServerCleanup() async {
    if (_cleaning) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _cleaning = true);
    OfflineStorageUsage usage;
    try {
      usage = await OfflineDownloadManager.instance.serverStorage();
    } catch (e) {
      if (mounted) setState(() => _cleaning = false);
      NasSnack.showOn(
        messenger,
        tr('video.offline.serverCleanupFailed', {'error': '$e'}),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _cleaning = false);
    if (usage.count <= 0) {
      NasSnack.showOn(messenger, tr('video.offline.serverUsageEmpty'));
      return;
    }

    final days = await showDialog<int>(
      context: context,
      builder: (_) => _ServerCleanupDialog(usage: usage),
    );
    if (days == null || !mounted) return;

    setState(() => _cleaning = true);
    try {
      // days == 0 是「全部清理」：带上 force，服务端才不会把刚转好的产物
      // 当成「客户端正要来取」而跳过（否则点了等于没点）。
      final res = await OfflineDownloadManager.instance.cleanupServerArtifacts(
        olderThanDays: days,
        force: days == 0,
      );
      final done = tr('video.offline.serverCleanupDone', {
        'count': '${res.removed}',
        'size': formatBytes(res.freedBytes),
      });
      final skippedText = tr('video.offline.serverCleanupSkipped', {
        'count': '${res.skipped}',
      });
      NasSnack.showOn(
        messenger,
        res.removed > 0
            // 有删有跳：两句都说清楚，不然「删了 2 个」会让人以为全清了
            ? (res.skipped > 0 ? '$done · $skippedText' : done)
            : (res.skipped > 0 ? skippedText : tr('video.offline.serverCleanupNone')),
      );
    } catch (e) {
      NasSnack.showOn(
        messenger,
        tr('video.offline.serverCleanupFailed', {'error': '$e'}),
      );
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  // ---------------------------------------------------------------- 进行中

  /// 阶段文案 + 该阶段的百分比（排队、校验这类阶段没有百分比就返回 null）。
  ///
  /// 百分比按**当前阶段**算，不用 `task.overall`：整体进度里转码只占前 30%，
  /// 直接显示会让转码到一半的片子看着像刚起步。
  (String, int?) _stageOf(OfflineTaskRecord task) {
    switch (task.state) {
      case OfflineTaskState.waitingWifi:
        return (tr('video.offline.waitingWifi'), null);
      case OfflineTaskState.paused:
        return (tr('video.offline.pausedState'), null);
      case OfflineTaskState.queued:
        return (tr('video.offline.stageQueued'), null);
      case OfflineTaskState.transcoding:
        final pct = (task.progress * 100).clamp(0, 100).round();
        return (tr('video.offline.stageTranscoding', {'percent': '$pct'}), pct);
      case OfflineTaskState.downloading:
        if (task.totalBytes <= 0) return (tr('video.offline.downloading'), null);
        final pct = (task.downloadedBytes * 100 / task.totalBytes)
            .clamp(0, 100)
            .round();
        // 带速度：用户抱怨「慢」时，第一个问题就是「现在到底多少」
        final bps = _sampleSpeed(task);
        final speed = bps > 0 ? ' · ${formatBytes(bps.round())}/s' : '';
        return (
          '${tr('video.offline.stageDownloading', {'percent': '$pct'})} · '
              '${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)}$speed',
          pct,
        );
      case OfflineTaskState.verifying:
        return (tr('video.offline.stageVerifying'), null);
      case OfflineTaskState.replacing:
        return (tr('video.offline.stageReplacing'), null);
      default:
        return (tr('video.offline.downloading'), null);
    }
  }

  Widget _activeList(List<OfflineTaskRecord> tasks) {
    if (tasks.isEmpty) return _empty(tr('video.offline.empty'));
    return ListView.separated(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      itemCount: tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final task = tasks[i];
        final paused =
            task.state == OfflineTaskState.paused || task.state == OfflineTaskState.waitingWifi;
        final (label, percent) = _stageOf(task);
        return _card(
          title: task.title,
          subtitle: label,
          progress: task.overall,
          percent: percent,
          showProgress: true,
          actions: [
            if (paused)
              TextButton(
                onPressed: () => OfflineDownloadManager.instance.resume(task.itemId),
                child: Text(tr('video.offline.resume')),
              )
            else
              TextButton(
                onPressed: () => OfflineDownloadManager.instance.pause(task.itemId),
                child: Text(tr('video.offline.pause')),
              ),
            TextButton(
              onPressed: () => OfflineDownloadManager.instance.cancel(task.itemId),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(tr('video.offline.cancel')),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- 失败

  Widget _failedList(List<OfflineTaskRecord> tasks) {
    if (tasks.isEmpty) return _empty(tr('video.offline.empty'));
    return ListView.separated(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      itemCount: tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final task = tasks[i];
        return _card(
          title: task.title,
          subtitle: task.error ?? tr('video.offline.failed'),
          danger: true,
          actions: [
            TextButton(
              onPressed: () => OfflineDownloadManager.instance.retry(task.itemId),
              child: Text(tr('video.offline.retry')),
            ),
            TextButton(
              onPressed: () => OfflineDownloadManager.instance.cancel(task.itemId),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(tr('video.offline.removeTask')),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- 已完成

  Widget _doneList(List<LocalMediaItem> items) {
    if (items.isEmpty) return _empty(tr('video.offline.empty'));
    return ListView.separated(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final item = items[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${item.specLabel}${item.bytes > 0 ? ' · ${formatBytes(item.bytes)}' : ''}',
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          onTap: () => _play(item),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('video.series.play'),
                icon: const Icon(Icons.play_arrow),
                onPressed: () => _play(item),
              ),
              IconButton(
                tooltip: tr('video.offline.deleteTitle'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(item),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _card({
    required String title,
    required String subtitle,
    required List<Widget> actions,
    double? progress,
    int? percent,
    bool showProgress = false,
    bool danger = false,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: context.nasStyle.panelColor,
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        border: Border.all(color: context.nasStyle.panelBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: danger
                  ? Theme.of(context).colorScheme.error
                  : context.nasTextSecondary,
            ),
          ),
          if (showProgress) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                    ),
                  ),
                ),
                // 百分比跟着条一起出现：光看条分不出「刚起步」还是「卡住了」
                if (percent != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '$percent%',
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      fontWeight: FontWeight.w600,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
        ],
      ),
    );
  }

  Future<void> _play(LocalMediaItem item) async {
    final store = _store;
    if (store == null) return;
    final file = File(store.absolute(item.filePath));
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(tr('video.offline.empty'))));
      await _load();
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          url: file.uri.toString(),
          title: item.title,
          durationMs: item.durationMs > 0 ? item.durationMs : null,
          startAt: item.playbackMs > 5000 ? Duration(milliseconds: item.playbackMs) : null,
          onPosition: (pos) => OfflineDownloadManager.instance
              .savePlayback(item.id, pos.inMilliseconds)
              .ignore(),
          localSubtitles: [
            for (final rel in item.subtitlePaths) store.absolute(rel),
          ],
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _delete(LocalMediaItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.offline.deleteTitle')),
        content: Text(tr('video.offline.deleteBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('video.offline.deleteSelected', {'n': '1'})),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await OfflineDownloadManager.instance.deleteItems([item.id]);
    if (mounted) await _load();
  }
}

/// 清理服务端产物的确认框。返回值是「只清多少天前的」，`0` = 全清，null = 取消。
class _ServerCleanupDialog extends StatefulWidget {
  const _ServerCleanupDialog({required this.usage});

  final OfflineStorageUsage usage;

  @override
  State<_ServerCleanupDialog> createState() => _ServerCleanupDialogState();
}

class _ServerCleanupDialogState extends State<_ServerCleanupDialog> {
  /// 默认保守：只清三天前用过的，今天刚下过的产物留着（可能还要在别的设备上再下一次）
  int _days = 3;

  @override
  Widget build(BuildContext context) {
    final usage = widget.usage;
    return AlertDialog(
      title: Text(tr('video.offline.serverCleanupTitle')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('video.offline.serverUsage', {
              'count': '${usage.count}',
              'size': formatBytes(usage.bytes),
            }),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (usage.oldestDays > 0)
            Text(
              tr('video.offline.serverOldest', {'days': '${usage.oldestDays}'}),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          const SizedBox(height: NasTokens.spaceSm),
          Text(
            tr('video.offline.serverCleanupHint'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          const SizedBox(height: NasTokens.spaceSm),
          _option(3, tr('video.offline.serverKeepRecent')),
          _option(0, tr('video.offline.serverKeepAll')),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _days),
          child: Text(tr('video.offline.serverCleanup')),
        ),
      ],
    );
  }

  /// 自己画单选项：RadioListTile 的 groupValue/onChanged 在新 SDK 上已废弃，
  /// 这里只是一行「图标 + 文案」，不值得为它引一套 RadioGroup。
  Widget _option(int days, String label) {
    final scheme = Theme.of(context).colorScheme;
    final on = _days == days;
    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      onTap: () => setState(() => _days = days),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(
              on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: on ? scheme.primary : context.nasTextSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: NasTokens.fontBody,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 下载速度的一次采样（算差速用）
class _SpeedSample {
  const _SpeedSample(this.bytes, this.at, this.bps);

  final int bytes;
  final int at;
  final double bps;
}

/// 下载设置面板：仅 WiFi / 限速 / 多连接加速，外加「清理服务端产物」的入口。
///
/// 用底部面板而不是又一个设置页：这几个开关都是「下载的时候才想起来要改」，
/// 放在下载页里点两下就能改，不用跳走再跳回来。
class _DownloadSettingsSheet extends StatefulWidget {
  const _DownloadSettingsSheet();

  @override
  State<_DownloadSettingsSheet> createState() => _DownloadSettingsSheetState();
}

class _DownloadSettingsSheetState extends State<_DownloadSettingsSheet> {
  late bool _wifiOnly = OfflinePreferences.wifiOnly;
  late int _maxKbps = OfflinePreferences.maxKbps;
  late bool _multi = OfflinePreferences.connections > 1;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            value: _wifiOnly,
            title: Text(tr('video.offline.wifiOnly')),
            subtitle: Text(tr('video.offline.wifiOnlyHint')),
            onChanged: (v) async {
              setState(() => _wifiOnly = v);
              await OfflinePreferences.setWifiOnly(v);
            },
          ),
          ListTile(
            title: Text(tr('video.offline.speedLimit')),
            subtitle: Text(tr('video.offline.speedHint')),
            trailing: NasDropdown<int>(
              value: _maxKbps,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(
                  value: 0,
                  child: Text(tr('video.offline.speedUnlimited')),
                ),
                for (final kbps in <int>[2000, 5000, 10000, 20000])
                  DropdownMenuItem(
                    value: kbps,
                    child: Text('${kbps ~/ 1000} MB/s'),
                  ),
              ],
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _maxKbps = v);
                await OfflinePreferences.setMaxKbps(v);
              },
            ),
          ),
          SwitchListTile(
            value: _multi,
            title: Text(tr('video.offline.multiConn')),
            subtitle: Text(tr('video.offline.multiConnHint')),
            onChanged: (v) async {
              setState(() => _multi = v);
              await OfflinePreferences.setConnections(v ? 4 : 1);
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              Icons.cleaning_services_outlined,
              color: scheme.onSurface,
            ),
            title: Text(tr('video.offline.serverCleanup')),
            subtitle: Text(tr('video.offline.serverCleanupHint')),
            onTap: () => Navigator.pop(context, 'cleanup'),
          ),
        ],
      ),
    );
  }
}
