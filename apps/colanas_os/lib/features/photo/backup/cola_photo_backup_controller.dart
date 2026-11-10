import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/session.dart';
import 'cola_photo_backup_models.dart';
import 'photo_backup_notification.dart';
import 'photo_backup_status.dart';
import 'photo_backup_store.dart';

/// 手机相册备份控制器（单向增量：本机 → NAS）。
///
/// 与「选几个文件传一下」的区别在于四件事：
/// 1. 整机只维护一份配置，开启后登录成功 / 回到 WiFi 自动跑一轮；
/// 2. 已处理素材按 id 落盘，`success` 和 `skipped` 都算已处理，重启后零 I/O 跳过；
/// 3. 内容级去重：size 预检 → 按需算本地 MD5 → 服务端比对 `content_md5`；
/// 4. 实况照片的视频分量单独上传且与主图同名（服务端才能重新配对）。
///
/// **进程级单例**（2026-11-07 改）：以前是备份页 State 的一个字段，页面一 dispose
/// 就把网络监听和上传循环一起带走了 —— 切出页面 / 最小化就停。现在由
/// `startPhotoBackupService()` 在 App 启动时 `init()`，页面只是观察者。
///
/// 网络口径：**未勾选「允许使用移动数据」时，绝不走移动网络**。
/// 网络状态未知 / 离线 / 只有蜂窝时一律不发一个字节；WiFi 掉了立刻暂停，
/// 连回来自动续跑（靠 handled.jsonl 接着传，不重传已完成的）。
class PhotoBackupController extends ChangeNotifier {
  factory PhotoBackupController() => instance;

  PhotoBackupController._();

  static final PhotoBackupController instance = PhotoBackupController._();

  static const int _pageSize = 100;
  static const int _batchSize = 200;
  static const int _concurrency = 5;
  static const int _maxAttempts = 3;
  static const int _minLiveVideoBytes = 32 * 1024;
  static const int _statusSaveGapMs = 700;

  final PhotoBackupStore _store = PhotoBackupStore.instance;
  ApiClient get _client => ApiSession.instance.client;

  BackupTask? task;
  final BackupRuntime rt = BackupRuntime();
  bool loading = true;
  String permissionError = '';

  bool _running = false;
  bool _starting = false;
  bool _cancelled = false;
  bool _manualCancel = false;
  bool _rescanAll = false;
  bool _autoTriggered = false;
  bool _pausedByNetwork = false;
  bool _pendingWifiStart = false;
  bool _resumeScheduled = false;
  bool _wifi = false;
  bool _online = false;
  bool _networkKnown = false;
  bool _wakeLockHeld = false;
  bool _initialized = false;
  bool _notificationStarted = false;
  int _lastFinishedAtMs = 0;
  int _lastUploaded = 0;
  int _lastStatusSaveMs = 0;

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  final Map<String, String> _md5Cache = <String, String>{};
  // 一轮内已经处理过的内容指纹：批内 / 跨批出现相同内容只传第一次。
  // 没有它，相册里同一张原图被多个相册（或微信、截图目录）各存一份就会重复上传。
  final Set<String> _runHandledMd5 = <String>{};
  // 一轮内各 size 出现次数：同 size 出现多次才值得算 MD5 做内容比对。
  final Map<int, int> _runSizeCount = <int, int>{};

  bool get isRunning => _running;
  bool get hasPhotoSource => true;
  bool get waitingWifi => rt.paused;
  int get totalBackedUp => _store.handledCount;

  /// 当前账号的相册源（NAS 上的库）。备份目标只能是其中之一。
  List<PhotoLibraryItem> libraries = const <PhotoLibraryItem>[];

  String get defaultTargetDir {
    if (libraries.isNotEmpty) return libraries.first.path;
    return 'photo-backup';
  }

  /// 老配置存的 `photo-backup` / `photo-backup/<设备>` 是 files 根下的相对目录，
  /// 那时还没有「选源」的概念。这两个形态一律当未设置处理。
  bool _isLegacyTarget(String t) =>
      t == 'photo-backup' || t.startsWith('photo-backup/');

  String get effectiveTargetDir {
    final t = (task?.targetDir ?? '').trim();
    if (t.isNotEmpty && !_isLegacyTarget(t)) return t;
    return defaultTargetDir;
  }

  String get targetLabel {
    final dir = effectiveTargetDir;
    for (final l in libraries) {
      if (l.path == dir) return l.name;
    }
    return dir;
  }

  /// 拉相册源列表。未登录 / 离线时静默跳过，保持上一次的结果。
  Future<void> loadLibraries() async {
    if (!ApiSession.instance.authState.value) return;
    try {
      final res = await _client.photoLibraryList();
      libraries = res.items;
      notifyListeners();
    } catch (_) {
      // 网络或服务端不可用时不影响备份本身
    }
  }

  /// 读取本机型号，用来在 NAS 上分层：`MobilePhoto/<型号>/2026/`。
  Future<String> _detectDeviceName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        final model = a.model.trim();
        if (model.isNotEmpty) return model;
        final brand = a.brand.trim();
        if (brand.isNotEmpty) return brand;
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        final name = i.name.trim();
        if (name.isNotEmpty) return name;
        final machine = i.utsname.machine.trim();
        if (machine.isNotEmpty) return machine;
      } else if (Platform.isWindows) {
        final w = await info.windowsInfo;
        final name = w.computerName.trim();
        if (name.isNotEmpty) return name;
      }
    } catch (_) {
      // 插件不可用（测试环境 / 不支持的平台）时退回系统名
    }
    return Platform.operatingSystem;
  }

  /// 首次运行时把型号写进配置。已经有值就不动 —— 用户可能手动改过。
  Future<void> _ensureDeviceName() async {
    final t = task;
    if (t == null) return;
    if (t.deviceName.trim().isNotEmpty) return;
    var name = _safeSegment(await _detectDeviceName()).trim();
    if (name.isEmpty) name = Platform.operatingSystem;
    task = t.copyWith(deviceName: name);
    await _store.saveTask(task!);
  }

  /// 只跑一次：恢复配置 / 进度快照、挂登录与网络监听、按开关自动开跑。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    task = await _store.loadTask();
    await _store.loadHandled();
    await _ensureDeviceName();
    final saved = await _store.loadStatus();
    if (saved != null) {
      _lastFinishedAtMs = saved.lastFinishedAtMs;
      _lastUploaded = saved.lastUploaded;
      // 快照里 running=true 说明上次进程被系统回收在一轮备份中间。
      // handled.jsonl 已经把传过的记下来了，autoStart 会接着跑，不会重传。
    }
    rt.phase = (task?.enabled ?? false) ? BackupPhase.idle : BackupPhase.off;
    loading = false;
    notifyListeners();

    ApiSession.instance.authState.addListener(_onAuthChanged);
    try {
      _connSub = Connectivity().onConnectivityChanged.listen(_applyConnectivity);
    } catch (_) {
      // 桌面 / 单测里插件可能没有实现：网络守卫退化成「不允许」，绝不放行
    }
    await _refreshNetwork();
    _onAuthChanged();
  }

  void _onAuthChanged() {
    // 登出后重新登录要能再自动跑一轮，否则一张照片都进不来
    if (!ApiSession.instance.authState.value) {
      _autoTriggered = false;
      return;
    }
    unawaited(loadLibraries());
    if (_autoTriggered) return;
    final t = task;
    if (t == null || !t.enabled || _running || _starting) return;
    // 开关是落盘的：这次打开过，以后每次启动 App 都会走到这里。
    _autoTriggered = true;
    unawaited(startBackup(BackupTrigger.autoStart));
  }

  /// 从后台切回前台也补跑一轮增量（开关记住之后，这是「打开 App 就备份」的
  /// 另一半）。10 分钟内刚跑完就跳过，避免来回切 App 反复枚举相册 id。
  Future<void> onAppResumed() async {
    final t = task;
    if (t == null || !t.enabled || _running || _starting) return;
    await _refreshNetwork();
    if (_pendingWifiStart || _pausedByNetwork) {
      _maybeResume();
      return;
    }
    final since = DateTime.now().millisecondsSinceEpoch - _lastFinishedAtMs;
    if (_lastFinishedAtMs > 0 && since < 10 * 60 * 1000) return;
    unawaited(startBackup(BackupTrigger.autoStart));
  }

  Future<void> _refreshNetwork() async {
    try {
      _applyConnectivity(await Connectivity().checkConnectivity());
    } catch (_) {
      // 保留上一次结果；拿不到网络状态就按「不允许」处理，绝不猜成 WiFi
    }
  }

  void _applyConnectivity(List<ConnectivityResult> results) {
    final wifi = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    final online = results.any((r) => r != ConnectivityResult.none);
    final wasWifi = _wifi;
    _wifi = wifi;
    _online = online;
    _networkKnown = true;
    final t = task;
    if (t == null) return;
    // 正在 WiFi 上备份，人走了 WiFi 掉了 → 立刻收尾停传。
    // 不直接 kill 上传任务，_cancelled 会在下一个分片/文件边界生效，
    // 已传的分片服务端有断点，续跑不会重来。
    if (!t.useCellular && !wifi && wasWifi && _running) {
      _pauseForNetwork();
    }
    _maybeResume();
  }

  /// 唯一的网络放行口径。
  bool _networkAllowed(BackupTask t) =>
      _networkKnown && _online && (t.useCellular || _wifi);

  void _pauseForNetwork() {
    if (_pausedByNetwork) return;
    _cancelled = true;
    _pausedByNetwork = true;
    rt.paused = true;
    rt.phase = BackupPhase.paused;
    rt.error = 'photo.backup.pausedMobile';
    notifyListeners();
  }

  /// 连回 WiFi（或用户允许了移动数据）后，接着上一轮把没传完的传掉。
  void _maybeResume() {
    final t = task;
    if (t == null || !t.enabled || _running || _starting) return;
    if (!(_pausedByNetwork || _pendingWifiStart)) return;
    if (!_networkAllowed(t)) return;
    if (_resumeScheduled) return;
    _resumeScheduled = true;
    _pausedByNetwork = false;
    _pendingWifiStart = false;
    Future.microtask(() {
      _resumeScheduled = false;
      unawaited(startBackup(BackupTrigger.networkResume));
    });
  }

  @override
  void dispose() { // ignore: must_call_super
    // 故意不取消监听、不 super.dispose()：这是进程级单例，页面 State 以前
    // 会调它，结果一离开备份页后台上传和通知栏就全停了。真正的清理交给进程退出。
  }

  /// 只在 App 真正退出时才有意义（目前没有这个时点）；放在这里是为了让
  /// 网络监听的句柄有归属，不要被当成无用字段删掉。
  Future<void> shutdown() async {
    ApiSession.instance.authState.removeListener(_onAuthChanged);
    await _connSub?.cancel();
    _connSub = null;
    await photoBackupNotification.stop();
  }

  // ------------------------------------------------------- 状态快照 / 通知栏

  BackupUiPhase get _uiPhase => switch (rt.phase) {
        BackupPhase.off => BackupUiPhase.off,
        BackupPhase.idle => BackupUiPhase.idle,
        BackupPhase.running => BackupUiPhase.running,
        BackupPhase.paused => BackupUiPhase.paused,
        BackupPhase.done => BackupUiPhase.done,
        BackupPhase.error => BackupUiPhase.error,
      };

  BackupStatusSnapshot _snapshot() => BackupStatusSnapshot(
        phase: _uiPhase,
        enabled: task?.enabled ?? false,
        running: _running,
        waitingWifi: rt.paused,
        done: rt.done,
        total: rt.runTotal,
        uploaded: rt.uploaded,
        skipped: rt.skipped,
        failed: rt.failed,
        checked: rt.checked,
        doneBytes: rt.doneBytes,
        totalBytes: rt.totalBytes,
        currentFile: rt.currentFile,
        message: rt.error,
        lastFinishedAtMs: _lastFinishedAtMs,
        lastUploaded: _lastUploaded,
        totalBackedUp: _store.handledCount,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  /// 每次 notifyListeners() 都把状态同步给：首页横条（读内存）、status.json
  /// （退出页面 / 进程重启后不丢数字）、通知栏（切后台也看得到进度）。
  @override
  void notifyListeners() {
    super.notifyListeners();
    final s = _snapshot();
    PhotoBackupStatus.instance.publish(s);
    final now = s.updatedAtMs;
    if (now - _lastStatusSaveMs >= _statusSaveGapMs) {
      _lastStatusSaveMs = now;
      unawaited(_store.saveStatus(s));
    }
    _pushNotification(s);
  }

  void _pushNotification(BackupStatusSnapshot s) {
    if (!_notificationStarted) return;
    if (rt.phase == BackupPhase.paused) {
      photoBackupNotification.update(
        title: tr('photo.backup.notifyPaused'),
        text: tr('photo.backup.waitWifi'),
        percent: s.percent,
        indeterminate: s.total <= 0,
      );
    } else if (rt.phase == BackupPhase.running) {
      photoBackupNotification.update(
        title: tr('photo.backup.notifyTitle'),
        text: s.total > 0
            ? tr('photo.backup.notifyText', <String, Object>{
                'done': '${s.done}',
                'total': '${s.total}',
                'uploaded': '${s.uploaded}',
              })
            : tr('photo.backup.notifyScanning'),
        percent: s.percent,
        indeterminate: s.total <= 0,
      );
    }
  }

  Future<void> _save(BackupTask next) async {
    task = next;
    rt.phase = !next.enabled
        ? BackupPhase.off
        : (_running
            ? BackupPhase.running
            : (rt.paused ? BackupPhase.paused : BackupPhase.idle));
    await _store.saveTask(next);
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    final t = task;
    if (t == null) return;
    if (value) {
      final ok = await ensurePermission();
      if (!ok) return;
      // Android 13+ 不给通知权限，前台服务的通知栏不显示（服务仍保活）。
      unawaited(photoBackupNotification.ensurePermission());
    }
    await _save(t.copyWith(enabled: value));
    if (!value) {
      // 关掉开关 = 立刻停止，不再等 WiFi、不再续跑、撤掉通知。
      if (_running) _cancelled = true;
      _manualCancel = true;
      _pausedByNetwork = false;
      _pendingWifiStart = false;
      rt.paused = false;
      rt.error = '';
      await photoBackupNotification.stop();
      _notificationStarted = false;
      notifyListeners();
      return;
    }
    if (!_running) await requestBackupNow();
  }

  Future<void> setSourceIds(List<String> ids, List<String> names) async {
    final t = task;
    if (t == null || _running) return;
    await _save(t.copyWith(sourceIds: ids, sourceNames: names));
  }

  Future<void> setTargetDir(String dir) async {
    final t = task;
    if (t == null || _running) return;
    await _save(t.copyWith(targetDir: dir.trim()));
  }

  Future<void> setDirStyle(BackupDirStyle style) async {
    final t = task;
    if (t == null || _running) return;
    await _save(t.copyWith(dirStyle: style));
  }

  Future<void> setUploadLivePhotoVideo(bool v) async {
    final t = task;
    if (t == null || _running) return;
    await _save(t.copyWith(uploadLivePhotoVideo: v));
  }

  Future<void> setOnlyPhotos(bool v) async {
    final t = task;
    if (t == null || _running) return;
    await _save(t.copyWith(onlyPhotos: v));
  }

  Future<void> setRenameByDate(bool v) async {
    final t = task;
    if (t == null || _running) return;
    await _save(t.copyWith(renameByDate: v));
  }

  /// 允许在运行中改：正用移动网络备份时关掉这个开关要立刻停，不能等下一轮。
  Future<void> setUseCellular(bool v) async {
    final t = task;
    if (t == null) return;
    await _save(t.copyWith(useCellular: v));
    if (!v && _running && !_wifi) _pauseForNetwork();
    _maybeResume();
  }

  Future<void> setSavingMode(bool v) async {
    final t = task;
    if (t == null || _running) return;
    await _save(t.copyWith(savingMode: v));
  }

  Future<void> setKeepScreenOn(bool v) async {
    final t = task;
    if (t == null || _running) return;
    await _save(t.copyWith(keepScreenOn: v));
  }

  Future<bool> ensurePermission() async {
    if (kIsWeb) return true;
    try {
      final state = await pm.PhotoManager.requestPermissionExtend();
      if (state.hasAccess) {
        permissionError = '';
        notifyListeners();
        return true;
      }
      permissionError = 'photo.backup.permissionMissing';
      notifyListeners();
      return false;
    } catch (e) {
      permissionError = 'photo.backup.permissionMissing';
      notifyListeners();
      return false;
    }
  }

  Future<void> openPermissionSettings() async {
    try {
      await pm.PhotoManager.openSetting();
    } catch (_) {
      // 平台不支持打开设置页时忽略
    }
  }

  Future<void> requestBackupNow() async {
    final t = task;
    if (t == null) return;
    if (!t.enabled) {
      await setEnabled(true);
      return;
    }
    await startBackup(BackupTrigger.manual);
  }

  Future<void> startBackupAll() async {
    _rescanAll = true;
    await startBackup(BackupTrigger.rescan);
  }

  void cancelTask() {
    if (!_running) return;
    _cancelled = true;
    _manualCancel = true;
    rt.error = 'photo.backup.manualCancel';
    notifyListeners();
  }

  Future<List<BackupRun>> listRuns() => _store.loadRuns();

  Future<List<BackupFileRecord>> fileRecords(String runId) =>
      _store.fileRecords(runId);

  Future<void> deleteRun(String runId) => _store.deleteRun(runId);

  // ---------------------------------------------------------------- 主流程

  Future<void> startBackup(BackupTrigger trigger) async {
    if (_running || _starting) return;
    final t = task;
    if (t == null || kIsWeb || !t.enabled) return;
    _starting = true;
    try {
      if (!await ensurePermission()) return;
      await _refreshNetwork();
      if (!_networkAllowed(t)) {
        // 开关开着但在移动网络 / 离线：一个字节都不发，只记「等 WiFi」。
        // 前台服务照常挂着 —— 进程被系统冻住就收不到连回 WiFi 的回调了，
        // 那条第 4 点需求（连回来自动续跑）会变成「要手动打开 App 才继续」。
        _pendingWifiStart = true;
        rt.paused = true;
        rt.phase = BackupPhase.paused;
        rt.error = 'photo.backup.waitWifi';
        await photoBackupNotification.start(
          title: tr('photo.backup.notifyPaused'),
          text: tr('photo.backup.waitWifi'),
          channelName: tr('photo.backup.notifyChannel'),
        );
        _notificationStarted = true;
        notifyListeners();
        return;
      }
      _pendingWifiStart = false;
      _pausedByNetwork = false;
      await _run(t, trigger);
    } finally {
      _starting = false;
      // 必须在 _starting 归零之后再判续跑：网络暂停的那一轮刚收尾时，
      // WiFi 可能已经回来了，_run 的 finally 里判会被 _starting 挡掉。
      _maybeResume();
    }
  }

  Future<void> _run(BackupTask t, BackupTrigger trigger) async {
    _running = true;
    rt.running = true;
    _cancelled = false;
    _manualCancel = false;
    rt.reset();
    _runHandledMd5.clear();
    _runSizeCount.clear();
    rt.phase = BackupPhase.running;
    rt.running = true;
    rt.error = '';

    // 前台服务把进程保活，通知栏显示「备份中」+ 进度；失败不影响上传本身。
    await photoBackupNotification.start(
      title: tr('photo.backup.notifyTitle'),
      text: tr('photo.backup.notifyScanning'),
      channelName: tr('photo.backup.notifyChannel'),
    );
    _notificationStarted = true;

    final run = BackupRun(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      trigger: trigger,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _store.saveRun(run);
    if (t.keepScreenOn) await _enableWakeLock();
    notifyListeners();

    var crashed = false;
    try {
      final entries = await _scanAlbums(t);
      // 分母在这一刻定死，之后只增分子 —— 进度条不会再「跑满又倒退」。
      rt.runTotal = entries.length;
      notifyListeners();
      for (var i = 0; i < entries.length; i += _batchSize) {
        if (_cancelled) break;
        final slice = entries.sublist(
          i,
          (i + _batchSize).clamp(0, entries.length),
        );
        await _processBatch(t, run, slice);
      }
    } catch (e) {
      crashed = true;
      if (rt.error.isEmpty) rt.error = e.toString();
    } finally {
      _rescanAll = false;
      _running = false;
      rt.running = false;

      if (_pausedByNetwork) {
        rt.phase = BackupPhase.paused;
        rt.paused = true;
      } else if (_manualCancel) {
        rt.phase = BackupPhase.idle;
      } else if (crashed || rt.failed > 0) {
        rt.phase = BackupPhase.error;
      } else {
        rt.phase = BackupPhase.done;
        _lastFinishedAtMs = DateTime.now().millisecondsSinceEpoch;
        _lastUploaded = rt.uploaded;
      }

      final finished = run.finish(
        finishedAtMs: DateTime.now().millisecondsSinceEpoch,
        successCount: rt.uploaded,
        failedCount: rt.failed,
        skippedCount: rt.skipped,
        totalBytes: rt.doneBytes,
      );
      await _store.saveRun(finished);
      try {
        await _client.photoBackupCommit(
          body: PhotoBackupCommitBody(
            source: 'mobile',
            total: rt.uploaded + rt.skipped + rt.failed,
            uploaded: rt.uploaded,
            skipped: rt.skipped,
            bytes: rt.doneBytes,
          ),
        );
      } catch (_) {
        // 断网 / 权限变化时忽略
      }
      _disableWakeLock();

      // 状态落盘：退出页面 / 进程重启也不丢「上次跑到哪」。
      final snapshot = _snapshot();
      PhotoBackupStatus.instance.publish(snapshot);
      await _store.saveStatus(snapshot);
      notifyListeners();

      if (rt.phase == BackupPhase.paused) {
        // 前台服务继续挂着：进程保活，WiFi 回来时 onConnectivityChanged 才收得到。
        _pushNotification(snapshot);
      } else if (rt.phase == BackupPhase.done) {
        await photoBackupNotification.finish(
          title: tr('photo.backup.notifyTitle'),
          text: tr('photo.backup.notifyDone', <String, Object>{
            'count': '${rt.uploaded}',
          }),
        );
      } else {
        await photoBackupNotification.stop();
      }
    }
  }

  Future<List<_Entry>> _scanAlbums(BackupTask t) async {
    final handled = await _store.loadHandled();
    final paths = await pm.PhotoManager.getAssetPathList(
      type: pm.RequestType.common,
      hasAll: true,
    );
    if (paths.isEmpty) return const <_Entry>[];

    final List<pm.AssetPathEntity> selected;
    if (t.sourceIds.isEmpty) {
      final all = paths.where((p) => p.isAll).toList();
      selected = all.isNotEmpty ? <pm.AssetPathEntity>[all.first] : <pm.AssetPathEntity>[paths.first];
    } else {
      selected = paths.where((p) => t.sourceIds.contains(p.id)).toList();
    }

    final out = <_Entry>[];
    final seen = <String>{};
    for (final path in selected) {
      for (var page = 0; !_cancelled; page += 1) {
        final list = await path.getAssetListPaged(page: page, size: _pageSize);
        if (list.isEmpty) break;
        for (final asset in list) {
          // 「最近删除」里的照片不该再备份：Android 11+ 插件默认排除，
          // 但 iOS 的过滤在插件里被注释掉了、Android 10- 没有 IS_TRASHED 列，
          // 厂商相册的回收站也是私有实现 —— 这里显式挡最后一道。
          if (asset.isTrashed) continue;
          if (t.onlyPhotos && asset.type != pm.AssetType.image) continue;
          final id = asset.id;
          if (!seen.add(id)) continue;
          rt.checked += 1;
          final liveId = '$id#live';
          final liveWanted = t.uploadLivePhotoVideo &&
              asset.type == pm.AssetType.image;
          final imageDone = !_rescanAll && handled.contains(id);
          final liveDone = !liveWanted || handled.contains(liveId);
          if (imageDone && liveDone) {
            // 已备份过的只计「累计已备份」，不进本轮的 uploaded/skipped，
            // 否则分子会大于分母、进度条直接爆表。
            rt.alreadyBackedUp += 1;
            continue;
          }
          final name = (asset.title ?? '').isNotEmpty
              ? asset.title!
              : '${asset.id}.jpg';
          final createMs = asset.createDateTime.millisecondsSinceEpoch;
          if (!imageDone) {
            out.add(_Entry(
              id: id,
              asset: asset,
              displayName: name,
              albumName: path.name,
              createMs: createMs,
              isLiveVideo: false,
            ));
          }
          if (liveWanted && !liveDone) {
            out.add(_Entry(
              id: liveId,
              asset: asset,
              displayName: _pairedVideoName(name),
              albumName: path.name,
              createMs: createMs,
              isLiveVideo: true,
            ));
          }
        }
        notifyListeners();
        if (list.length < _pageSize) break;
        // 不再「整页都已处理就停止翻页」：相册返回顺序并不保证最新在前，
        // 早停会漏掉后来插入 / 从别的设备同步进来的老照片。
        // handled 命中项本来就是零 I/O 跳过，全量翻页只多几次枚举 id。
      }
    }
    return out;
  }

  Future<void> _processBatch(
    BackupTask t,
    BackupRun run,
    List<_Entry> slice,
  ) async {
    final poolSize = t.savingMode ? 1 : _concurrency;

    // 1) 先物化（取原文件 + 过滤「假实况视频」）
    final materialized = await _pool<_Materialized?, _Entry>(
      slice,
      (e) => _materialize(e),
      concurrency: poolSize,
    );
    final items = materialized.whereType<_Materialized>().toList();
    // 取不到原文件（已删 / 云端未下载）的也算处理完，否则进度永远到不了 100%。
    rt.omitted += slice.length - items.length;
    if (items.isEmpty) {
      notifyListeners();
      return;
    }
    for (final e in items) {
      _runSizeCount[e.size] = (_runSizeCount[e.size] ?? 0) + 1;
    }

    // 2) size 预检（不带 md5）：absent = 该用户全部相册源里连「同 size 候选」
    //    都没有 ⇒ 内容不可能已存在，直接上传，**跳过本地 MD5**。
    final pre = await _checkContent(<PhotoBackupCheckContentItem>[
      for (final e in items) PhotoBackupCheckContentItem(size: e.size),
    ]);
    final absent = pre == null ? <int>{} : pre.absent.toSet();
    final needMd5 = <_Materialized>[];
    for (final e in items) {
      final dupInRun = e.size > 0 && (_runSizeCount[e.size] ?? 0) > 1;
      final maybeOnServer = pre == null || !absent.contains(e.size);
      if (dupInRun || maybeOnServer) needMd5.add(e);
    }

    // 3) 按需算 MD5（进程内缓存 → 落盘缓存 → 实算）
    final md5s = await _pool<String, _Materialized>(
      needMd5,
      (e) => _safeMd5(e.file, e.cacheKey),
      concurrency: poolSize,
    );
    final md5Map = <String, String>{
      for (var i = 0; i < needMd5.length; i += 1)
        needMd5[i].id: md5s[i].toLowerCase(),
    };

    // 4) 批内 / 跨批内容去重：内容相同的只处理第一次
    final candidates = <_Materialized>[];
    for (final e in items) {
      final md5 = md5Map[e.id] ?? '';
      if (md5.isNotEmpty && !_runHandledMd5.add(md5)) {
        await _record(run, e, BackupFileStatus.skipped, '');
        continue;
      }
      candidates.add(e);
    }
    if (candidates.isEmpty) return;

    // 5) 二轮内容比对：只问带了 md5 的条目，服务端返回确实存在的原始 md5。
    final withMd5 = candidates
        .where((e) => (md5Map[e.id] ?? '').isNotEmpty)
        .toList(growable: false);
    PhotoBackupCheckContentResponse? second;
    if (withMd5.isNotEmpty) {
      second = await _checkContent(<PhotoBackupCheckContentItem>[
        for (final e in withMd5)
          PhotoBackupCheckContentItem(size: e.size, md5: md5Map[e.id]),
      ]);
    }
    final remoteOk = second != null;
    final matched = second == null
        ? <String>{}
        : second.matched.map((m) => m.toLowerCase()).toSet();

    final toUpload = <_Materialized>[];
    for (final e in candidates) {
      final md5 = md5Map[e.id] ?? '';
      if (remoteOk && md5.isNotEmpty && matched.contains(md5)) {
        await _record(run, e, BackupFileStatus.skipped, '');
        continue;
      }
      // 内容索引接口不可用时的降级：按目标路径问「同名同大小文件是否已在 NAS」。
      if (!remoteOk && md5.isNotEmpty && await _targetAlreadyExists(t, e)) {
        await _record(run, e, BackupFileStatus.skipped, '');
        continue;
      }
      toUpload.add(e);
    }
    if (toUpload.isEmpty) return;

    // 6) 断点续传 + 并发上传，单文件 3 次重试
    rt.totalBytes += toUpload.fold<int>(0, (s, e) => s + e.size);
    await _forEachPool(
      toUpload,
      (e) async {
        if (_cancelled) return;
        rt.currentFile = e.displayName;
        notifyListeners();
        final target = _targetPath(t, e);
        try {
          await _withRetry(() => _uploadOne(e.file, target, e.size));
          rt.doneBytes += e.size;
          await _record(run, e, BackupFileStatus.success, '');
        } catch (err) {
          await _record(run, e, BackupFileStatus.error, err.toString());
        }
      },
      concurrency: poolSize,
    );
  }

  /// 内容去重接口；`null` = 接口不可用（老服务端 / 网络失败），调用方走降级路径。
  Future<PhotoBackupCheckContentResponse?> _checkContent(
    List<PhotoBackupCheckContentItem> items,
  ) async {
    if (items.isEmpty) return null;
    try {
      return await _client.photoBackupCheckContent(
        body: PhotoBackupCheckContentBody(items: items),
      );
    } catch (_) {
      return null;
    }
  }

  /// 降级判定：目标路径下同名文件已存在且大小一致 ⇒ 服务端已有这份，跳过。
  Future<bool> _targetAlreadyExists(BackupTask t, _Materialized e) async {
    try {
      final res = await _client.filesCheck(
        body: FilesCheckBody(path: _targetPath(t, e), size: e.size),
      );
      return res.exists;
    } catch (_) {
      return false;
    }
  }

  Future<String> _safeMd5(File file, String cacheKey) async {
    try {
      final cached = await _store.loadHash(cacheKey);
      if (cached != null && cached.isNotEmpty) return cached;
      final value = await _md5Of(file, cacheKey);
      await _store.saveHash(cacheKey, value);
      return value;
    } catch (_) {
      return '';
    }
  }

  Future<_Materialized?> _materialize(_Entry e) async {
    try {
      final file = e.isLiveVideo
          ? await e.asset.originFileWithSubtype
          : await e.asset.originFile;
      if (file == null) return null;
      // Android 上没有动图的普通 JPEG，originFileWithSubtype 会原样返回图片本身，
      // 传上去就多一份字节完全相同的假 .MOV。按文件头剔除。
      if (e.isLiveVideo && await _looksLikeImage(file)) return null;
      final size = await file.length();
      if (size <= 0) return null;
      if (e.isLiveVideo && size < _minLiveVideoBytes) return null;
      final stat = await file.stat();
      return _Materialized(
        id: e.id,
        displayName: e.displayName,
        albumName: e.albumName,
        createMs: e.createMs,
        isLiveVideo: e.isLiveVideo,
        file: file,
        size: size,
        cacheKey: '${e.id}|$size|${stat.modified.millisecondsSinceEpoch}',
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> _md5Of(File file, String cacheKey) async {
    final cached = _md5Cache[cacheKey];
    if (cached != null) return cached;
    final digest = await crypto.md5.bind(file.openRead()).first;
    final value = digest.toString();
    if (_md5Cache.length > 20000) _md5Cache.clear();
    _md5Cache[cacheKey] = value;
    return value;
  }

  Future<void> _record(
    BackupRun run,
    _Materialized e,
    BackupFileStatus status,
    String error,
  ) async {
    switch (status) {
      case BackupFileStatus.success:
        rt.uploaded += 1;
        break;
      case BackupFileStatus.skipped:
        rt.skipped += 1;
        break;
      case BackupFileStatus.error:
        rt.failed += 1;
        break;
    }
    await _store.markHandled(e.id, status);
    await _store.appendFileRecord(BackupFileRecord(
      runId: run.id,
      sourceUniqueId: e.id,
      displayName: e.displayName,
      size: e.size,
      status: status,
      atMs: DateTime.now().millisecondsSinceEpoch,
      error: error,
    ));
    notifyListeners();
  }

  String _targetPath(BackupTask t, _Materialized e) {
    final name = t.renameByDate
        ? _renamedByDate(e.displayName, e.createMs)
        : e.displayName;
    final date = DateTime.fromMillisecondsSinceEpoch(e.createMs);
    final yyyy = date.year.toString().padLeft(4, '0');
    final mm = date.month.toString().padLeft(2, '0');
    final sub = switch (t.dirStyle) {
      BackupDirStyle.byAlbum => _safeSegment(e.albumName),
      BackupDirStyle.byYear => yyyy,
      BackupDirStyle.byMonth => '$yyyy/$mm',
    };
    // 统一收在 `MobilePhoto/<机型>` 下。
    final root = effectiveTargetDir.replaceAll(RegExp(r'/$'), '');
    final device = _safeSegment(t.deviceName).trim();
    final base =
        device.isEmpty ? '$root/MobilePhoto' : '$root/MobilePhoto/$device';
    return '$base/$sub/$name';
  }

  String _safeSegment(String raw) {
    final s = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return s.isEmpty ? '全部' : s;
  }

  String _renamedByDate(String name, int createMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(createMs);
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${d.year}${two(d.month)}${two(d.day)}_'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}';
    final ext = _extensionOf(name);
    return 'IMG_$stamp$ext';
  }

  String _extensionOf(String name) {
    final i = name.lastIndexOf('.');
    return i > 0 ? name.substring(i) : '.jpg';
  }

  /// 实况视频必须与主图同名，服务端才能按 basename 配对。
  String _pairedVideoName(String imageName) {
    final i = imageName.lastIndexOf('.');
    final stem = i > 0 ? imageName.substring(0, i) : imageName;
    return '$stem.mov';
  }

  Future<void> _uploadOne(File file, String target, int size) async {
    final check = await _client.filesCheck(
      body: FilesCheckBody(path: target, size: size),
    );
    if (check.exists) return;
    final chunkSize = check.chunkSize <= 0 ? 4 * 1024 * 1024 : check.chunkSize;
    final total = (size / chunkSize).ceil().clamp(1, 1 << 20);
    final already = check.uploaded.toSet();
    final handle = await file.open();
    try {
      for (var index = 0; index < total; index += 1) {
        if (_cancelled) return;
        if (already.contains(index)) continue;
        await handle.setPosition(index * chunkSize);
        final bytes = await handle.read(chunkSize);
        if (bytes.isEmpty) break;
        await _client.filesChunk(
          path: target,
          index: index,
          total: total,
          body: bytes,
        );
      }
    } finally {
      await handle.close();
    }
    if (_cancelled) return;
    await _client.filesMerge(
      body: FilesMergeBody(path: target, total: total, size: size),
    );
  }

  Future<void> _withRetry(Future<void> Function() fn) async {
    var attempt = 0;
    while (true) {
      try {
        await fn();
        return;
      } catch (e) {
        attempt += 1;
        if (attempt >= _maxAttempts || _cancelled) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  /// 只跑副作用、不需要收集结果的并发池（上传用）。
  Future<void> _forEachPool<E>(
    List<E> items,
    Future<void> Function(E item) work, {
    int concurrency = _concurrency,
  }) async {
    if (items.isEmpty) return;
    var cursor = 0;
    await Future.wait(
      List<Future<void>>.generate(
        concurrency.clamp(1, items.length),
        (_) async {
          while (true) {
            if (_cancelled) return;
            final i = cursor;
            if (i >= items.length) return;
            cursor += 1;
            await work(items[i]);
          }
        },
      ),
    );
  }

  Future<List<T>> _pool<T, E>(
    List<E> items,
    Future<T> Function(E item) work, {
    int concurrency = _concurrency,
  }) async {
    if (items.isEmpty) return <T>[];
    final out = List<T?>.filled(items.length, null);
    var cursor = 0;
    final workers = List<Future<void>>.generate(
      concurrency.clamp(1, items.length),
      (_) async {
        while (true) {
          if (_cancelled) return;
          final i = cursor;
          if (i >= items.length) return;
          cursor += 1;
          out[i] = await work(items[i]);
        }
      },
    );
    await Future.wait(workers);
    return out.whereType<T>().toList();
  }

  Future<void> _enableWakeLock() async {
    if (_wakeLockHeld || kIsWeb) return;
    try {
      await WakelockPlus.enable();
      _wakeLockHeld = true;
    } catch (_) {
      // 平台不支持时忽略
    }
  }

  void _disableWakeLock() {
    if (!_wakeLockHeld) return;
    _wakeLockHeld = false;
    try {
      unawaited(WakelockPlus.disable());
    } catch (_) {
      // 同上
    }
  }

  static Future<bool> _looksLikeImage(File file) async {
    try {
      final raf = await file.open();
      late final List<int> head;
      try {
        head = await raf.read(12);
      } finally {
        await raf.close();
      }
      bool starts(List<int> magic) {
        if (head.length < magic.length) return false;
        for (var i = 0; i < magic.length; i += 1) {
          if (head[i] != magic[i]) return false;
        }
        return true;
      }

      return starts(<int>[0xFF, 0xD8, 0xFF]) ||
          starts(<int>[0x89, 0x50, 0x4E, 0x47]) ||
          starts(<int>[0x47, 0x49, 0x46, 0x38]) ||
          starts(<int>[0x42, 0x4D]);
    } catch (_) {
      return false;
    }
  }
}

class _Entry {
  const _Entry({
    required this.id,
    required this.asset,
    required this.displayName,
    required this.albumName,
    required this.createMs,
    required this.isLiveVideo,
  });

  final String id;
  final pm.AssetEntity asset;
  final String displayName;
  final String albumName;
  final int createMs;
  final bool isLiveVideo;
}

class _Materialized {
  const _Materialized({
    required this.id,
    required this.displayName,
    required this.albumName,
    required this.createMs,
    required this.isLiveVideo,
    required this.file,
    required this.size,
    required this.cacheKey,
  });

  final String id;
  final String displayName;
  final String albumName;
  final int createMs;
  final bool isLiveVideo;
  final File file;
  final int size;
  final String cacheKey;
}
