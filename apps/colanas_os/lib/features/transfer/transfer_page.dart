import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/mobile_frame.dart';
import 'transfer_manager.dart';

/// 传输中心。
///
/// 与旧实现的差别（旧版只有「我在这页选的文件」）：
/// - 数据来自服务端会话表，**任何一端、任何用户**的传输都能看到；
/// - 手机照片备份、双向同步这些后台在跑的上传也会自动出现在这里；
/// - 页面只是订阅者：离开页面传输继续，回来还在跑。
class TransferPage extends StatefulWidget {
  const TransferPage({super.key});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

/// 筛选桶：面板上四颗 chip 一一对应
enum _Bucket { all, active, done, failed }

class _TransferPageState extends State<TransferPage> {
  final TextEditingController _dirCtrl = TextEditingController(text: '/');
  final TransferManager _mgr = TransferManager.instance;
  _Bucket _bucket = _Bucket.all;
  bool _pruning = false;

  @override
  void initState() {
    super.initState();
    _mgr.startPolling();
  }

  @override
  void dispose() {
    // 只停轮询：正在传的东西要继续在后台跑完
    _mgr.stopPolling();
    _dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final files = await openFiles();
    if (files.isEmpty) return;
    final added = await _mgr.addFiles(files, targetDir: _dirCtrl.text.trim());
    if (!mounted) return;
    NasSnack.show(context, tr('transfer.added', {'count': '$added'}));
  }

  Future<void> _prune() async {
    setState(() => _pruning = true);
    final n = await _mgr.prune();
    if (!mounted) return;
    setState(() => _pruning = false);
    NasSnack.show(context, tr('transfer.pruned', {'count': '$n'}));
  }

  bool _inBucket(TransferSession s) {
    switch (_bucket) {
      case _Bucket.all:
        return true;
      case _Bucket.active:
        return s.state == 'active' ||
            s.state == 'pending' ||
            s.state == 'paused';
      case _Bucket.done:
        return s.state == 'done';
      case _Bucket.failed:
        return s.state == 'failed' || s.state == 'canceled';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: nasPageAppBar(
        context,
        title: tr('ui.transfer.001'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: tr('ui.transfer.002'),
            onPressed: _pick,
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: tr('transfer.prune'),
            onPressed: _pruning ? null : _prune,
          ),
        ],
      ),
      body: Column(
        // 默认的 center 会让「宽度跟内容走」的子组件（分隔线以外的各种条）横向居中，
        // 页面里就出现几条各自为政的中轴线。统一 stretch，全部左边缘对齐。
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _uploadBar(),
          const Divider(height: 1),
          _statsBar(),
          _filterBar(),
          const Divider(height: 1),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _uploadBar() {
    // 原来 helperText 挂在 TextField 里，Row 又默认垂直居中 ——
    // 按钮对齐的是「输入框 + 提示行」整块的中线，视觉上就比输入框低了一截。
    // 现在提示行独立出来，Row 里只剩等高的输入框和按钮。
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceMd,
        NasTokens.spaceMd,
        NasTokens.spaceSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _dirCtrl,
                  decoration: InputDecoration(
                    labelText: tr('transfer.uploadDir'),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              SizedBox(
                // 与 isDense + OutlineInputBorder 的输入框同高（48），
                // 两边都定死才不会随字体缩放错位
                height: 48,
                child: FilledButton.icon(
                  onPressed: _pick,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('ui.transfer.006')),
                ),
              ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceXs + 2),
          Text(
            tr('ui.transfer.005'),
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statsBar() {
    return ValueListenableBuilder<TransferStats?>(
      valueListenable: _mgr.stats,
      builder: (context, stats, _) {
        final active = stats?.active ?? 0;
        final done = stats?.done ?? 0;
        final failed = stats?.failed ?? 0;
        final speed = stats?.speedBps ?? 0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceMd,
            NasTokens.spaceSm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('transfer.statsLine', {
                    'active': '$active',
                    'done': '$done',
                    'failed': '$failed',
                  }),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (active > 0 && speed > 0) ...[
                Icon(Icons.speed, size: 16, color: context.nasTextSecondary),
                const SizedBox(width: NasTokens.spaceXs),
                Text(
                  '${_fmtBytes(speed)}/s',
                  style: TextStyle(color: context.nasTextSecondary),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _filterBar() {
    final chips = <_Bucket, String>{
      _Bucket.all: tr('transfer.all'),
      _Bucket.active: tr('transfer.inProgress'),
      _Bucket.done: tr('transfer.completed'),
      _Bucket.failed: tr('transfer.failedState'),
    };
    // SingleChildScrollView 的宽度跟着内容走，而外层 Column 默认 crossAxisAlignment.center，
    // 于是这排 chip 就在页面正中间「悬浮」着，跟左边对齐的统计行完全不在一条竖线上。
    // 用 Align 撑满宽度再靠左，chips 从左边起排，跟上面的输入框、下面的列表对齐。
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          NasTokens.spaceMd,
          NasTokens.spaceXs,
          NasTokens.spaceMd,
          NasTokens.spaceXs,
        ),
        child: Row(
          children: [
            for (final entry in chips.entries)
              Padding(
                padding: const EdgeInsets.only(right: NasTokens.spaceSm),
                child: ChoiceChip(
                  label: Text(entry.value),
                  selected: _bucket == entry.key,
                  onSelected: (_) => setState(() => _bucket = entry.key),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    return ValueListenableBuilder<List<TransferSession>>(
      valueListenable: _mgr.sessions,
      builder: (context, all, _) {
        // 本机任务的进度比服务端更细（服务端只在分片边界落库），跟着它刷新
        return ValueListenableBuilder<int>(
          valueListenable: _mgr.localRevision,
          builder: (context, _, _) {
            final items = all.where(_inBucket).toList(growable: false);
            if (items.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.swap_vert,
                      size: 42,
                      color: context.nasTextSecondary,
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    Text(
                      tr('transfer.empty'),
                      style: TextStyle(color: context.nasTextSecondary),
                    ),
                  ],
                ),
              );
            }
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _row(items[i]),
            );
          },
        );
      },
    );
  }

  Widget _row(TransferSession s) {
    final isUpload = s.direction == 'upload';
    final total = s.size;
    final done = s.transferred.clamp(0, total <= 0 ? s.transferred : total);
    final ratio = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
    final local = _mgr.localTasks[s.id];
    final active = s.state == 'active' || s.state == 'pending';
    final ended = s.state == 'done' || s.state == 'canceled';

    // 服务端的 `owner` 是 uid，客户端只知道登录名：靠 `ownerName`（服务端 join 出来的）
    // 判断「这条是不是我发起的」。两者都没有时退回 uid，至少还能区分不同人。
    final me = ApiSession.instance.username;
    final who = (me != null && s.ownerName == me)
        ? tr('transfer.byMe')
        : (s.ownerName?.isNotEmpty == true ? s.ownerName! : s.owner);
    final source = s.device.isNotEmpty ? '$who · ${s.device}' : who;

    return ListTile(
      leading: Icon(
        isUpload ? Icons.file_upload_outlined : Icons.file_download_outlined,
        color: s.state == 'failed'
            ? context.nasDanger
            : (ended ? context.nasTextSecondary : null),
      ),
      title: Text(
        s.name.isEmpty ? s.path : s.name,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            '$source · ${_fmtBytes(total)}${isUpload ? '' : ''}',
            style: TextStyle(
              color: context.nasTextSecondary,
              fontSize: NasTokens.fontCaption,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (active || s.state == 'paused') ...[
            const SizedBox(height: NasTokens.spaceXs),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: s.state == 'paused' ? ratio : ratio,
                minHeight: 4,
              ),
            ),
            const SizedBox(height: NasTokens.spaceXs),
            Text(
              _progressText(s, ratio, isUpload),
              style: TextStyle(
                color: context.nasTextSecondary,
                fontSize: NasTokens.fontCaption,
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: NasTokens.spaceXs),
              child: Text(
                _stateText(s),
                style: TextStyle(
                  color: s.state == 'failed'
                      ? context.nasDanger
                      : context.nasTextSecondary,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active && local != null)
            IconButton(
              icon: const Icon(Icons.pause_circle_outline),
              tooltip: tr('transfer.pause'),
              onPressed: () => _mgr.pause(s.id),
            ),
          if (s.state == 'paused')
            IconButton(
              icon: const Icon(Icons.play_circle_outline),
              tooltip: tr('transfer.resume'),
              onPressed: () => _mgr.resume(s.id),
            ),
          if (s.state == 'failed' && local != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: tr('ui.transfer.008'),
              onPressed: () => _mgr.retry(s.id),
            ),
          if (active || s.state == 'paused')
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: tr('transfer.cancel'),
              onPressed: () => _mgr.cancel(s.id),
            ),
        ],
      ),
    );
  }

  String _progressText(TransferSession s, double? ratio, bool isUpload) {
    final percent = ((ratio ?? 0) * 100).toStringAsFixed(0);
    final head = isUpload
        ? tr('transfer.uploading', {'percent': percent})
        : tr('transfer.downloading', {'percent': percent});
    return '$head · ${_fmtBytes(s.transferred)} / ${_fmtBytes(s.size)}';
  }

  String _stateText(TransferSession s) {
    switch (s.state) {
      case 'pending':
        return tr('transfer.queued');
      case 'done':
        return tr('transfer.done');
      case 'canceled':
        return tr('transfer.canceled');
      case 'failed':
        return tr('transfer.failed', {'error': s.error ?? ''});
      case 'paused':
        return tr('transfer.paused');
      default:
        return tr('transfer.queued');
    }
  }

  /// 人类可读大小：面板上全是 B/KB/MB，别显示 1048576
  static String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = value >= 100 || unit == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }
}
