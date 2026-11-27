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

  /// 动态照片的视频分量**总是**一起上传（开关已移除，见 2026-11-27 反馈）。
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
/// 进度口径（2026-11-27 改）：
///   - 分母 = 相册里的**全部资产数**（扫描结束时定死，`totalAssets`）；
///   - 分子 = **上次已备份数 + 本轮完成数**（`baseDone + done`），只增不减；
///   - 扫描还没数完时分母给 0，界面显示「正在统计相册…」而不是 0/N。
///
/// 之前的分子只算本轮，于是每轮都从 0 开始，看起来像「又从头备份一遍」。
/// 也不能拿「已完成字节 / 已加入字节」当分母：每跑完一批就 100%，下一批
/// 又把分母撑大，进度条来回跳。
class BackupRuntime {
  BackupPhase phase = BackupPhase.off;
  bool running = false;
  bool paused = false;
  int checked = 0;
  int alreadyBackedUp = 0;
  /// 相册里的全部资产数（含已备份的）。本轮扫描时统计，0 = 还没数完。
  int totalAssets = 0;
  /// 扫描是否已经数完。没数完时进度按「不确定」显示，避免用户看到
  /// 一个 0/逐渐变大 的分数，误以为又从零开始备份。
  bool assetsCounted = false;
  /// 本轮开始前已经备份过的数量：进度分子的起点。
  ///
  /// 以前分子只算本轮，每轮都从 0 开始，用户看到的就是「又从头备份一遍」。
  int baseDone = 0;
  int runTotal = 0;
  int omitted = 0;
  int uploaded = 0;
  int skipped = 0;
  int failed = 0;
  int doneBytes = 0;
  int totalBytes = 0;
  String currentFile = '';
  String error = '';

  /// 每个 entry 恰好贡献一次：上传成功 / 服务端已有 / 失败 / 原文件取不到，
  /// 四种结果都记一笔，分母才对得上。
  int get done => uploaded + skipped + failed + omitted;

  /// 展示用的分子：**上次备份数 + 本轮完成数**，只增不减。
  int get shownDone => baseDone + done;

  /// 展示用的分母：相册全部资产数；还没统计出来时退回本轮待办数。
  int get shownTotal =>
      assetsCounted ? (totalAssets > 0 ? totalAssets : runTotal) : 0;

  double? get progress {
    if (shownTotal <= 0) return null;
    return (shownDone / shownTotal).clamp(0.0, 1.0).toDouble();
  }

  void reset() {
    phase = BackupPhase.idle;
    running = false;
    paused = false;
    checked = 0;
    alreadyBackedUp = 0;
    totalAssets = 0;
    assetsCounted = false;
    baseDone = 0;
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
