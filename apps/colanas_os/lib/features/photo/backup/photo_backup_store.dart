import 'dart:convert';

import 'backup_store_io.dart'
    if (dart.library.js_interop) 'backup_store_web.dart' as backend;
import 'cola_photo_backup_models.dart';
import 'photo_backup_status.dart';

/// 备份数据的本地持久化。
///
/// 与「配置只有一份」对应：task.json 小文件整写；已处理素材与文件级明细用
/// JSONL 只追加（1.9 万张也不会因为每次写全量 JSON 卡住）；运行记录条数有限，
/// 结束时整写一次。所有读失败都返回空集合，不因为磁盘问题让页面起不来。
class PhotoBackupStore {
  PhotoBackupStore._();

  static final PhotoBackupStore instance = PhotoBackupStore._();

  bool get persistent => backend.persistent;

  BackupTask? _taskCache;
  final Set<String> _handled = <String>{};
  bool _handledLoaded = false;
  List<BackupRun>? _runsCache;
  final Map<String, String> _hashes = <String, String>{};
  bool _hashesLoaded = false;

  Future<BackupTask> loadTask() async {
    final cached = _taskCache;
    if (cached != null) return cached;
    final raw = await backend.readText('task.json');
    BackupTask task = const BackupTask();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          task = BackupTask.fromJson(decoded);
        }
      } catch (_) {
        // 损坏就当默认配置
      }
    }
    _taskCache = task;
    return task;
  }

  Future<void> saveTask(BackupTask task) async {
    _taskCache = task;
    await backend.writeText('task.json', task.encode());
  }

  /// 已处理素材 id 集合：`success` 与 `skipped` 都算已处理。
  /// 少了 skipped 会导致「关掉 App 再打开又从头算一遍 MD5」。
  Future<Set<String>> loadHandled() async {
    if (_handledLoaded) return _handled;
    final raw = await backend.readText('handled.jsonl');
    if (raw != null && raw.isNotEmpty) {
      for (final line in const LineSplitter().convert(raw)) {
        if (line.trim().isEmpty) continue;
        final tab = line.indexOf('\t');
        if (tab <= 0) continue;
        final status = line.substring(tab + 1);
        if (status == 'success' || status == 'skipped') {
          _handled.add(line.substring(0, tab));
        }
      }
    }
    _handledLoaded = true;
    return _handled;
  }

  Future<void> markHandled(String id, BackupFileStatus status) async {
    await loadHandled();
    final ok = status == BackupFileStatus.success ||
        status == BackupFileStatus.skipped;
    if (ok) _handled.add(id);
    await backend.appendLine(
      'handled.jsonl',
      '$id\t${status.key}',
    );
  }

  bool isHandled(String id) => _handled.contains(id);

  /// 累计已备份的素材数（含「服务端已有」跳过的），给首页横条 / 进度卡做常量。
  int get handledCount => _handled.length;

  /// 实时进度快照：退出页面、甚至进程被回收后重启，数字都不会「从头开始」。
  /// 写得很轻（整写一个小 JSON），调用方负责节流。
  Future<BackupStatusSnapshot?> loadStatus() async {
    final raw = await backend.readText('status.json');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return BackupStatusSnapshot.fromJson(decoded);
      }
    } catch (_) {
      // 损坏就当没有快照
    }
    return null;
  }

  Future<void> saveStatus(BackupStatusSnapshot snapshot) async {
    await backend.writeText('status.json', snapshot.encode());
  }

  /// 本地文件内容 MD5 缓存：`素材id|size|mtime` → md5。
  /// 没有它，App 每次重启都要把几万张原图重新读一遍算哈希。
  /// 只追加 JSONL，读失败按「没缓存」处理（重算即可，不影响正确性）。
  Future<String?> loadHash(String key) async {
    if (!_hashesLoaded) {
      final raw = await backend.readText('hash.jsonl');
      if (raw != null && raw.isNotEmpty) {
        for (final line in const LineSplitter().convert(raw)) {
          if (line.trim().isEmpty) continue;
          final tab = line.indexOf('\t');
          if (tab <= 0) continue;
          _hashes[line.substring(0, tab)] = line.substring(tab + 1);
        }
      }
      _hashesLoaded = true;
    }
    return _hashes[key];
  }

  Future<void> saveHash(String key, String md5) async {
    if (key.isEmpty || md5.isEmpty) return;
    if (_hashes[key] == md5) return;
    _hashes[key] = md5;
    if (_hashes.length > 60000) _hashes.clear();
    await backend.appendLine('hash.jsonl', '$key\t$md5');
  }

  Future<List<BackupRun>> loadRuns() async {
    final cached = _runsCache;
    if (cached != null) return cached;
    final raw = await backend.readText('runs.json');
    final runs = <BackupRun>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map<String, dynamic>) runs.add(BackupRun.fromJson(e));
          }
        }
      } catch (_) {
        // 损坏就当没有记录
      }
    }
    runs.sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
    _runsCache = runs;
    return runs;
  }

  Future<void> saveRun(BackupRun run) async {
    final runs = await loadRuns();
    final idx = runs.indexWhere((r) => r.id == run.id);
    if (idx >= 0) {
      runs[idx] = run;
    } else {
      runs.insert(0, run);
    }
    // 只留最近 50 轮，避免文件无限增长
    if (runs.length > 50) runs.removeRange(50, runs.length);
    _runsCache = runs;
    await backend.writeText(
      'runs.json',
      jsonEncode(runs.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> deleteRun(String runId) async {
    final runs = await loadRuns();
    runs.removeWhere((r) => r.id == runId);
    _runsCache = runs;
    await backend.writeText(
      'runs.json',
      jsonEncode(runs.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> appendFileRecord(BackupFileRecord record) async {
    await backend.appendLine(
      'files.jsonl',
      jsonEncode(record.toJson()),
    );
  }

  Future<List<BackupFileRecord>> fileRecords(String runId) async {
    final raw = await backend.readText('files.jsonl');
    if (raw == null || raw.isEmpty) return const <BackupFileRecord>[];
    final out = <BackupFileRecord>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          final r = BackupFileRecord.fromJson(decoded);
          if (r.runId == runId) out.add(r);
        }
      } catch (_) {
        // 跳过坏行
      }
    }
    return out;
  }
}
