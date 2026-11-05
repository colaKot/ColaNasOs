import 'dart:async';

import 'package:flutter/material.dart';
import '../../shell/app_widgets.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/mobile_frame.dart';

/// 系统监控：CPU / 内存 / 磁盘，5 秒自动刷新。
class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key});

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  Map<String, dynamic>? _data;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ApiSession.instance.client.systemMonitor();
      if (!mounted) return;
      setState(() {
        _data = res;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  String _bytes(num v) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var n = v.toDouble();
    var i = 0;
    while (n >= 1024 && i < units.length - 1) {
      n /= 1024;
      i += 1;
    }
    return '${n.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final cpu = (d?['cpu'] as Map?)?.cast<String, dynamic>();
    final mem = (d?['mem'] as Map?)?.cast<String, dynamic>();
    final disk = (d?['disk'] as Map?)?.cast<String, dynamic>();
    final gpu = (d?['gpu'] as Map?)?.cast<String, dynamic>();
    final perCore = ((cpu?['perCore'] as List?) ?? const []).toList();

    return Scaffold(
      appBar: nasPageAppBar(
        context,
        title: tr('ui.monitor.001'),
        actions: [NasRefreshButton(onPressed: _load)],
      ),
      body: _error != null && d == null
          ? Center(
              child: Text(_error!, style: TextStyle(color: context.nasDanger)),
            )
          : d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(NasTokens.spaceLg),
              children: [
                _Metric(
                  label: 'CPU',
                  value: '${cpu?['usagePercent'] ?? 0}%',
                  detail:
                      tr('monitor.cpu', {'cores': cpu?['cores'] ?? 0, 'load': (cpu?['loadavg'] as List?)?.take(1).join() ?? '-'}),
                  ratio: ((cpu?['usagePercent'] as num?) ?? 0) / 100,
                ),
                if (perCore.isNotEmpty) ...[
                  const SizedBox(height: NasTokens.spaceSm),
                  Text(
                    tr('monitor.perCore'),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < perCore.length; i += 1)
                        SizedBox(
                          width: 96,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text('${i + 1}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: context.nasTextSecondary,
                                      )),
                                  const Spacer(),
                                  Text('${((perCore[i] as num?) ?? 0).toStringAsFixed(0)}%',
                                      style: const TextStyle(fontSize: 10)),
                                ],
                              ),
                              const SizedBox(height: 2),
                              LinearProgressIndicator(
                                // perCore 是 List<dynamic>，服务端采不到某个核的占用时
                                // 会给 null；裸写 `as num` 会抛
                                // 「Null is not a subtype of type num」把整页搞崩。
                                value: (((perCore[i] as num?) ?? 0) / 100)
                                    .clamp(0, 1)
                                    .toDouble(),
                                minHeight: 3,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: NasTokens.spaceLg),
                _Metric(
                  label: tr('home.gpu'),
                  value: gpu == null
                      ? '—'
                      : '${(gpu['usagePercent'] as num?) ?? 0}%',
                  detail: gpu == null
                      ? tr('home.gpuUnavailable')
                      : [
                          '${gpu['name'] ?? 'GPU'}',
                          ((gpu['memTotal'] as num?)?.toInt() ?? 0) > 0
                              ? '${_bytes((gpu['memUsed'] as num?)?.toInt() ?? 0)} / '
                                  '${_bytes((gpu['memTotal'] as num?)?.toInt() ?? 0)}'
                              : _bytes((gpu['memUsed'] as num?)?.toInt() ?? 0),
                          if ('${gpu['driverVersion'] ?? ''}'.isNotEmpty)
                            'v${gpu['driverVersion']}',
                        ].join(' · '),
                  ratio: gpu == null
                      ? 0
                      : (((gpu['usagePercent'] as num?) ?? 0) / 100)
                          .clamp(0, 1)
                          .toDouble(),
                ),
                const SizedBox(height: NasTokens.spaceLg),
                _Metric(
                  label: tr('ui.monitor.002'),
                  value:
                      '${_bytes((mem?['used'] as num?) ?? 0)} / ${_bytes((mem?['total'] as num?) ?? 0)}',
                  detail: tr('monitor.free', {'bytes': _bytes((mem?['free'] as num?) ?? 0)}),
                  ratio: ((mem?['total'] as num?) ?? 1) == 0
                      ? 0
                      : ((mem?['used'] as num?) ?? 0) /
                            ((mem?['total'] as num?) ?? 1),
                ),
                const SizedBox(height: NasTokens.spaceLg),
                _Metric(
                  label: tr('ui.monitor.003'),
                  value:
                      '${_bytes((disk?['used'] as num?) ?? 0)} / ${_bytes((disk?['total'] as num?) ?? 0)}',
                  detail: tr('monitor.free', {'bytes': _bytes((disk?['free'] as num?) ?? 0)}),
                  ratio: ((disk?['total'] as num?) ?? 1) == 0
                      ? 0
                      : ((disk?['used'] as num?) ?? 0) /
                            ((disk?['total'] as num?) ?? 1),
                ),
                const SizedBox(height: NasTokens.spaceXl),
                Text(
                  tr('monitor.uptime', {'hours': ((d['uptimeSec'] as num?) ?? 0) ~/ 3600, 'platform': d['platform'], 'arch': d['arch']}),
                  style: TextStyle(color: context.nasTextSecondary),
                ),
              ],
            ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.detail,
    required this.ratio,
  });

  final String label;
  final String value;
  final String detail;
  final double ratio;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: NasTokens.fontTitle)),
            Text(value, style: const TextStyle(fontSize: NasTokens.fontBody)),
          ],
        ),
        const SizedBox(height: NasTokens.spaceSm),
        ClipRRect(
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          child: LinearProgressIndicator(
            value: ratio.clamp(0, 1),
            minHeight: 8,
          ),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          detail,
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
      ],
    );
  }
}
