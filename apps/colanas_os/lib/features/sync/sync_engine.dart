import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:nas_core/nas_core.dart';

import '../../core/session.dart';
import 'sync_fs.dart';

/// 任务级策略（与服务端 `sync_json` 同结构）
class SyncTaskConfig {
  const SyncTaskConfig({
    this.realtime = false,
    this.intervalMinutes = 30,
    this.conflictStrategy = 'manual',
    this.deleteExtra = true,
  });

  final bool realtime;
  final int intervalMinutes;

  /// manual（不猜，默认）/ prefer_newer / prefer_local / prefer_remote
  final String conflictStrategy;
  final bool deleteExtra;

  factory SyncTaskConfig.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const <String, dynamic>{};
    final strategy = '${j['conflictStrategy'] ?? 'manual'}';
    final rawInterval = j['intervalMinutes'];
    return SyncTaskConfig(
      realtime: j['realtime'] == true,
      intervalMinutes:
          rawInterval == null ? 30 : (rawInterval as num).toInt().clamp(0, 1440),
      conflictStrategy: const [
        'prefer_newer',
        'prefer_local',
        'prefer_remote',
      ].contains(strategy)
          ? strategy
          : 'manual',
      deleteExtra: j['deleteExtra'] != false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'realtime': realtime,
        'intervalMinutes': intervalMinutes,
        'conflictStrategy': conflictStrategy,
        'deleteExtra': deleteExtra,
      };
}

/// 同步任务（服务端 `sync_tasks`）
class SyncTask {
  const SyncTask({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.mode,
    required this.status,
    required this.localDir,
    required this.remoteDir,
    required this.include,
    required this.exclude,
    this.filterConfig = const SyncFilterConfig(),
    this.syncConfig = const SyncTaskConfig(),
    required this.createdAt,
    required this.updatedAt,
    this.name = '',
    this.lastRunAt,
    this.lastError,
  });

  final String id;
  final String deviceId;
  final String deviceName;

  /// 任务名；服务端尚未落库时为空，卡片回退显示设备名
  final String name;
  final String mode;
  final String status;
  final String localDir;
  final String remoteDir;
  final List<String> include;
  final List<String> exclude;
  final SyncFilterConfig filterConfig;
  final SyncTaskConfig syncConfig;
  final int createdAt;
  final int updatedAt;
  final int? lastRunAt;
  final String? lastError;

  factory SyncTask.fromJson(Map<String, dynamic> json) => SyncTask(
        id: '${json['id']}',
        deviceId: '${json['deviceId'] ?? ''}',
        deviceName: '${json['deviceName'] ?? ''}',
        name: '${json['name'] ?? ''}',
        mode: '${json['mode'] ?? 'bidirectional'}',
        status: '${json['status'] ?? 'idle'}',
        localDir: '${json['localDir'] ?? ''}',
        remoteDir: '${json['remoteDir'] ?? ''}',
        include: ((json['include'] as List?) ?? const [])
            .map((e) => '$e')
            .toList(),
        exclude: ((json['exclude'] as List?) ?? const [])
            .map((e) => '$e')
            .toList(),
        filterConfig: SyncFilterConfig.fromJson(
          (json['filterConfig'] as Map?)?.cast<String, dynamic>(),
        ),
        syncConfig: SyncTaskConfig.fromJson(
          (json['syncConfig'] as Map?)?.cast<String, dynamic>(),
        ),
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
        lastRunAt: (json['lastRunAt'] as num?)?.toInt(),
        lastError: json['lastError'] == null ? null : '${json['lastError']}',
      );

  Map<String, dynamic> toUpsertBody() => <String, dynamic>{
        'id': id,
        'name': name,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'mode': mode,
        'localDir': localDir,
        'remoteDir': remoteDir,
        'include': include,
        'exclude': exclude,
        'filterConfig': filterConfig.toJson(),
        'syncConfig': syncConfig.toJson(),
      };
}

/// 三向比对返回的单个动作
class SyncPlanAction {
  const SyncPlanAction({
    required this.kind,
    required this.path,
    required this.reason,
    this.size = 0,
    this.mtimeMs = 0,
    this.remoteSize = 0,
    this.remoteMtimeMs = 0,
  });

  final String kind;
  final String path;
  final String reason;
  final int size;
  final int mtimeMs;
  final int remoteSize;
  final int remoteMtimeMs;

  factory SyncPlanAction.fromJson(Map<String, dynamic> json) => SyncPlanAction(
        kind: '${json['kind']}',
        path: '${json['path']}',
        reason: '${json['reason'] ?? ''}',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mtimeMs: (json['mtimeMs'] as num?)?.toInt() ?? 0,
        remoteSize: (json['remoteSize'] as num?)?.toInt() ?? 0,
        remoteMtimeMs: (json['remoteMtimeMs'] as num?)?.toInt() ?? 0,
      );
}

/// 同步阶段（scanning → planning → transferring → cleaning → reporting）
class SyncPhase {
  static const scanning = 'scanning';
  static const planning = 'planning';
  static const transferring = 'transferring';
  static const cleaning = 'cleaning';
  static const reporting = 'reporting';
  static const done = 'done';
  static const failed = 'failed';
}

class SyncProgress {
  const SyncProgress({
    this.phase = SyncPhase.scanning,
    this.totalActions = 0,
    this.doneActions = 0,
    this.bytesTotal = 0,
    this.bytesDone = 0,
    this.currentPath = '',
    this.error,
  });

  final String phase;
  final int totalActions;
  final int doneActions;
  final int bytesTotal;
  final int bytesDone;
  final String currentPath;
  final String? error;

  bool get finished => phase == SyncPhase.done || phase == SyncPhase.failed;

  double get percent {
    if (bytesTotal > 0) {
      return (bytesDone / bytesTotal).clamp(0.0, 1.0);
    }
    if (totalActions > 0) {
      return (doneActions / totalActions).clamp(0.0, 1.0);
    }
    return 0;
  }

  SyncProgress copyWith({
    String? phase,
    int? totalActions,
    int? doneActions,
    int? bytesTotal,
    int? bytesDone,
    String? currentPath,
    String? error,
  }) =>
      SyncProgress(
        phase: phase ?? this.phase,
        totalActions: totalActions ?? this.totalActions,
        doneActions: doneActions ?? this.doneActions,
        bytesTotal: bytesTotal ?? this.bytesTotal,
        bytesDone: bytesDone ?? this.bytesDone,
        currentPath: currentPath ?? this.currentPath,
        error: error ?? this.error,
      );
}

class SyncRunResult {
  const SyncRunResult({
    required this.ok,
    this.error,
    this.uploaded = 0,
    this.downloaded = 0,
    this.deleted = 0,
    this.skipped = 0,
    this.conflicts = 0,
    this.failed = 0,
    this.bytes = 0,
    this.errors = const [],
  });

  final bool ok;
  final String? error;
  final int uploaded;
  final int downloaded;
  final int deleted;
  final int skipped;
  final int conflicts;
  final int failed;
  final int bytes;
  final List<String> errors;
}

class _SyncCancelled implements Exception {
  const _SyncCancelled();
}

/// 同步执行引擎（客户端侧）。
///
/// 服务端负责扫远端 + 三向比对 + 记录基线；客户端负责扫描本地、执行上传/下载/删除。
/// 关键约定：上下行都回写 mtime（下载后 `setLastModified`、上传时 `merge.mtimeMs`），
/// 否则下一轮会把「时间戳不同」当成「内容被修改」而重复传输。
class SyncEngine {
  SyncEngine._();

  static final SyncEngine instance = SyncEngine._();

  final SyncFs fs = createSyncFs();

  final Map<String, SyncProgress> _progress = <String, SyncProgress>{};
  final Set<String> _running = <String>{};
  final Set<String> _cancel = <String>{};

  /// 进度变化计数（UI 监听它重建）
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool isRunning(String id) => _running.contains(id);

  SyncProgress? progressOf(String id) => _progress[id];

  void cancel(String id) {
    if (_running.contains(id)) _cancel.add(id);
  }

  void clearProgress(String id) {
    _progress.remove(id);
    revision.value += 1;
  }

  void _set(String id, SyncProgress value) {
    _progress[id] = value;
    revision.value += 1;
  }

  void _throwIfCancelled(String id) {
    if (_cancel.contains(id)) throw const _SyncCancelled();
  }

  Future<SyncRunResult> run(SyncTask task) async {
    if (!fs.canSync) {
      return const SyncRunResult(
        ok: false,
        error: 'sync_requires_desktop',
      );
    }
    if (!_running.add(task.id)) {
      return const SyncRunResult(ok: false, error: 'sync_already_running');
    }
    _cancel.remove(task.id);

    var uploaded = 0;
    var downloaded = 0;
    var deleted = 0;
    var skipped = 0;
    var conflicts = 0;
    var failed = 0;
    var bytes = 0;
    final errors = <String>[];
    final applied = <Map<String, dynamic>>[];

    try {
      _set(task.id, const SyncProgress(phase: SyncPhase.scanning));
      final local = await fs.scan(
        task.localDir,
        include: task.include,
        exclude: task.exclude,
        filter: task.filterConfig,
      );
      _throwIfCancelled(task.id);

      _set(
        task.id,
        SyncProgress(phase: SyncPhase.planning, totalActions: local.length),
      );
      final plan = await ApiSession.instance.client.syncPlan(
        body: <String, dynamic>{
          'taskId': task.id,
          'local': [for (final e in local) e.toJson()],
        },
      );
      final actions = ((plan['actions'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => SyncPlanAction.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      final bytesTotal = (plan['stats'] is Map
              ? ((plan['stats'] as Map)['bytes'] as num?)?.toInt()
              : null) ??
          0;
      final totalActions = actions.length;
      var doneActions = 0;
      var bytesDone = 0;

      void bump(String phase, String currentPath) {
        _set(
          task.id,
          SyncProgress(
            phase: phase,
            totalActions: totalActions,
            doneActions: doneActions,
            bytesTotal: bytesTotal,
            bytesDone: bytesDone,
            currentPath: currentPath,
          ),
        );
      }

      final deleteRemote = <String>[];

      for (final action in actions) {
        _throwIfCancelled(task.id);
        switch (action.kind) {
          case 'upload':
            bump(SyncPhase.transferring, action.path);
            try {
              final ok = await _upload(task, action, (delta) {
                bytesDone += delta;
                bump(SyncPhase.transferring, action.path);
              });
              if (ok) {
                uploaded += 1;
                bytes += action.size;
                applied.add({'path': action.path, 'kind': 'upload', 'ok': true});
              } else {
                skipped += 1;
              }
            } catch (e) {
              failed += 1;
              errors.add('${action.path}: $e');
              applied.add({'path': action.path, 'kind': 'upload', 'ok': false});
            }
            break;
          case 'download':
            bump(SyncPhase.transferring, action.path);
            try {
              await _download(task, action, (received) {
                bytesDone += received;
                bump(SyncPhase.transferring, action.path);
              });
              downloaded += 1;
              bytes += action.remoteSize;
              applied.add({'path': action.path, 'kind': 'download', 'ok': true});
            } catch (e) {
              if (_isCancel(e)) rethrow;
              failed += 1;
              errors.add('${action.path}: $e');
              applied.add({
                'path': action.path,
                'kind': 'download',
                'ok': false,
              });
            }
            break;
          case 'deleteLocal':
            bump(SyncPhase.cleaning, action.path);
            try {
              await fs.deleteLocal(_localPath(task, action.path));
              deleted += 1;
              applied.add({
                'path': action.path,
                'kind': 'deleteLocal',
                'ok': true,
              });
            } catch (e) {
              failed += 1;
              errors.add('${action.path}: $e');
            }
            break;
          case 'deleteRemote':
            deleteRemote.add(action.path);
            break;
          case 'conflict':
            conflicts += 1;
            applied.add({
              'path': action.path,
              'kind': 'conflict',
              'ok': false,
            });
            break;
          default:
            skipped += 1;
            applied.add({'path': action.path, 'kind': 'skip', 'ok': true});
        }
        doneActions += 1;
      }

      if (deleteRemote.isNotEmpty) {
        bump(SyncPhase.cleaning, '');
        try {
          final res = await ApiSession.instance.client.syncDeleteRemote(
            body: <String, dynamic>{
              'taskId': task.id,
              'paths': deleteRemote,
            },
          );
          final removed = (res['removed'] as num?)?.toInt() ?? 0;
          deleted += removed;
          for (final rel in deleteRemote) {
            applied.add({'path': rel, 'kind': 'deleteRemote', 'ok': true});
          }
        } catch (e) {
          failed += deleteRemote.length;
          errors.add('deleteRemote: $e');
        }
        doneActions += deleteRemote.length;
      }

      _set(
        task.id,
        SyncProgress(
          phase: SyncPhase.reporting,
          totalActions: doneActions,
          doneActions: doneActions,
          bytesTotal: bytesTotal,
          bytesDone: bytesDone,
        ),
      );
      final status = failed > 0
          ? 'failed'
          : conflicts > 0
              ? 'partial'
              : 'done';
      try {
        await ApiSession.instance.client.syncReport(
          body: <String, dynamic>{
            'taskId': task.id,
            'applied': applied,
            'bytes': bytes,
            'status': status,
            if (errors.isNotEmpty) 'error': errors.take(20).join('; '),
          },
        );
      } catch (e) {
        // 回写失败不改变本轮结果：文件已经同步完了，下一轮还能重算
        errors.add('report: $e');
      }

      _set(
        task.id,
        SyncProgress(
          phase: SyncPhase.done,
          totalActions: doneActions,
          doneActions: doneActions,
          bytesTotal: bytesTotal,
          bytesDone: bytesDone,
        ),
      );

      return SyncRunResult(
        ok: failed == 0,
        uploaded: uploaded,
        downloaded: downloaded,
        deleted: deleted,
        skipped: skipped,
        conflicts: conflicts,
        failed: failed,
        bytes: bytes,
        errors: errors,
      );
    } catch (e) {
      final cancelled = _isCancel(e);
      final message = cancelled ? 'sync_cancelled' : '$e';
      _set(
        task.id,
        SyncProgress(phase: SyncPhase.failed, error: message),
      );
      try {
        await ApiSession.instance.client.syncReport(
          body: <String, dynamic>{
            'taskId': task.id,
            'applied': applied,
            'bytes': bytes,
            'status': 'failed',
            'error': message.length > 500 ? message.substring(0, 500) : message,
          },
        );
      } catch (_) {}
      return SyncRunResult(
        ok: false,
        error: message,
        uploaded: uploaded,
        downloaded: downloaded,
        deleted: deleted,
        skipped: skipped,
        conflicts: conflicts,
        failed: failed + 1,
        bytes: bytes,
        errors: errors,
      );
    } finally {
      _running.remove(task.id);
      _cancel.remove(task.id);
      revision.value += 1;
    }
  }

  /// 上传一个文件：秒传预检 → 分片 → 合并（带 mtime 对齐）。
  /// 返回 false 表示服务端已有同尺寸文件（本轮跳过，不算失败）。
  Future<bool> _upload(
    SyncTask task,
    SyncPlanAction action,
    void Function(int delta) onProgress,
  ) async {
    final client = ApiSession.instance.client;
    final remoteRel = joinPosix([task.remoteDir, action.path]);
    final localPath = _localPath(task, action.path);

    final check = await client.filesCheck(
      body: FilesCheckBody(path: remoteRel, size: action.size),
    );
    if (check.exists) return false;

    final chunkSize = math.max(1, check.chunkSize);
    final total = action.size == 0
        ? 0
        : math.max(1, (action.size + chunkSize - 1) ~/ chunkSize);
    for (var i = 0; i < total; i += 1) {
      _throwIfCancelled(task.id);
      final start = i * chunkSize;
      final end = math.min(action.size, start + chunkSize);
      final bytes = await fs.readChunk(localPath, start, end);
      await client.filesChunk(
        path: remoteRel,
        index: i,
        total: total,
        body: bytes,
      );
      onProgress(bytes.length);
    }

    await client.filesMerge(
      body: FilesMergeBody(
        path: remoteRel,
        total: total,
        size: action.size,
        mtimeMs: action.mtimeMs.toDouble(),
      ),
    );
    return true;
  }

  Future<void> _download(
    SyncTask task,
    SyncPlanAction action,
    void Function(int received) onProgress,
  ) async {
    final remoteRel = joinPosix([task.remoteDir, action.path]);
    final token = ApiSession.instance.token ?? '';
    final uri = Uri.parse('${ApiSession.instance.baseUrl}/api/v1/files/download')
        .replace(queryParameters: {'path': remoteRel});
    await fs.download(
      uri: uri,
      headers: {'authorization': 'Bearer $token', 'accept': '*/*'},
      localPath: _localPath(task, action.path),
      mtimeMs: action.remoteMtimeMs,
      onProgress: onProgress,
      cancelled: () => _cancel.contains(task.id),
    );
  }

  String _localPath(SyncTask task, String rel) =>
      '${task.localDir.replaceAll(RegExp(r'[/\\\\]+$'), '')}/$rel';

  bool _isCancel(Object e) =>
      e is _SyncCancelled || e.toString().toLowerCase().contains('cancel');
}
