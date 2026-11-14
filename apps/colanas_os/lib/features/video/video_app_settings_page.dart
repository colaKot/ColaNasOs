import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/display_labels.dart';
import '../../core/session.dart';
import '../../shell/app_widgets.dart';

/// 影视设置（**服务端级**，所有客户端共享）。
///
/// 三块，从上到下就是「现在的活儿 → 怎么刮 → 怎么补字幕」：
///   1. 搜刮任务：各库的扫描 / 刮削 / 字幕进度，失败的保留计数（任务表不清理失败行）
///   2. 刮削：TMDB Key / 语言 / 置信度阈值 / 是否写 .nfo
///   3. 字幕：库级「入库自动补字幕」+ 手动触发一轮补全
///
/// 与「客户端设置」的分界：播放偏好（画质 / 编码 / 音频）在那边，只影响当前设备。
class VideoAppSettingsPage extends StatefulWidget {
  const VideoAppSettingsPage({super.key});

  @override
  State<VideoAppSettingsPage> createState() => _VideoAppSettingsPageState();
}

class _VideoAppSettingsPageState extends State<VideoAppSettingsPage> {
  bool _loading = true;
  String? _error;
  List<VideoLibraryItem> _libs = const [];
  List<_VideoTask> _tasks = const [];

  /// 每日刮削进度快照（`/video/scrape/progress` 的 latest）
  Map<String, dynamic>? _stats;
  bool _statsBusy = false;
  Timer? _poll;

  final _keyCtrl = TextEditingController();
  final _langCtrl = TextEditingController(text: 'zh-CN');
  final _minScoreCtrl = TextEditingController(text: '6');
  // 字幕抓取（服务端级）
  final _javUserCtrl = TextEditingController();
  final _javPassCtrl = TextEditingController();
  final _assrtCtrl = TextEditingController();
  final _openSubCtrl = TextEditingController();
  bool _preExtract = false;
  bool _xunlei = true;
  bool _dailyEnable = true;
  int _dailyHour = 4;
  String _defaultLang = 'zh-CN';
  bool _javConfigured = false;
  bool _assrtConfigured = false;
  bool _openSubConfigured = false;
  // 转码（服务端级）
  final _tempDirCtrl = TextEditingController();
  String _hwaccel = 'auto';
  String _effectiveTempDir = '';
  bool _writeSidecar = true;
  bool _configured = false;
  bool _saving = false;
  bool _testing = false;
  bool _testingSub = false;
  List<Map<String, dynamic>>? _subTestResults;

  @override
  void initState() {
    super.initState();
    _load();
    // 任务进度要「看着它动」，2s 一次足够；页面销毁就停，不留定时器
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _loadTasks();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _keyCtrl.dispose();
    _langCtrl.dispose();
    _minScoreCtrl.dispose();
    _javUserCtrl.dispose();
    _javPassCtrl.dispose();
    _assrtCtrl.dispose();
    _openSubCtrl.dispose();
    _tempDirCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final libs = await ApiSession.instance.client.videoLibraryList();
      final tmdb = await ApiSession.instance.client.videoTmdbSettingsGet();
      final st = await ApiSession.instance.client.videoSettingsGet();
      if (!mounted) return;
      setState(() {
        _libs = libs.items;
        _configured = tmdb.configured;
        // 明文回传：用户要能看见自己配的是哪个 Key
        _keyCtrl.text = tmdb.apiKey;
        _langCtrl.text = tmdb.language;
        _minScoreCtrl.text = '${tmdb.minScore}';
        _writeSidecar = tmdb.writeSidecar;
        final sub = (st['subtitle'] as Map?) ?? const {};
        final trans = (st['transcode'] as Map?) ?? const {};
        _preExtract = sub['preExtract'] == true;
        _defaultLang = '${sub['defaultLang'] ?? 'zh-CN'}';
        _javUserCtrl.text = '${sub['javUser'] ?? ''}';
        // 明文回显：只显示「已配置」时用户根本看不出自己配了什么（2026-11-03 反馈）
        _javPassCtrl.text = '${sub['javPass'] ?? ''}';
        _assrtCtrl.text = '${sub['assrtToken'] ?? ''}';
        _openSubCtrl.text = '${sub['openSubtitlesKey'] ?? ''}';
        _javConfigured = sub['javConfigured'] == true;
        _assrtConfigured = sub['assrtConfigured'] == true;
        _openSubConfigured = sub['openSubtitlesConfigured'] == true;
        _xunlei = sub['xunlei'] != false;
        _dailyEnable = sub['dailyEnable'] != false;
        _dailyHour = (sub['dailyHour'] as num?)?.toInt() ?? 4;
        _hwaccel = '${trans['hwaccel'] ?? 'auto'}';
        _tempDirCtrl.text = '${trans['tempDir'] ?? ''}';
        _effectiveTempDir = '${trans['effectiveTempDir'] ?? ''}';
        _loading = false;
      });
      await _loadTasks();
      await _loadStats();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadTasks() async {
    try {
      final raw = await ApiSession.instance.client.tasksList();
      if (!mounted) return;
      setState(() => _tasks = _parseTasks(raw));
    } catch (_) {
      // 任务列表拿不到不影响上面两块的编辑，不弹错
    }
  }

  /// 刮削进度快照：每天由 `video.scrape.progress` 任务写一条，这里只读。
  Future<void> _loadStats() async {
    try {
      final raw = await ApiSession.instance.client.videoScrapeProgress(days: 7);
      if (!mounted) return;
      final latest = raw['latest'];
      setState(() => _stats = latest is Map ? Map<String, dynamic>.from(latest) : null);
    } catch (_) {
      // 没有快照 / 接口失败都不影响设置页其它内容
    }
  }

  /// 立即重算一次（入队），随后轮询等它落库
  Future<void> _recountStats() async {
    if (_statsBusy) return;
    setState(() => _statsBusy = true);
    try {
      await ApiSession.instance.client.videoScrapeProgressRefresh();
      // 任务本身几十毫秒，等一下再读；失败就按原值显示
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await _loadStats();
        if (!mounted) return;
        if (_stats != null) break;
      }
      await _loadTasks();
    } catch (e) {
      if (mounted) NasSnack.show(context, '$e');
    } finally {
      if (mounted) setState(() => _statsBusy = false);
    }
  }

  /// `/tasks` 返回 `{items, stats}`；payload 在库里是 text，这里兼容字符串与已解析的 Map。
  static List<_VideoTask> _parseTasks(Map<String, dynamic> raw) {
    final items = raw['items'];
    if (items is! List) return const [];
    final out = <_VideoTask>[];
    for (final e in items) {
      if (e is! Map) continue;
      final type = '${e['type'] ?? ''}';
      if (!type.startsWith('video.')) continue;
      var payload = e['payload'];
      if (payload is String) {
        try {
          payload = jsonDecode(payload);
        } catch (_) {
          payload = null;
        }
      }
      out.add(
        _VideoTask(
          type: type,
          state: '${e['state'] ?? ''}',
          // 服务端 progress 是 0..100 的百分数（done 时置 100）
          progress: e['progress'] is num
              ? (e['progress'] as num).toDouble() / 100
              : 0,
          doneCount: (e['done_count'] as num?)?.toInt() ?? 0,
          totalCount: (e['total_count'] as num?)?.toInt() ?? 0,
          error: e['error'] as String?,
          libraryId: payload is Map ? payload['libraryId']?.toString() : null,
        ),
      );
    }
    return out;
  }

  Future<void> _toggleAutoSubtitle(VideoLibraryItem lib, bool value) async {
    try {
      await ApiSession.instance.client.videoLibraryFlags(
        body: VideoLibraryFlagsBody(id: lib.id, autoSubtitle: value),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _fetchSubtitles(VideoLibraryItem lib) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.videoSubtitleFetchLibrary(
        body: {'id': lib.id},
      );
      NasSnack.showOn(messenger, tr('video.sub.fetchDone'));
      await _loadTasks();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  /// 逐个字幕站测连通性：用**输入框里**的凭据（没保存也能测）。
  Future<void> _testSubtitleSources() async {
    if (_testingSub) return;
    setState(() {
      _testingSub = true;
      _subTestResults = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.videoSubtitleSourcesTest(
        body: {
          'assrtToken': _assrtCtrl.text.trim(),
          'openSubtitlesKey': _openSubCtrl.text.trim(),
        },
      );
      final list = (res['sources'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _subTestResults = list
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      });
    } catch (e) {
      NasSnack.showOn(messenger, tr('video.sub.testFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _testingSub = false);
    }
  }

  static String _subSourceLabel(String id) {
    switch (id) {
      case 'jav':
        return tr('video.sub.src.jav');
      case 'assrt':
        return tr('video.sub.src.assrt');
      case 'openSub':
        return tr('video.sub.src.openSub');
      default:
        return tr('video.sub.src.xunlei');
    }
  }

  Widget _subSourceResult(Map<String, dynamic> r) {
    final ok = r['ok'] == true;
    final ms = r['latencyMs'] ?? 0;
    final message = '${r['message'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: ok
                ? context.nasSuccess
                : Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 120,
            child: Text(
              _subSourceLabel('${r['id'] ?? ''}'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              '$message · $ms ms',
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceLg,
        NasTokens.spaceMd,
        NasTokens.spaceLg,
        NasTokens.spaceXl,
      ),
      children: [
        _tasksPanel(),
        _section(tr('video.scrape.group')),
        ..._scrapeSection(),
        ..._subtitleSection(),
        _section(tr('video.transcode.group')),
        ..._transcodeSection(),
      ],
    );
  }

  // ---------------------------------------------------------------- 任务面板

  /// 补全演员头像 / 档案：头像来自本地 NFO 的 `<actor><thumb>`（快），
  /// 身高生日出身地要联网抓维基（慢，进队列串行跑）。
  Future<void> _fillActors() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.videoJpActorRebuild(body: const {});
      await _loadTasks();
      NasSnack.showOn(messenger, tr('video.stats.actorFillQueued'));
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  /// 每日刮削进度（待刮 / 已刮 / 无中字无字幕）。
  ///
  /// 数据来自 `video.scrape.progress` 任务写的每日快照。为什么不直接读任务列表：
  /// `/tasks` 只保留最近 50 条执行记录，翻不到上周的数字，而这里要的是
  /// 「还剩多少要刮、已经刮了多少」这种能对比的进度。
  Widget _statsBlock() {
    final s = _stats;
    final scheme = Theme.of(context).colorScheme;
    final caption = TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary);
    final recount = TextButton(
      onPressed: _statsBusy ? null : _recountStats,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 28),
      ),
      child: _statsBusy
          ? const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(tr('video.stats.recount'), style: const TextStyle(fontSize: 12)),
    );

    if (s == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
        child: Row(
          children: [
            Expanded(child: Text(tr('video.stats.none'), style: caption)),
            recount,
          ],
        ),
      );
    }

    final total = (s['total'] as num?)?.toInt() ?? 0;
    final scraped = (s['scraped'] as num?)?.toInt() ?? 0;
    final unscraped = (s['unscraped'] as num?)?.toInt() ?? 0;
    final noCNoSub = (s['noCNoSub'] as num?)?.toInt() ?? 0;
    final pct = total > 0 ? (scraped / total).clamp(0.0, 1.0) : 1.0;

    Widget figure(String label, int value, {Color? color}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$value',
          style: TextStyle(
            fontSize: NasTokens.fontTitle,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        Text(label, style: caption),
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceSm,
        NasTokens.spaceXs,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: context.nasStyle.panelColor,
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        border: Border.all(color: context.nasStyle.panelBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr('video.stats.title'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              Text('${s['day'] ?? ''}', style: caption),
              recount,
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: figure(tr('video.stats.unscraped'), unscraped, color: scheme.primary),
              ),
              Expanded(child: figure(tr('video.stats.scraped'), scraped)),
              Expanded(child: figure(tr('video.stats.noCNoSub'), noCNoSub)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 4,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 3),
          Text('$scraped / $total', style: caption),
          ..._statsByLibrary(s, caption),
        ],
      ),
    );
  }

  List<Widget> _statsByLibrary(Map<String, dynamic> s, TextStyle caption) {
    final list = (s['byLibrary'] as List?) ?? const [];
    if (list.isEmpty) return const [];
    final rows = <Widget>[
      const SizedBox(height: 6),
      Text(tr('video.stats.byLibrary'), style: caption),
    ];
    for (final e in list.take(4)) {
      if (e is! Map) continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${e['name'] ?? ''}',
                  style: caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${e['unscraped'] ?? 0} / ${e['total'] ?? 0}', style: caption),
            ],
          ),
        ),
      );
    }
    return rows;
  }

  Widget _tasksPanel() {
    return NasCard(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.task_alt_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr('video.task.title'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              NasRefreshButton(size: 18, onPressed: _loadTasks),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            tr('video.task.hint'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          const SizedBox(height: NasTokens.spaceSm),
          _statsBlock(),
          if (_libs.isEmpty)
            Text(
              tr('video.task.none'),
              style: TextStyle(color: context.nasTextSecondary),
            )
          else
            ..._libs.map(_libraryTaskRow).whereType<Widget>(),
          const SizedBox(height: NasTokens.spaceXs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _fillActors,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              icon: const Icon(Icons.person_search_outlined, size: 16),
              label: Text(
                tr('video.stats.actorFill'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _libraryTaskRow(VideoLibraryItem lib) {
    final rows = <Widget>[];
    for (final kind in _kKindOrder) {
      final agg = _aggregate(lib.id, kind);
      if (agg == null) continue;
      rows.add(_kindLine(kind, agg));
    }
    if (rows.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: NasTokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lib.name,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          ...rows,
        ],
      ),
    );
  }

  static const List<String> _kKindOrder = ['scan', 'scrape', 'subtitle'];

  static String _kindOf(String type) {
    if (type.startsWith('video.scan')) return 'scan';
    if (type.startsWith('video.scrape')) return 'scrape';
    if (type.startsWith('video.subtitle')) return 'subtitle';
    return 'other';
  }

  static String _kindLabel(String kind) {
    switch (kind) {
      case 'scan':
        return tr('video.task.kind.scan');
      case 'scrape':
        return tr('video.task.kind.scrape');
      default:
        return tr('video.task.kind.subtitle');
    }
  }

  static String _stateLabel(String state) {
    switch (state) {
      case 'running':
        return tr('video.task.state.running');
      case 'pending':
        return tr('video.task.state.pending');
      case 'failed':
        return tr('video.task.state.failed');
      case 'canceled':
        return tr('video.task.state.canceled');
      default:
        return tr('video.task.state.done');
    }
  }

  /// 同一库里同一类任务聚合成一行：进行中优先，其次失败计数，最后「完成 N」。
  _TaskAgg? _aggregate(String libId, String kind) {
    final ofKind = _tasks
        .where((t) => t.libraryId == libId && _kindOf(t.type) == kind)
        .toList();
    if (ofKind.isEmpty) return null;
    final running = ofKind.where((t) => t.state == 'running').toList();
    if (running.isNotEmpty) {
      return _TaskAgg(
        state: 'running',
        progress: running.first.progress,
        done: 0,
        failed: 0,
        doneCount: running.first.doneCount,
        totalCount: running.first.totalCount,
      );
    }
    final pending = ofKind.where((t) => t.state == 'pending').length;
    if (pending > 0) {
      return _TaskAgg(state: 'pending', progress: 0, done: 0, failed: 0);
    }
    // 收尾后仍要显示条数：扫描完一轮，用户想知道这一轮到底处理了多少条
    _VideoTask? counted;
    for (final t in ofKind) {
      if (t.totalCount > 0) counted = t;
    }
    final failed = ofKind.where((t) => t.state == 'failed').length;
    final done = ofKind.where((t) => t.state == 'done').length;
    if (failed > 0) {
      // 失败也算这批活儿的一部分：显示失败数，同时把总数带出来
      return _TaskAgg(
        state: 'failed',
        progress: 1,
        done: done,
        failed: failed,
        doneCount: counted?.doneCount ?? 0,
        totalCount: counted?.totalCount ?? 0,
      );
    }
    return _TaskAgg(
      state: 'done',
      progress: 1,
      done: done,
      failed: 0,
      doneCount: counted?.doneCount ?? 0,
      totalCount: counted?.totalCount ?? 0,
    );
  }

  Widget _kindLine(String kind, _TaskAgg agg) {
    final isRunning = agg.state == 'running';
    // 有条目口径就显示「已完成/总数」，没有就退回原来的状态文案
    final countText = agg.totalCount > 0
        ? '${agg.doneCount}/${agg.totalCount}'
        : null;
    final detail =
        countText ??
        (agg.state == 'failed'
            ? '${agg.failed}'
            : (agg.state == 'done' && agg.done > 0 ? '${agg.done}' : null));
    final label = detail == null
        ? _stateLabel(agg.state)
        : '${_stateLabel(agg.state)} $detail';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              _kindLabel(kind),
              style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
            ),
          ),
          Expanded(
            child: isRunning
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: agg.progress <= 0
                          ? null
                          : agg.progress.clamp(0.0, 1.0).toDouble(),
                      minHeight: 4,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: agg.state == 'failed'
                  ? Theme.of(context).colorScheme.error
                  : context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 刮削

  List<Widget> _scrapeSection() {
    return [
      Row(
        children: [
          Icon(
            _configured ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: _configured
                ? Theme.of(context).colorScheme.primary
                : context.nasTextSecondary,
          ),
          const SizedBox(width: 6),
          Text(
            _configured
                ? tr('video.scrape.configured')
                : tr('video.scrape.notConfigured'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _keyCtrl,
        decoration: InputDecoration(
          labelText: tr('video.scrape.key'),
          helperText: tr('video.scrape.keyHint'),
          isDense: true,
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      Row(
        children: [
          Expanded(
            child: NasDropdown<String>(
              initialValue: _langCtrl.text.isEmpty ? 'zh-CN' : _langCtrl.text,
              isDense: true,
              decoration: InputDecoration(
                labelText: tr('video.scrape.language'),
                isDense: true,
              ),
              items: [
                for (final l in kTmdbLanguages)
                  DropdownMenuItem<String>(value: l.$1, child: Text(l.$2)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _langCtrl.text = v);
              },
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _minScoreCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: tr('video.scrape.minScore'),
                isDense: true,
              ),
            ),
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: _writeSidecar,
        title: Text(tr('video.scrape.writeSidecar')),
        subtitle: Text(
          tr('video.scrape.writeSidecarHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        onChanged: (v) => setState(() => _writeSidecar = v),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(
              onPressed: _testing ? null : _testTmdb,
              child: Text(tr('video.tmdb.test')),
            ),
            const SizedBox(width: NasTokens.spaceSm),
            FilledButton(
              onPressed: _saving ? null : _saveServer,
              child: Text(tr('common.save')),
            ),
          ],
        ),
      ),
    ];
  }

  /// 连通性自检：用**输入框里的** Key 打一次 TMDB（没保存也能测）。
  Future<void> _testTmdb() async {
    if (_testing) return;
    setState(() => _testing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ApiSession.instance.client.videoTmdbTest(
        body: {'apiKey': _keyCtrl.text.trim()},
      );
      NasSnack.showOn(messenger,
          '${errorMessageOf(r['message'])} (${r['latencyMs'] ?? 0} ms)');
    } catch (e) {
      NasSnack.showOn(messenger, errorMessageOf(e));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  // ---------------------------------------------------------------- 字幕

  /// 字幕：**全局抓取配置**（服务端级）+ 每库「入库自动补字幕」开关。
  ///
  /// 来源顺序由后端决定（JAV 站 → Assrt → OpenSubtitles → 迅雷，命中即停），
  /// 这里只负责把每家的凭据存下来；没配的来源会自动跳过。
  List<Widget> _subtitleSection() {
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: _preExtract,
        title: Text(tr('video.sub.preExtract')),
        subtitle: Text(
          tr('video.sub.preExtractHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        onChanged: (v) => setState(() => _preExtract = v),
      ),
      NasDropdown<String>(
        initialValue: _defaultLang,
        isDense: true,
        decoration: InputDecoration(
          labelText: tr('video.sub.defaultLang'),
          helperText: tr('video.sub.defaultLangHint'),
          isDense: true,
        ),
        items: [
          DropdownMenuItem<String>(
            value: 'auto',
            child: Text(tr('video.sub.langAuto')),
          ),
          for (final l in kTmdbLanguages)
            DropdownMenuItem<String>(value: l.$1, child: Text(l.$2)),
        ],
        onChanged: (v) {
          if (v != null) setState(() => _defaultLang = v);
        },
      ),

      _section(tr('video.sub.sources')),
      Text(
        tr('video.sub.sourcesHint'),
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          color: context.nasTextSecondary,
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _javUserCtrl,
        decoration: InputDecoration(
          labelText: tr('video.sub.javUser'),
          isDense: true,
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _javPassCtrl,
        // 明文显示：本地自用，配没配、配的是什么必须一眼看到
        obscureText: false,
        decoration: InputDecoration(
          labelText: tr('video.sub.javPass'),
          hintText: _javConfigured
              ? tr('video.sub.javPassHint')
              : tr('video.sub.notConfigured'),
          suffixIcon: _javConfigured
              ? Icon(
                  Icons.check_circle_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                )
              : null,
          isDense: true,
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _assrtCtrl,
        obscureText: false,
        decoration: InputDecoration(
          labelText: tr('video.sub.assrt'),
          hintText: _assrtConfigured
              ? tr('video.sub.javConfigured')
              : tr('video.sub.notConfigured'),
          isDense: true,
        ),
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _openSubCtrl,
        obscureText: false,
        decoration: InputDecoration(
          labelText: tr('video.sub.openSub'),
          hintText: _openSubConfigured
              ? tr('video.sub.javConfigured')
              : tr('video.sub.notConfigured'),
          isDense: true,
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: _xunlei,
        title: Text(tr('video.sub.xunlei')),
        subtitle: Text(
          tr('video.sub.xunleiHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        onChanged: (v) => setState(() => _xunlei = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: _dailyEnable,
        title: Text(tr('video.sub.daily')),
        subtitle: Text(
          tr('video.sub.dailyHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        onChanged: (v) => setState(() => _dailyEnable = v),
      ),
      NasDropdown<int>(
        initialValue: _dailyHour,
        isDense: true,
        decoration: InputDecoration(
          labelText: tr('video.sub.dailyHour'),
          isDense: true,
        ),
        items: [
          for (var h = 0; h < 24; h++)
            DropdownMenuItem<int>(
              value: h,
              child: Text('${h.toString().padLeft(2, '0')}:00'),
            ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => _dailyHour = v);
        },
      ),

      _section(tr('video.sub.group')),
      if (_libs.isEmpty)
        Text(
          tr('video.task.none'),
          style: TextStyle(color: context.nasTextSecondary),
        )
      else ...[
        Text(
          tr('video.sub.autoHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        for (final lib in _libs)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: (lib.autoSubtitle ?? 0) == 1,
                    title: Text('${tr('video.sub.auto')} · ${lib.name}'),
                    onChanged: (v) => _toggleAutoSubtitle(lib, v),
                  ),
                ),
                TextButton(
                  onPressed: () => _fetchSubtitles(lib),
                  child: Text(tr('video.sub.fetchNow')),
                ),
              ],
            ),
          ),
      ],
      if (_subTestResults != null) ...[
        const SizedBox(height: NasTokens.spaceSm),
        for (final r in _subTestResults!) _subSourceResult(r),
      ],
      const SizedBox(height: NasTokens.spaceSm),
      Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(
              onPressed: _testingSub ? null : _testSubtitleSources,
              child: Text(
                _testingSub
                    ? tr('video.sub.testing')
                    : tr('video.sub.testSources'),
              ),
            ),
            const SizedBox(width: NasTokens.spaceSm),
            FilledButton(
              onPressed: _saving ? null : _saveServer,
              child: Text(tr('common.save')),
            ),
          ],
        ),
      ),
    ];
  }

  // ---------------------------------------------------------------- 转码

  List<Widget> _transcodeSection() {
    return [
      NasDropdown<String>(
        initialValue: _hwaccel,
        isDense: true,
        decoration: InputDecoration(
          labelText: tr('video.transcode.hwaccel'),
          helperText: tr('video.transcode.hwaccelHint'),
          isDense: true,
        ),
        items: [
          DropdownMenuItem(
            value: 'auto',
            child: Text(tr('video.transcode.hwaccelAuto')),
          ),
          const DropdownMenuItem(value: 'nvenc', child: Text('NVIDIA NVENC')),
          const DropdownMenuItem(value: 'qsv', child: Text('Intel QSV')),
          const DropdownMenuItem(value: 'amf', child: Text('AMD AMF')),
          DropdownMenuItem(
            value: 'cpu',
            child: Text(tr('video.transcode.hwaccelCpu')),
          ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => _hwaccel = v);
        },
      ),
      const SizedBox(height: NasTokens.spaceSm),
      TextField(
        controller: _tempDirCtrl,
        decoration: InputDecoration(
          labelText: tr('video.transcode.tempDir'),
          helperText: tr('video.transcode.tempDirHint'),
          isDense: true,
        ),
      ),
      if (_effectiveTempDir.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            tr('video.transcode.effective', {'path': _effectiveTempDir}),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ),
      const SizedBox(height: NasTokens.spaceSm),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: _saving ? null : _saveServer,
          child: Text(tr('common.save')),
        ),
      ),
    ];
  }

  /// 一次提交三段（TMDB / 字幕 / 转码）：设置页只有一个「保存」，别让用户猜哪个按钮管哪段。
  Future<void> _saveServer() async {
    if (_saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.videoTmdbSettingsSet(
        body: VideoTmdbSettingsBody(
          apiKey: _keyCtrl.text.trim(),
          language: _langCtrl.text.trim().isEmpty
              ? 'zh-CN'
              : _langCtrl.text.trim(),
          minScore: double.tryParse(_minScoreCtrl.text.trim()) ?? 6,
          writeSidecar: _writeSidecar,
        ),
      );
      await ApiSession.instance.client.videoSettingsSet(
        body: {
          'subtitle': {
            'preExtract': _preExtract,
            'defaultLang': _defaultLang,
            'javUser': _javUserCtrl.text.trim(),
            if (_javPassCtrl.text.isNotEmpty) 'javPass': _javPassCtrl.text,
            'assrtToken': _assrtCtrl.text.trim(),
            'openSubtitlesKey': _openSubCtrl.text.trim(),
            'xunlei': _xunlei,
            'dailyEnable': _dailyEnable,
            'dailyHour': _dailyHour,
          },
          'transcode': {
            'hwaccel': _hwaccel,
            'tempDir': _tempDirCtrl.text.trim(),
          },
        },
      );
      NasSnack.showOn(messenger, tr('video.scrape.saved'));
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(
      top: NasTokens.spaceLg,
      bottom: NasTokens.spaceXs,
    ),
    child: Text(
      title,
      style: TextStyle(
        fontSize: NasTokens.fontCaption,
        fontWeight: FontWeight.w600,
        color: context.nasTextSecondary,
      ),
    ),
  );
}

class _VideoTask {
  const _VideoTask({
    required this.type,
    required this.state,
    required this.progress,
    required this.libraryId,
    this.doneCount = 0,
    this.totalCount = 0,
    this.error,
  });

  final String type;
  final String state;
  final double progress;
  final String? libraryId;
  /// 已完成 / 总条数（服务端 `done_count` / `total_count`）；0 表示这条任务没有条目口径
  final int doneCount;
  final int totalCount;
  final String? error;
}

class _TaskAgg {
  const _TaskAgg({
    required this.state,
    required this.progress,
    required this.done,
    required this.failed,
    this.doneCount = 0,
    this.totalCount = 0,
  });

  final String state;
  final double progress;
  final int done;
  final int failed;
  /// 面板右侧「已完成/总数」用的条数（来自运行中那条任务）
  final int doneCount;
  final int totalCount;
}

/// TMDB / 字幕语言：`值 → 展示名`。展示名一律用**该语言自己的写法**
/// （中文写「中文（简体）」、西班牙语写「Español」），
/// 这样不管界面语言是什么，用户都能一眼认出母语。
const List<(String, String)> kTmdbLanguages = [
  ('zh-CN', '中文（简体）'),
  ('zh-TW', '中文（繁體）'),
  ('en-US', 'English'),
  ('ja-JP', '日本語'),
  ('ko-KR', '한국어'),
  ('es-ES', 'Español'),
  ('fr-FR', 'Français'),
  ('de-DE', 'Deutsch'),
  ('ru-RU', 'Русский'),
  ('pt-BR', 'Português'),
  ('it-IT', 'Italiano'),
  ('th-TH', 'ไทย'),
  ('vi-VN', 'Tiếng Việt'),
];
