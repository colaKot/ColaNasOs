import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/session.dart';
import '../../shell/mobile_frame.dart';

/// Transmission 下载器（一级栏目）。
///
/// 定位是「看」而不是「管」：三组（下载中 / 暂停 / 做种），每行左边海报、
/// 右边片名 + 一行状态（进度 / 速度 / 体积）。真正的加种、选目录都在
/// 「发现 → PT / RSS」里做，这里不重复一遍。
class TransmissionPage extends StatefulWidget {
  const TransmissionPage({super.key});

  @override
  State<TransmissionPage> createState() => _TransmissionPageState();
}

class _TransmissionPageState extends State<TransmissionPage> {
  bool _loading = true;
  String _error = '';
  String _hint = '';

  /// 内置 transmission Web UI 的入口（「完整界面」按钮用）
  String _webPath = '';
  String _webTicket = '';
  bool _webReady = false;

  /// 当前用的是「内置」还是「外部」下载器（服务端 message 里点出来的）
  String _source = '';
  /// 服务端说的「transmission 未配置」这类情况：不是崩溃，用空状态提示更合适
  bool _ready = true;
  List<Map<String, dynamic>> _items = const [];

  /// 5 秒轮询：下载进度不动就没意义了，但也别太频繁（transmission RPC 会排队）
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    try {
      final res = await ApiSession.instance.client.ptTorrents();
      if (!mounted) return;
      final list = (res['items'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _items = list;
        _hint = (res['message'] ?? '').toString();
        _webPath = (res['webPath'] ?? '').toString();
        _webTicket = (res['webTicket'] ?? '').toString();
        _webReady = res['webReady'] == true;
        // 与服务端 /pt/torrents 的 message 前缀保持一致；用「内置 transmission」
        // 做关键字，避免以后微调标签文案又要同步改这里。
        _source = _hint.contains('内置 transmission')
            ? tr('transmission.builtin')
            : _hint.contains('自动发现')
                ? tr('transmission.external')
                : '';
        _ready = res['ok'] != false;
        _error = '';
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

  static const _downloading = <int>{1, 2, 3, 4};
  static const _paused = <int>{0};
  static const _seeding = <int>{5, 6};

  List<Map<String, dynamic>> _of(Set<int> statuses) =>
      _items.where((t) => statuses.contains(_status(t))).toList();

  int _status(Map<String, dynamic> t) => (t['status'] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final down = _of(_downloading);
    final paused = _of(_paused);
    final seeding = _of(_seeding);

    Widget body;
    if (_loading && _items.isEmpty) {
      body = const NasLoading();
    } else if (_error.isNotEmpty && _items.isEmpty) {
      body = NasErrorState(message: _error, onRetry: _load);
    } else {
      body = RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
        children: [
          if (_source.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                NasTokens.spaceXs,
                NasTokens.spaceMd,
                0,
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle,
                      size: 14, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    _source,
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
          if (down.isEmpty && paused.isEmpty && seeding.isEmpty)
            ListView(
              shrinkWrap: true,
              children: [
                NasEmptyState(
                  title: tr('transmission.empty'),
                  message: _ready
                      ? tr('transmission.emptyHint')
                      : (_hint.isEmpty ? tr('transmission.emptyHint') : _hint),
                  icon: Icons.download_outlined,
                ),
              ],
            ),
          if (down.isNotEmpty) _section(tr('transmission.downloading'), down),
          if (paused.isNotEmpty) _section(tr('transmission.paused'), paused),
          if (seeding.isNotEmpty) _section(tr('transmission.seeding'), seeding),
        ],
        ),
      );
    }

    return Scaffold(
      appBar: nasPageAppBar(
        context,
        title: tr('app.transmission'),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: tr('transmission.fullUi'),
            onPressed: _openWebUi,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr('common.refresh'),
            onPressed: () => _load(),
          ),
        ],
      ),
      body: body,
    );
  }

  static bool _isLoopback(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost' || host == '::1' || host.isEmpty;
  }

  /// 内置 Web UI 的地址：baseUrl 写死 127.0.0.1 时（外网/手机）改用页面同源，
  /// 再带上一次性票据换成 Cookie。
  String _webUiUrl() {
    final origin = Uri.base.origin;
    var base = ApiSession.instance.baseUrl.trim();
    if (base.isEmpty) base = origin;
    if (_isLoopback(base) && !_isLoopback(origin)) base = origin;
    final path = _webPath.isEmpty ? '/transmission/web/' : _webPath;
    final q = _webTicket.isEmpty ? '' : '?t=${Uri.encodeComponent(_webTicket)}';
    return '${base.replaceAll(RegExp(r'/+$'), '')}$path$q';
  }

  /// 打开 transmission 自带的完整 Web 界面（官方前端，由内核托管 + 反代 RPC）。
  Future<void> _openWebUi() async {
    if (!_webReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('transmission.webUiMissing'))),
      );
      return;
    }
    final ok = await launchUrl(
      Uri.parse(_webUiUrl()),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('transmission.openFailed'))),
      );
    }
  }

  Widget _section(String title, List<Map<String, dynamic>> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceMd,
            NasTokens.spaceXs,
          ),
          child: Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: NasTokens.fontSubtitle,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${rows.length}',
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ],
          ),
        ),
        for (final t in rows) _row(t),
      ],
    );
  }

  Widget _row(Map<String, dynamic> t) {
    final status = _status(t);
    final name = _titleOf(t);
    final percent = ((t['percent'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
    final size = (t['sizeBytes'] as num?)?.toInt() ?? 0;
    final rateDown = (t['rateDownload'] as num?)?.toInt() ?? 0;
    final rateUp = (t['rateUpload'] as num?)?.toInt() ?? 0;
    final ratio = (t['uploadRatio'] as num?)?.toDouble() ?? 0;
    final err = (t['error'] ?? '').toString();

    String sub;
    if (err.isNotEmpty) {
      sub = err;
    } else if (_downloading.contains(status)) {
      sub = '${(percent * 100).toStringAsFixed(1)}% · ↓ ${_speed(rateDown)}'
          '${size > 0 ? ' · ${_size(size)}' : ''}';
    } else if (_paused.contains(status)) {
      sub = '${tr('transmission.paused')} · ${(percent * 100).toStringAsFixed(1)}%'
          '${size > 0 ? ' · ${_size(size)}' : ''}';
    } else {
      sub = '${tr('transmission.seeding')} · ${tr('transmission.ratio')} '
          '${ratio.toStringAsFixed(2)} · ↑ ${_speed(rateUp)}';
    }

    return ListTile(
      dense: true,
      leading: _thumb(t),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        sub,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          color: err.isNotEmpty
              ? Theme.of(context).colorScheme.error
              : context.nasTextSecondary,
        ),
      ),
      trailing: _downloading.contains(status)
          ? SizedBox(
              width: 44,
              child: LinearProgressIndicator(value: percent, minHeight: 4),
            )
          : null,
    );
  }

  /// 片名：优先台账里的影视标题，其次种子名
  String _titleOf(Map<String, dynamic> t) {
    final title = (t['title'] ?? '').toString().trim();
    if (title.isNotEmpty) return title;
    return (t['name'] ?? '').toString();
  }

  Widget _thumb(Map<String, dynamic> t) {
    final poster = (t['posterPath'] ?? '').toString().trim();
    final w = 44.0;
    final h = 62.0;
    if (poster.isEmpty) {
      return SizedBox(
        width: w,
        height: h,
        child: Icon(Icons.movie_outlined, color: context.nasTextSecondary),
      );
    }
    final base = ApiSession.instance.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final url =
        '$base/api/v1/discover/image?path=${Uri.encodeComponent(poster)}&size=w185';
    return ClipRRect(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      child: SizedBox(
        width: w,
        height: h,
        child: NasCoverImage(url: url, cacheWidth: 120, icon: Icons.movie_outlined),
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes <= 0) return '-';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }

  static String _speed(int bytesPerSec) {
    if (bytesPerSec <= 0) return '0 B/s';
    return '${_size(bytesPerSec)}/s';
  }
}
