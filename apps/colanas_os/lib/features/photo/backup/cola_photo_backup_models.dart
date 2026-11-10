import 'dart:convert';

/// 手机相册备份的模型层。
///
/// 整机只维护**一份**配置（BackupTask），不建多任务；运行记录与文件级明细
/// 分开存，重启后靠「已处理素材 id」做零 I/O 增量，不依赖内存里的进度。

enum BackupPhase { off, idle, running, paused, done, error }

enum BackupDirStyle { byAlbum, byMonth, byYear }

enum BackupTrigger { manual, autoStart, rescan, networkResume }

enum BackupFileStatus { success, skipped, error }

extension BackupDirStyleX on BackupDirStyle {
  String get key => switch (this) {
        BackupDirStyle.byAlbum => 'album',
        BackupDirStyle.byMonth => 'month',
        BackupDirStyle.byYear => 'year',
      };

  static BackupDirStyle fromKey(String? v) => switch (v) {
        'album' => BackupDirStyle.byAlbum,
        'year' => BackupDirStyle.byYear,
        _ => BackupDirStyle.byMonth,
      };
}

extension BackupFileStatusX on BackupFileStatus {
  String get key => switch (this) {
        BackupFileStatus.success => 'success',
        BackupFileStatus.skipped => 'skipped',
        BackupFileStatus.error => 'error',
      };

  static BackupFileStatus fromKey(String? v) => switch (v) {
        'error' => BackupFileStatus.error,
        'skipped' => BackupFileStatus.skipped,
        _ => BackupFileStatus.success,
      };
}

class BackupTask {
  const BackupTask({
    this.enabled = false,
    this.sourceIds = const <String>[],
    this.sourceNames = const <String>[],
    this.targetDir = '',
    this.dirStyle = BackupDirStyle.byYear,
    this.uploadLivePhotoVideo = false,
    this.onlyPhotos = false,
    this.renameByDate = false,
    this.useCellular = false,
    this.savingMode = false,
    this.keepScreenOn = false,
    this.deviceName = '',
  });

  /// 总开关。开启后：登录成功 / 回到 WiFi 时自动跑一轮。
  final bool enabled;

  /// 空 = 全部相册。
  final List<String> sourceIds;
  final List<String> sourceNames;
  final String targetDir;
  final BackupDirStyle dirStyle;

  /// 苹果实况 / 鸿蒙动态照片的视频分量是否单独上传。
  final bool uploadLivePhotoVideo;
  final bool onlyPhotos;
  final bool renameByDate;
  final bool useCellular;
  final bool savingMode;
  final bool keepScreenOn;
  final String deviceName;

  bool get hasSource => sourceIds.isEmpty || sourceIds.isNotEmpty;

  BackupTask copyWith({
    bool? enabled,
    List<String>? sourceIds,
    List<String>? sourceNames,
    String? targetDir,
    BackupDirStyle? dirStyle,
    bool? uploadLivePhotoVideo,
    bool? onlyPhotos,
    bool? renameByDate,
    bool? useCellular,
    bool? savingMode,
    bool? keepScreenOn,
    String? deviceName,
  }) =>
      BackupTask(
        enabled: enabled ?? this.enabled,
        sourceIds: sourceIds ?? this.sourceIds,
        sourceNames: sourceNames ?? this.sourceNames,
        targetDir: targetDir ?? this.targetDir,
        dirStyle: dirStyle ?? this.dirStyle,
        uploadLivePhotoVideo: uploadLivePhotoVideo ?? this.uploadLivePhotoVideo,
        onlyPhotos: onlyPhotos ?? this.onlyPhotos,
        renameByDate: renameByDate ?? this.renameByDate,
        useCellular: useCellular ?? this.useCellular,
        savingMode: savingMode ?? this.savingMode,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        deviceName: deviceName ?? this.deviceName,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'sourceIds': sourceIds,
        'sourceNames': sourceNames,
        'targetDir': targetDir,
        'dirStyle': dirStyle.key,
        'uploadLivePhotoVideo': uploadLivePhotoVideo,
        'onlyPhotos': onlyPhotos,
        'renameByDate': renameByDate,
        'useCellular': useCellular,
        'savingMode': savingMode,
        'keepScreenOn': keepScreenOn,
        'deviceName': deviceName,
      };

  factory BackupTask.fromJson(Map<String, dynamic> json) => BackupTask(
        enabled: json['enabled'] as bool? ?? false,
        sourceIds: _strings(json['sourceIds']),
        sourceNames: _strings(json['sourceNames']),
        targetDir: json['targetDir'] as String? ?? '',
        dirStyle: BackupDirStyleX.fromKey(json['dirStyle'] as String?),
        uploadLivePhotoVideo: json['uploadLivePhotoVideo'] as bool? ?? false,
        onlyPhotos: json['onlyPhotos'] as bool? ?? false,
        renameByDate: json['renameByDate'] as bool? ?? false,
        useCellular: json['useCellular'] as bool? ?? false,
        savingMode: json['savingMode'] as bool? ?? false,
        keepScreenOn: json['keepScreenOn'] as bool? ?? false,
        deviceName: json['deviceName'] as String? ?? '',
      );

  static List<String> _strings(Object? raw) => raw is List
      ? raw.whereType<String>().toList(growable: false)
      : const <String>[];

  String encode() => jsonEncode(toJson());
}

class BackupRun {
  const BackupRun({
    required this.id,
    required this.trigger,
    required this.startedAtMs,
    this.finishedAtMs,
    this.successCount = 0,
    this.failedCount = 0,
    this.skippedCount = 0,
    this.totalBytes = 0,
  });

  final String id;
  final BackupTrigger trigger;
  final int startedAtMs;
  final int? finishedAtMs;
  final int successCount;
  final int failedCount;
  final int skippedCount;
  final int totalBytes;

  BackupRun finish({
    required int finishedAtMs,
    required int successCount,
    required int failedCount,
    required int skippedCount,
    required int totalBytes,
  }) =>
      BackupRun(
        id: id,
        trigger: trigger,
        startedAtMs: startedAtMs,
        finishedAtMs: finishedAtMs,
        successCount: successCount,
        failedCount: failedCount,
        skippedCount: skippedCount,
        totalBytes: totalBytes,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'trigger': trigger.name,
        'startedAtMs': startedAtMs,
        'finishedAtMs': finishedAtMs,
        'successCount': successCount,
        'failedCount': failedCount,
        'skippedCount': skippedCount,
        'totalBytes': totalBytes,
      };

  factory BackupRun.fromJson(Map<String, dynamic> json) => BackupRun(
        id: json['id'] as String? ?? '',
        trigger: BackupTrigger.values.firstWhere(
          (v) => v.name == json['trigger'],
          orElse: () => BackupTrigger.manual,
        ),
        startedAtMs: (json['startedAtMs'] as num?)?.toInt() ?? 0,
        finishedAtMs: (json['finishedAtMs'] as num?)?.toInt(),
        successCount: (json['successCount'] as num?)?.toInt() ?? 0,
        failedCount: (json['failedCount'] as num?)?.toInt() ?? 0,
        skippedCount: (json['skippedCount'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      );
}

class BackupFileRecord {
  const BackupFileRecord({
    required this.runId,
    required this.sourceUniqueId,
    required this.displayName,
    required this.size,
    required this.status,
    required this.atMs,
    this.error = '',
  });

  final String runId;
  final String sourceUniqueId;
  final String displayName;
  final int size;
  final BackupFileStatus status;
  final int atMs;
  final String error;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'runId': runId,
        'sourceUniqueId': sourceUniqueId,
        'displayName': displayName,
        'size': size,
        'status': status.key,
        'atMs': atMs,
        'error': error,
      };

  factory BackupFileRecord.fromJson(Map<String, dynamic> json) =>
      BackupFileRecord(
        runId: json['runId'] as String? ?? '',
        sourceUniqueId: json['sourceUniqueId'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        status: BackupFileStatusX.fromKey(json['status'] as String?),
        atMs: (json['atMs'] as num?)?.toInt() ?? 0,
        error: json['error'] as String? ?? '',
      );
}

/// 一轮备份的实时计数。UI 直接读这些字段，Controller 每次变化都 notifyListeners()。
///
/// 进度口径（2026-11-07 修）：扫描结束时把 `runTotal` 一次定死，
/// `done` 只增不减，进度条 = done / runTotal，单调递增。
/// 旧实现拿「已完成字节 / 已加入的字节」当分母，每跑完一批就 100%，
/// 下一批又把分母撑大，进度条来回跳；退出页面再进来 rt.reset() 又全清零。
class BackupRuntime {
  BackupPhase phase = BackupPhase.off;
  bool running = false;
  bool paused = false;
  int checked = 0;
  int alreadyBackedUp = 0;
  int runTotal = 0;
  int omitted = 0;
  int uploaded = 0;
  int skipped = 0;
  int failed = 0;
  int doneBytes = 0;
  int totalBytes = 0;
  String currentFile = '';
  String error = '';

  /// 本轮已处理的条目数。每个 entry 恰好贡献一次：上传成功 / 服务端已有 /
  /// 失败 / 原文件取不到，四种结果都记一笔，分母才对得上。
  int get done => uploaded + skipped + failed + omitted;

  double? get progress {
    if (runTotal <= 0) return null;
    return (done / runTotal).clamp(0.0, 1.0).toDouble();
  }

  void reset() {
    phase = BackupPhase.idle;
    running = false;
    paused = false;
    checked = 0;
    alreadyBackedUp = 0;
    runTotal = 0;
    omitted = 0;
    uploaded = 0;
    skipped = 0;
    failed = 0;
    doneBytes = 0;
    totalBytes = 0;
    currentFile = '';
    error = '';
  }
}
