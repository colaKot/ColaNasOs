import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:nas_core/nas_core.dart';

import '../../core/session.dart';
import 'transfer_device.dart';

/// 本机上传任务：持有 `XFile`（服务端拿不到它），其余状态一律以服务端会话为准。
///
/// 为什么不把任务塞进页面 State：以前就是这么写的，结果一离开「传输」页，
/// 上传就跟着 State 一起没了。这里放在单例里，页面只是订阅者。
class LocalUploadTask {
  LocalUploadTask({required this.file, required this.targetDir});

  final XFile file;
  final String targetDir;

  /// 会话 id：服务端行的主键，也是页面上用来对齐的键
  String sessionId = '';

  int size = 0;
  int sent = 0;
  int totalChunks = 1;
  bool canceled = false;
  bool paused = false;
  bool done = false;

  /// 正在跑（泵的占位标记）：避免同一轮 while 把同一个任务取两遍
  bool running = false;
  String? error;

  String get name => file.name;

  String get remotePath {
    final dir = targetDir.replaceAll(RegExp(r'/+$'), '');
    return '$dir/$name';
  }

  double get progress => size <= 0 ? 0 : (sent / size).clamp(0, 1);
}

/// 传输中心的数据源与上传执行器。
///
/// 三件事：
/// 1. **轮询** `GET /transfer/sessions`，拿到**整机所有来源**的会话（自己的、别的设备的、
///    别的用户的，还有照片备份与同步引擎在后台跑的那些）；
/// 2. **执行本机上传**：分片 + 断点续传 + 暂停/取消；
/// 3. 页面只订阅两个 `ValueNotifier`，不持有任何任务状态。
class TransferManager {
  TransferManager._();

  static final TransferManager instance = TransferManager._();

  /// 服务端返回的全部会话（已按 updatedAt 倒序）
  final ValueNotifier<List<TransferSession>> sessions =
      ValueNotifier<List<TransferSession>>(const <TransferSession>[]);

  /// 顶部小结：进行中 / 完成 / 失败 / 暂停 + 整机吞吐
  final ValueNotifier<TransferStats?> stats = ValueNotifier<TransferStats?>(
    null,
  );

  /// 本机正在跑的上传（键是会话 id；还没拿到 id 时用临时键）
  final Map<String, LocalUploadTask> localTasks = <String, LocalUploadTask>{};

  /// 本机任务变化时通知页面重绘（会话列表走另一个 notifier）
  final ValueNotifier<int> localRevision = ValueNotifier<int>(0);

  static const int _concurrency = 2;
  static const int _fallbackChunk = 4 * 1024 * 1024;

  Timer? _pollTimer;
  int _inflight = 0;
  bool _disposed = false;

  /// 页面进入时调用：立刻拉一次，然后每 1.5 s 轮询。
  /// 轮询而不是长连接：Web / 桌面 / 移动共用一套 transport，代价是一次小 JSON。
  void startPolling({Duration interval = const Duration(milliseconds: 1500)}) {
    _pollTimer?.cancel();
    unawaited(refresh());
    _pollTimer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  /// 页面离开时调用。**只停轮询，不停上传** —— 传输继续在后台跑。
  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> refresh() async {
    if (_disposed) return;
    try {
      final res = await ApiSession.instance.client.transferSessions(limit: 100);
      // 生成器对嵌套数组只给了 Map：手动转成强类型，页面就不必到处 `as String`
      sessions.value = res.items
          .map(TransferSession.fromJson)
          .toList(growable: false);
      stats.value = TransferStats.fromJson(res.stats);
    } catch (_) {
      // 断网 / 未登录：保留上次快照，别把列表清空吓人
    }
  }

  /// 选文件并加入上传队列（目标目录默认文件根）
  Future<int> addFiles(List<XFile> files, {String targetDir = '/'}) async {
    if (files.isEmpty) return 0;
    final dir = targetDir.trim().isEmpty ? '/' : targetDir.trim();
    for (final f in files) {
      final task = LocalUploadTask(file: f, targetDir: dir);
      localTasks[_draftKey(task)] = task;
    }
    _bump();
    unawaited(_pump());
    return files.length;
  }

  /// 临时键：会话 id 还没拿到时用来在 Map 里定位任务
  String _draftKey(LocalUploadTask task) => 'draft:${task.filePathOrName}';

  void _bump() {
    if (_disposed) return;
    localRevision.value = localRevision.value + 1;
  }

  /// 队列泵：同时最多跑 [_concurrency] 个，跑完一个补一个
  Future<void> _pump() async {
    while (_inflight < _concurrency) {
      final next = localTasks.values
          .where(
            (t) =>
                !t.running &&
                !t.done &&
                !t.canceled &&
                !t.paused &&
                t.error == null,
          )
          .firstOrNull;
      if (next == null) return;
      next.running = true;
      _inflight++;
      unawaited(
        _upload(next).whenComplete(() {
          next.running = false;
          _inflight--;
          _bump();
          unawaited(_pump());
        }),
      );
    }
  }

  Future<void> _upload(LocalUploadTask task) async {
    final client = ApiSession.instance.client;
    task.sent = 0;
    try {
      task.size = await task.file.length();
      _bump();

      final draftId = _newSessionId();
      // 先建会话（带上端与设备名），再走 check：check 会复用同 owner+path 的活跃会话，
      // 于是 origin/device 不会被空值覆盖回去。
      await client.transferBegin(
        body: TransferBeginBody(
          id: draftId,
          direction: 'upload',
          path: task.remotePath,
          size: task.size,
          totalChunks: task.size <= 0
              ? 0
              : (task.size + _fallbackChunk - 1) ~/ _fallbackChunk,
          origin: transferOrigin,
          device: transferDeviceName,
        ),
      );

      final check = await client.filesCheck(
        body: FilesCheckBody(path: task.remotePath, size: task.size),
      );

      if (check.exists) {
        task.sent = task.size;
        task.sessionId = check.sessionId ?? draftId;
        task.done = true; // 秒传：目标已存在，不必再传
        return;
      }

      final sid = check.sessionId ?? draftId;
      // 把临时键换成正式会话 id
      localTasks.removeWhere((_, v) => identical(v, task));
      task.sessionId = sid;
      localTasks[sid] = task;
      _bump();

      final chunkSize = check.chunkSize > 0 ? check.chunkSize : _fallbackChunk;
      task.totalChunks = task.size <= 0
          ? 1
          : ((task.size + chunkSize - 1) ~/ chunkSize);
      final have = check.uploaded.toSet();

      for (var i = 0; i < task.totalChunks; i++) {
        if (task.canceled) {
          await _safe(
            () =>
                client.transferCancel(body: TransferIdBody(id: task.sessionId)),
          );
          return;
        }
        if (task.paused) {
          await _safe(
            () =>
                client.transferPause(body: TransferIdBody(id: task.sessionId)),
          );
          return;
        }
        final start = i * chunkSize;
        final end = start + chunkSize > task.size
            ? task.size
            : start + chunkSize;
        if (!have.contains(i)) {
          final bytes = await _readRange(task.file, start, end);
          await client.filesChunk(
            path: task.remotePath,
            index: i,
            total: task.totalChunks,
            sid: task.sessionId,
            body: bytes,
          );
        }
        task.sent = end;
        _bump();
      }

      await client.filesMerge(
        body: FilesMergeBody(
          path: task.remotePath,
          total: task.totalChunks,
          size: task.size,
        ),
      );
      task.sent = task.size;
      await _safe(
        () => client.transferFinish(body: TransferIdBody(id: task.sessionId)),
      );
      task.done = true;
      _bump();
      unawaited(refresh());
    } catch (e) {
      if (task.canceled) return;
      task.error = e.toString();
      _bump();
      if (task.sessionId.isNotEmpty) {
        await _safe(
          () => ApiSession.instance.client.transferCancel(
            body: TransferIdBody(id: task.sessionId),
          ),
        );
      }
      unawaited(refresh());
    }
  }

  /// 跨平台读取区间（`XFile.openRead` 在桌面 / 移动 / Web 都可用，不引入 `dart:io`）
  Future<Uint8List> _readRange(XFile file, int start, int end) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(start, end)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _safe(Future<void> Function() run) async {
    try {
      await run();
    } catch (_) {
      /* 收口动作失败不覆盖已有错误 */
    }
  }

  String _newSessionId() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rnd = (ts % 100000).toString().padLeft(5, '0');
    return 'tf_${ts}_$rnd';
  }

  // ---------------------------------------------------------------- 控制

  /// 取消：本机任务立刻停；别人的任务只改服务端状态
  Future<void> cancel(String sessionId) async {
    final local = localTasks[sessionId];
    if (local != null) {
      local.canceled = true;
      _bump();
    }
    await _safe(
      () => ApiSession.instance.client.transferCancel(
        body: TransferIdBody(id: sessionId),
      ),
    );
    await refresh();
  }

  Future<void> pause(String sessionId) async {
    final local = localTasks[sessionId];
    if (local != null) {
      local.paused = true;
      _bump();
    }
    await _safe(
      () => ApiSession.instance.client.transferPause(
        body: TransferIdBody(id: sessionId),
      ),
    );
    await refresh();
  }

  /// 恢复：本机任务重新入泵；非本机会话只改服务端状态（真正续传要发起端配合）
  Future<void> resume(String sessionId) async {
    final local = localTasks[sessionId];
    if (local != null) {
      local.paused = false;
      local.error = null;
      _bump();
      unawaited(_pump());
    }
    await _safe(
      () => ApiSession.instance.client.transferResume(
        body: TransferIdBody(id: sessionId),
      ),
    );
    await refresh();
  }

  /// 重试失败的本机任务（服务端会话已 done/failed，begin 会另开一条）
  Future<void> retry(String sessionId) async {
    final local = localTasks[sessionId];
    if (local == null) {
      unawaited(refresh());
      return;
    }
    localTasks.remove(sessionId);
    local.sessionId = '';
    local.sent = 0;
    local.error = null;
    local.paused = false;
    local.canceled = false;
    local.done = false;
    localTasks[_draftKey(local)] = local;
    _bump();
    unawaited(_pump());
  }

  /// 清掉已结束的旧会话记录（不碰磁盘文件）
  Future<int> prune() async {
    try {
      final res = await ApiSession.instance.client.transferPrune();
      await refresh();
      return (res['affected'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  void dispose() {
    _disposed = true;
    stopPolling();
    sessions.dispose();
    stats.dispose();
    localRevision.dispose();
  }
}

/// `firstOrNull`：本项目没有 collection 扩展，自己补一个（避免引入额外的包）
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

extension _FilePathOf on LocalUploadTask {
  /// 临时键用：优先真实路径，Web 上退化为名字
  String get filePathOrName => '$targetDir/${file.name}';
}
