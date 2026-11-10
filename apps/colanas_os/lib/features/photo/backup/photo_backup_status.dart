import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 备份状态的「跨页面」快照。
///
/// 这一层刻意不 import `dart:io` / `photo_manager` / `connectivity_plus`：
/// 首页横条是 Web / 桌面也会编译的共享代码，只为了显示一个进度就把原生库
/// 拖进浏览器包里会直接编译失败。原生控制器把状态推到这里，UI 只读这里。
///
/// 快照同时是**断点续传的落盘对象**（`status.json`）：进程被系统回收后重启，
/// 至少能显示「上次备份了多少 / 什么时候完成」，而不是全部清零。
enum BackupUiPhase { off, idle, running, paused, done, error }

@immutable
class BackupStatusSnapshot {
  const BackupStatusSnapshot({
    this.phase = BackupUiPhase.off,
    this.enabled = false,
    this.running = false,
    this.waitingWifi = false,
    this.done = 0,
    this.total = 0,
    this.uploaded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.checked = 0,
    this.doneBytes = 0,
    this.totalBytes = 0,
    this.currentFile = '',
    this.message = '',
    this.lastFinishedAtMs = 0,
    this.lastUploaded = 0,
    this.totalBackedUp = 0,
    this.updatedAtMs = 0,
  });

  final BackupUiPhase phase;
  final bool enabled;
  final bool running;
  final bool waitingWifi;

  /// 本轮已处理条目（上传 + 服务端已有 + 失败 + 读不出原文件）。
  final int done;

  /// 本轮需要处理的总条目：扫描结束时**一次性确定**，之后不再增长。
  /// 以前用「已传字节 / 累计已加入的字节」当分母，每处理完一批就到 100%，
  /// 下一批又把分母撑大，进度条来回跳 —— 这里就是修那个问题。
  final int total;

  final int uploaded;
  final int skipped;
  final int failed;
  final int checked;
  final int doneBytes;
  final int totalBytes;
  final String currentFile;

  /// 文案键（`photo.backup.*`）或异常明文，UI 负责区分。
  final String message;

  /// 上次成功跑完一轮的时间 / 上传数，与累计已备份数。
  final int lastFinishedAtMs;
  final int lastUploaded;
  final int totalBackedUp;
  final int updatedAtMs;

  /// 0..1；本轮还没算出总数时返回 null（不确定进度条）。
  double? get progress {
    if (total <= 0) return null;
    return (done / total).clamp(0.0, 1.0).toDouble();
  }

  int get percent => progress == null ? 0 : (progress! * 100).round();

  bool get hasRunData => done > 0 || total > 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'phase': phase.name,
        'enabled': enabled,
        'running': running,
        'waitingWifi': waitingWifi,
        'done': done,
        'total': total,
        'uploaded': uploaded,
        'skipped': skipped,
        'failed': failed,
        'checked': checked,
        'doneBytes': doneBytes,
        'totalBytes': totalBytes,
        'currentFile': currentFile,
        'message': message,
        'lastFinishedAtMs': lastFinishedAtMs,
        'lastUploaded': lastUploaded,
        'totalBackedUp': totalBackedUp,
        'updatedAtMs': updatedAtMs,
      };

  factory BackupStatusSnapshot.fromJson(Map<String, dynamic> json) =>
      BackupStatusSnapshot(
        phase: BackupUiPhase.values.firstWhere(
          (v) => v.name == json['phase'],
          orElse: () => BackupUiPhase.off,
        ),
        enabled: json['enabled'] as bool? ?? false,
        running: false, // 进程重启后不可能还有在跑的一轮
        waitingWifi: json['waitingWifi'] as bool? ?? false,
        done: (json['done'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        uploaded: (json['uploaded'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        failed: (json['failed'] as num?)?.toInt() ?? 0,
        checked: (json['checked'] as num?)?.toInt() ?? 0,
        doneBytes: (json['doneBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        currentFile: json['currentFile'] as String? ?? '',
        message: json['message'] as String? ?? '',
        lastFinishedAtMs: (json['lastFinishedAtMs'] as num?)?.toInt() ?? 0,
        lastUploaded: (json['lastUploaded'] as num?)?.toInt() ?? 0,
        totalBackedUp: (json['totalBackedUp'] as num?)?.toInt() ?? 0,
        updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      );

  String encode() => jsonEncode(toJson());
}

/// 全局唯一的状态源：页面可以随便进出，它一直活着。
///
/// `publish` 做了「只在会影响 UI 的字段变化时通知」的节流：扫描阶段每 100 个
/// 素材就 notify 一次，全推给 ValueNotifier 会让首页横条无谓地重建几百次。
class PhotoBackupStatus extends ValueNotifier<BackupStatusSnapshot> {
  PhotoBackupStatus._() : super(const BackupStatusSnapshot());

  static final PhotoBackupStatus instance = PhotoBackupStatus._();

  void publish(BackupStatusSnapshot next) {
    final old = value;
    if (old.phase == next.phase &&
        old.enabled == next.enabled &&
        old.running == next.running &&
        old.waitingWifi == next.waitingWifi &&
        old.done == next.done &&
        old.total == next.total &&
        old.uploaded == next.uploaded &&
        old.lastFinishedAtMs == next.lastFinishedAtMs &&
        old.message == next.message) {
      return;
    }
    value = next;
  }
}
