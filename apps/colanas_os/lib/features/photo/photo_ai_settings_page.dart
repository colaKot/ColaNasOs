import 'dart:async';
import '../../shell/app_widgets.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// AI 设置：任务进度 / MCP 开放平台 / GPU / 识别模块开关 / 人脸参数。
class PhotoAiSettingsPage extends StatefulWidget {
  const PhotoAiSettingsPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<PhotoAiSettingsPage> createState() => _PhotoAiSettingsPageState();
}

class _PhotoAiSettingsPageState extends State<PhotoAiSettingsPage> {
  bool _loading = true;
  String? _error;
  PhotoAiSettings? _settings;
  PhotoMcpStatus? _mcp;
  List<Map<String, dynamic>> _users = const [];

  double _matchSim = 0.45;
  int _minVotes = 2;
  int _threads = 3;

  Timer? _timer;
  bool _busy = false;

  /// 连续批处理的实时进度（`已处理 / 总量`）；null = 没在跑
  String? _progressText;

  ApiClient get _client => ApiSession.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _client.photoAiConfig(),
        _client.photoMcpStatus(),
      ]);
      final settings = results[0] as PhotoAiSettings;
      final users = <Map<String, dynamic>>[];
      try {
        final raw = await _client.userList();
        final items = raw['items'] as List<dynamic>? ?? const [];
        for (final item in items) {
          if (item is Map<String, dynamic>) users.add(item);
        }
      } catch (_) {
        /* 普通用户没有账号列表权限时只显示当前挂载 uid */
      }
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _mcp = results[1] as PhotoMcpStatus;
        _users = users;
        _matchSim = settings.config.tuning.matchSim;
        _minVotes = settings.config.tuning.minVotes;
        _threads = settings.config.tuning.threads;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    try {
      final results = await Future.wait([
        _client.photoAiConfig(),
        _client.photoMcpStatus(),
      ]);
      if (!mounted) return;
      setState(() {
        _settings = results[0] as PhotoAiSettings;
        _mcp = results[1] as PhotoMcpStatus;
      });
    } catch (_) {
      /* 轮询失败保持上一屏，不弹错误 */
    }
  }

  Future<void> _run(String label, Future<Object?> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await job();
      if (!mounted) return;
      final msg = res is PhotoAiOpResponse
          ? (res.message ?? label)
          : res is PhotoAiTuningResponse
              ? tr('photo.ai.saved')
              : label;
      NasSnack.show(context, msg);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 提交整库识别到内核队列（`photo.ai.scan`）。
  ///
  /// 以前是客户端循环调 analyze（每次 20 张）：客户端一关 / 服务端一重启就断，
  /// 表现就是「识别没跑完，再打开也不会继续」。入队之后内核重启会由队列
  /// recover() 接着跑，进度靠页面 5 秒轮询的 config 反映。
  Future<void> _queueScan({
    bool ocr = false,
    bool activity = false,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await _client.photoAiScan(
        body: PhotoAiScanBody(ocr: ocr, activity: activity),
      );
      if (!mounted) return;
      NasSnack.show(
        context,
        res.reused ? tr('photo.ai.alreadyQueued') : tr('photo.ai.queued'),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startFaceScene() => _queueScan(ocr: true);

  Future<void> _startOcr() => _queueScan(ocr: true);

  Future<void> _startActivity() => _queueScan(ocr: true, activity: true);

  /// 只补人脸框（不重算场景/嵌入）：头像墙依赖 bbox，老数据需要补一次
  Future<void> _backfillFaces() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await _client.photoFaceBackfill(
        body: const PhotoFaceBackfillBody(limit: 300),
      );
      NasSnack.showOn(
        messenger,
        tr('photo.ai.backfillDone', {
          'photos': '${res.photos}',
          'faces': '${res.faces}',
          'remaining': '${res.remaining}',
        }),
        duration: const Duration(seconds: 5),
      );
      await _refresh();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(PhotoAiConfigBody body) async {
    try {
      await _client.photoAiConfigSet(body: body);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final s = _settings!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Text(
          tr('photo.ai.hint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: 14),
        _queueCard(s),
        const SizedBox(height: 14),
        _mcpCard(),
        const SizedBox(height: 14),
        _gpuCard(s),
        const SizedBox(height: 14),
        _modulesCard(s),
        const SizedBox(height: 14),
        _faceCard(s),
      ],
    );
  }

  Widget _card({required Widget child, EdgeInsets? padding}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: child,
    );
  }

  Widget _titleRow({
    required String title,
    String? subtitle,
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 10), trailing],
      ],
    );
  }

  Widget _queueCard(PhotoAiSettings s) {
    final queue = s.queue;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 连续批处理时显示实时进度：几万张里 20 张的百分比会被四舍五入成 0%，
          // 只有「已处理 / 总量」才能让人看出在动。
          if (_progressText != null) ...[
            Row(
              children: [
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _progressText!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],          Row(
            children: [
              const Icon(Icons.donut_large_outlined, size: 18),
              const SizedBox(width: 8),
              Text(tr('photo.ai.taskProgress'), style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              if (queue.jobs.every((j) => j.pending == 0))
                Text(
                  tr('photo.ai.allDone'),
                  style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
                ),
              TextButton(
                onPressed: () => _run(
                  queue.paused ? tr('photo.ai.resume') : tr('photo.ai.pause'),
                  () => _client.photoAiQueuePause(
                    body: PhotoAiQueuePauseBody(paused: !queue.paused),
                  ),
                ),
                child: Text(queue.paused ? tr('photo.ai.resume') : tr('photo.ai.pause')),
              ),
              NasRefreshButton(onPressed: _refresh),
            ],
          ),
          if (queue.paused)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                tr('photo.ai.paused'),
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ),
          for (final job in queue.jobs) _queueRow(job),
        ],
      ),
    );
  }

  Widget _queueRow(PhotoAiQueueJob job) {
    final running = job.status == 'running';
    final disabled = job.status == 'disabled';
    final percent = disabled ? 0 : job.percent;
    final status = disabled
        ? tr('photo.ai.status.disabled')
        : running
            ? tr('photo.ai.status.running')
            : tr('photo.ai.status.idle');
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: disabled
                      ? Theme.of(context).colorScheme.outline
                      : running
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.tertiary,
                ),
              ),
              const SizedBox(width: 6),
              Text(job.label, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              Text(
                status,
                style: TextStyle(fontSize: 11, color: context.nasTextSecondary),
              ),
              const Spacer(),
              Text(
                // 显示条数而不是百分比：1.9 万张里跑 100 多张，百分比四舍五入永远 0%，
                // 用户就以为「完全没动」（2026-11-04）。有总数时给 done/total。
                job.total > 0 ? '${job.done} / ${job.total}' : '$percent%',
                style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              // 用真实比例而不是整数百分比：0.6% 的整数版本是 0，条会一直是空的
              value: job.total > 0
                  ? (job.done / job.total).clamp(0.0, 1.0)
                  : percent / 100,
              minHeight: 4,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }

  Widget _mcpCard() {
    final mcp = _mcp;
    if (mcp == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(
            title: tr('photo.ai.mcp'),
            subtitle: tr('photo.ai.mcp.readonly'),
            trailing: Switch(
              value: mcp.enabled,
              onChanged: (v) => _run(
                tr('photo.ai.mcp'),
                () => _client.photoMcpConfigSet(body: PhotoMcpConfigBody(enabled: v)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _kv(tr('photo.ai.mcp.endpoint'), mcp.baseUrl),
          _kv(tr('photo.ai.mcp.token'), mcp.tokenMasked),
          Row(
            children: [
              Expanded(child: Text(tr('photo.ai.mcp.uid'), style: TextStyle(fontSize: 12, color: context.nasTextSecondary))),
              NasDropdown<String>(
                value: mcp.uid.isEmpty ? null : mcp.uid,
                hint: Text(tr('photo.ai.mcp.noUid')),
                underline: const SizedBox.shrink(),
                items: [
                  for (final u in _users)
                    DropdownMenuItem(
                      value: '${u['id'] ?? u['uid'] ?? ''}',
                      child: Text('${u['name'] ?? u['username'] ?? u['id'] ?? ''}'),
                    ),
                  if (mcp.uid.isNotEmpty && !_users.any((u) => '${u['id'] ?? u['uid'] ?? ''}' == mcp.uid))
                    DropdownMenuItem(value: mcp.uid, child: Text(mcp.uid)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  _run(
                    tr('photo.ai.mcp'),
                    () => _client.photoMcpConfigSet(body: PhotoMcpConfigBody(uid: v)),
                  );
                },
              ),
            ],
          ),
          _kv(tr('photo.ai.mcp.tools'), mcp.tools.join(' · ')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () async {
                  final ok = await _confirm(
                    tr('photo.ai.mcp.rotate'),
                    tr('photo.ai.mcp.rotateConfirm'),
                  );
                  if (!ok) return;
                  await _run(tr('photo.ai.mcp.rotate'), () async {
                    final res = await _client.photoMcpTokenRotate();
                    await Clipboard.setData(ClipboardData(text: res.token));
                    return null;
                  });
                },
                child: Text(tr('photo.ai.mcp.rotate')),
              ),
              OutlinedButton(
                onPressed: () async {
                  final token = mcp.tokenMasked;
                  final body =
                      '{"mcpServers":{"colanas-photo":{"type":"http","url":"${mcp.baseUrl}","headers":{"Authorization":"Bearer ${tr('photo.ai.mcpTokenPlaceholder')}"}}}}';
                  await Clipboard.setData(ClipboardData(text: body));
                  if (!mounted) return;
                  NasSnack.show(context, '${tr('photo.ai.mcp.copied')} $token');
                },
                child: Text(tr('photo.ai.mcp.copy')),
              ),
            ],
          ),
          if (scheme.brightness == Brightness.dark) const SizedBox(height: 0),
        ],
      ),
    );
  }

  Widget _kv(String key, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              key,
              style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _gpuCard(PhotoAiSettings s) {
    return _card(
      child: _switchRow(
        title: tr('photo.ai.gpu'),
        subtitle: tr('photo.ai.gpuHint'),
        value: s.config.gpuPrefer,
        onChanged: (v) => _save(PhotoAiConfigBody(gpuPrefer: v)),
      ),
    );
  }

  /// 已完成 / 总数：面板要显示「120/19113」，只有百分比时几千张里跑十张看着像没动
  (int, int) _counts(PhotoAiSettings s, String key) {
    for (final job in s.queue.jobs) {
      if (job.key == key) return (job.done, job.total);
    }
    return (0, 0);
  }

  /// 「（120/19113 · 1%）」；没有条目口径（total=0）时返回空串
  String _progressSuffix(int percent, (int, int) counts) {
    final (done, total) = counts;
    if (total <= 0) return '';
    return tr('photo.ai.progressDoneTotal', {
      'done': '$done',
      'total': '$total',
      'percent': '$percent',
    });
  }

  Widget _modulesCard(PhotoAiSettings s) {
    return _card(
      child: Column(
        children: [
          _moduleRow(
            title: tr('photo.ai.enableOcr'),
            subtitle: tr('photo.ai.sub.ocr'),
            percent: s.progress.ocr,
            counts: _counts(s, 'ocr'),
            value: s.config.ocrEnabled,
            onChanged: (v) async {
              await _save(PhotoAiConfigBody(ocrEnabled: v));
              if (v) await _startOcr();
            },
            onStart: _startOcr,
            startTooltip: tr('photo.ai.startOcr'),
            onReset: () => _run(
              tr('photo.ai.reset'),
              () => _client.photoAiReset(body: const PhotoAiResetBody(kind: 'ocr')),
            ),
          ),
          const Divider(height: 22),
          _moduleRow(
            title: tr('photo.ai.enablePlace'),
            subtitle: tr('photo.ai.sub.place'),
            percent: s.progress.place,
            counts: _counts(s, 'place'),
            value: s.config.placeEnabled,
            onChanged: (v) async {
              await _save(PhotoAiConfigBody(placeEnabled: v));
              if (v) await _startFaceScene();
            },
            onStart: _startFaceScene,
            startTooltip: tr('photo.ai.startFaceScene'),
            onReset: () => _run(
              tr('photo.ai.reset'),
              () => _client.photoAiReset(body: const PhotoAiResetBody(kind: 'place')),
            ),
          ),
          const Divider(height: 22),
          _moduleRow(
            title: tr('photo.ai.enableActivity'),
            subtitle: tr('photo.ai.sub.activity'),
            percent: s.progress.activity,
            counts: _counts(s, 'activity'),
            value: s.config.activityEnabled,
            onChanged: (v) async {
              await _save(PhotoAiConfigBody(activityEnabled: v));
              if (v) await _startActivity();
            },
            onStart: _startActivity,
            startTooltip: tr('photo.ai.startActivity'),
            onReset: () => _run(
              tr('photo.ai.reset'),
              () => _client.photoAiReset(body: const PhotoAiResetBody(kind: 'activity')),
            ),
          ),
          const Divider(height: 22),
          _moduleRow(
            title: tr('photo.ai.enableSimilar'),
            subtitle: tr('photo.ai.sub.similar'),
            percent: s.progress.similarScan,
            counts: _counts(s, 'similar'),
            secondPercent: s.progress.similarCompare,
            value: s.config.similarEnabled,
            onChanged: (v) => _save(PhotoAiConfigBody(similarEnabled: v)),
            onReset: () => _run(
              tr('photo.ai.reset'),
              () => _client.photoAiReset(body: const PhotoAiResetBody(kind: 'similar')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _moduleRow({
    required String title,
    required String subtitle,
    required int percent,
    required (int, int) counts,
    required bool value,
    required ValueChanged<bool> onChanged,
    required VoidCallback onReset,
    VoidCallback? onStart,
    String? startTooltip,
    int? secondPercent,
  }) {
    return _titleRow(
      title: '$title${_progressSuffix(percent, counts)}',
      subtitle: secondPercent == null
          ? subtitle
          : '$subtitle · ${tr('photo.ai.scanCompare', {'scan': '$percent', 'compare': '$secondPercent'})}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onStart != null) IconButton(
            tooltip: startTooltip ?? title,
            onPressed: _busy ? null : onStart,
            icon: const Icon(Icons.play_arrow, size: 20),
          ),
          TextButton(onPressed: _busy ? null : onReset, child: Text(tr('photo.ai.reset'))),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _faceCard(PhotoAiSettings s) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _switchRow(
            title: '${tr('photo.ai.enableFace')}${_progressSuffix(s.progress.face, _counts(s, 'face'))}',
            subtitle: tr('photo.ai.sub.face'),
            value: s.config.faceEnabled,
            onChanged: (v) async {
              await _save(PhotoAiConfigBody(faceEnabled: v));
              if (v) await _startFaceScene();
            },
            onStart: _startFaceScene,
            startTooltip: tr('photo.ai.startFaceScene'),
          ),
          const Divider(height: 22),
          _titleRow(
            title: tr('photo.ai.backfillTitle'),
            subtitle: tr('photo.ai.backfillHint'),
            trailing: FilledButton.tonalIcon(
              onPressed: _busy ? null : _backfillFaces,
              icon: const Icon(Icons.crop_free, size: 16),
              label: Text(tr('photo.ai.backfillRun')),
            ),
          ),
          const Divider(height: 22),
          _titleRow(
            title: tr('photo.ai.autoHide'),
            subtitle: tr('photo.ai.autoHideHint'),
            trailing: NasDropdown<int>(
              value: s.config.faceMinShowCount,
              underline: const SizedBox.shrink(),
              items: [
                for (final n in const [0, 3, 5, 10])
                  DropdownMenuItem(
                    value: n,
                    child: Text(n == 0 ? tr('photo.ai.hideNone') : tr('photo.ai.hideLess', {'count': '$n'})),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                _save(PhotoAiConfigBody(faceMinShowCount: v));
              },
            ),
          ),
          const Divider(height: 22),
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('photo.ai.faceTuning'),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(
                          tr('photo.ai.save'),
                          () => _client.photoFaceTuning(
                            body: PhotoAiTuningBody(
                              matchSim: _matchSim,
                              minVotes: _minVotes,
                              threads: _threads,
                            ),
                          ),
                        ),
                icon: const Icon(Icons.save_outlined, size: 16),
                label: Text(tr('photo.ai.save')),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            tr('photo.ai.faceTuningHint'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
          const SizedBox(height: 10),
          _slider(
            label: tr('photo.ai.matchSim'),
            hint: tr('photo.ai.matchSimHint'),
            valueText: _matchSim.toStringAsFixed(2),
            child: Slider(
              value: _matchSim,
              min: 0.3,
              max: 0.75,
              divisions: 9,
              label: _matchSim.toStringAsFixed(2),
              onChanged: (v) => setState(() => _matchSim = v),
            ),
          ),
          _slider(
            label: tr('photo.ai.minVotes'),
            hint: tr('photo.ai.minVotesHint'),
            valueText: '$_minVotes',
            child: Slider(
              value: _minVotes.toDouble(),
              min: 1,
              max: 8,
              divisions: 7,
              label: '$_minVotes',
              onChanged: (v) => setState(() => _minVotes = v.round()),
            ),
          ),
          _titleRow(
            title: tr('photo.ai.threads'),
            subtitle: tr('photo.ai.threadsHint'),
            trailing: NasDropdown<int>(
              value: _threads,
              underline: const SizedBox.shrink(),
              items: [
                for (final n in const [1, 2, 3, 4, 6, 8])
                  DropdownMenuItem(value: n, child: Text('$n')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _threads = v);
              },
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(
                          tr('photo.ai.rescanMissing'),
                          () => _client.photoFaceRescanMissing(
                            body: const PhotoFaceRescanBody(limit: 200),
                          ),
                        ),
                icon: const Icon(Icons.find_in_page_outlined, size: 16),
                label: Text(tr('photo.ai.rescanMissing')),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(
                          tr('photo.ai.mergeSimilar'),
                          () => _client.photoFaceMergeSimilar(
                            body: const PhotoFaceMergeSimilarBody(dryRun: false, rounds: 1),
                          ),
                        ),
                icon: const Icon(Icons.merge_type, size: 16),
                label: Text(tr('photo.ai.mergeSimilar')),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(
                          tr('photo.ai.recluster'),
                          () => _client.photoFaceRebuild(
                            body: const PhotoFaceRebuildBody(limit: 200000),
                          ),
                        ),
                icon: const Icon(Icons.restart_alt, size: 16),
                label: Text(tr('photo.ai.recluster')),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final ok = await _confirm(
                          tr('photo.ai.resetAll'),
                          tr('photo.ai.resetAllConfirm'),
                        );
                        if (!ok) return;
                        await _run(
                          tr('photo.ai.resetAll'),
                          () => _client.photoFaceResetAll(),
                        );
                      },
                icon: const Icon(Icons.delete_forever_outlined, size: 16),
                label: Text(tr('photo.ai.resetAll')),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(
                          tr('photo.ai.purge'),
                          () => _client.photoFacePurge(),
                        ),
                icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                label: Text(tr('photo.ai.purge')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _slider({
    required String label,
    required String hint,
    required String valueText,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            Text(valueText, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ],
        ),
        Text(
          hint,
          style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
        ),
        child,
      ],
    );
  }

  Widget _switchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    VoidCallback? onStart,
    String? startTooltip,
  }) {
    return _titleRow(
      title: title,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onStart != null)
            IconButton(
              tooltip: startTooltip ?? title,
              onPressed: _busy ? null : onStart,
              icon: const Icon(Icons.play_arrow, size: 20),
            ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('common.ok')),
          ),
        ],
      ),
    );
    return res == true;
  }
}