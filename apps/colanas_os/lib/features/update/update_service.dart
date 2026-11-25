import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_version.dart';
import '../../core/launch_mode.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../../core/tv_mode.dart';
import 'update_install.dart';

/// 客户端自动更新（PC / 安卓 / TV / Web 共用一套状态机）。
///
/// 三端行为（方案 §8、§13.3）：
///   - **登录成功时检查一次**，同一设备 6 小时内不重复查；
///   - 只亮提示，不打断：红点 + 一个可关闭的对话框，用户点了才下载；
///   - 下载 → 校验 sha256 → 拉起安装器/系统安装器；失败只影响「这次没更新」。
///
/// 服务端更新走同一份清单（`system/update/check?component=server`），
/// 由设置页里的「服务端更新」区块负责，与客户端更新互不阻塞。
enum UpdatePhase { idle, checking, available, downloading, verifying, installing, done, failed }

/// 安卓要装哪一份包：`apk_tv` / `apk_photo` / `apk`。
///
/// 三份包身份不同，绝不能互相代替（见 `ClientUpdate.assetFor`）：
/// TV 与主客户端手机包是同一个 applicationId，相册端是另一个 applicationId。
/// 判断依据是**启动入口**（`tv_mode.dart` / `launch_mode.dart`），
/// 不是可以随手切换的界面设置。
String get clientApkKind {
  if (isTvPackage) return 'apk_tv';
  if (currentLaunchMode == AppLaunchMode.photo) return 'apk_photo';
  return 'apk';
}

class UpdateAsset {
  const UpdateAsset({
    required this.kind,
    required this.size,
    required this.sha256,
    required this.urls,
  });

  final String kind;
  final int size;
  final String sha256;
  final List<String> urls;

  static UpdateAsset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final urls = (raw['urls'] as List?)?.map((e) => '$e').where((e) => e.isNotEmpty).toList() ?? const <String>[];
    if (urls.isEmpty) return null;
    return UpdateAsset(
      kind: '${raw['kind'] ?? ''}',
      size: (raw['size'] as num?)?.toInt() ?? 0,
      sha256: '${raw['sha256'] ?? ''}',
      urls: urls,
    );
  }
}

class ClientUpdate {
  const ClientUpdate({
    required this.hasUpdate,
    required this.latestSemver,
    required this.latestVersionCode,
    required this.notes,
    required this.assets,
  });

  final bool hasUpdate;
  final String latestSemver;
  final int latestVersionCode;
  final String notes;
  final List<UpdateAsset> assets;

  /// 按平台挑要装的资产：PC 只认 setup（便携版走 zip，不在这里自替换）
  ///
  /// 安卓按**包身份**分三份，绝不能互通：
  ///   - TV 包 → `apk_tv`（与手机包同一个 applicationId，装错就是把电视端换成手机 UI）
  ///   - 相册独立端 → `apk_photo`（另一个 applicationId，装错就是凭空多出一个主客户端）
  ///   - 主客户端手机包 → `apk`
  ///
  /// 包身份由入口决定（见 `tv_mode.dart` / `launch_mode.dart`），不依赖
  /// `--dart-define` 写没写对。拿不到与自己匹配的资产时返回 null，
  /// 界面显示「没有适用于本端的安装包」。
  UpdateAsset? assetFor(String platform) => assetForPlatform(platform, assets);
}

/// 按平台从资产清单里挑出「本端能装的那一份」。
///
/// 与 [ClientUpdate.assetFor] 是同一套规则，抽成函数是因为「检查更新」阶段
/// 就要先判断有没有本端的包：相册独立端 / TV 包身份不同，正式发版经常只发
/// 主客户端手机包，那时不能只凭服务端的 `hasUpdate` 就亮红点。
UpdateAsset? assetForPlatform(String platform, List<UpdateAsset> assets) {
  if (platform == 'client_android') {
    final want = clientApkKind;
    for (final a in assets) {
      if (a.kind == want) return a;
    }
    return null;
  }
  // PC 只认安装版：便携版是 zip，没法「自己替换自己」，硬跑只会把 zip 当 exe 启动
  for (final a in assets) {
    if (a.kind == 'setup') return a;
  }
  return null;
}

class UpdateStatus {
  const UpdateStatus({
    this.phase = UpdatePhase.idle,
    this.progress = 0,
    this.loaded = 0,
    this.total = 0,
    this.speed = 0,
    this.message = '',
    this.error = '',
  });

  final UpdatePhase phase;

  /// 0~1；总量未知时为 0（界面显示「已下载 X MB」而不是假进度条）
  final double progress;
  final int loaded;
  final int total;
  final int speed;
  final String message;
  final String error;

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.verifying ||
      phase == UpdatePhase.installing;

  UpdateStatus copyWith({
    UpdatePhase? phase,
    double? progress,
    int? loaded,
    int? total,
    int? speed,
    String? message,
    String? error,
  }) {
    return UpdateStatus(
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      loaded: loaded ?? this.loaded,
      total: total ?? this.total,
      speed: speed ?? this.speed,
      message: message ?? this.message,
      error: error ?? this.error,
    );
  }
}

class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// 当前任务状态（设置页进度条 / 全局提示都听它）
  final ValueNotifier<UpdateStatus> status = ValueNotifier(const UpdateStatus());

  /// 发现的新客户端版本；null = 没有更新（或还没检查）
  final ValueNotifier<ClientUpdate?> available = ValueNotifier(null);

  /// 服务端更新（只在设置页展示，不弹窗）
  final ValueNotifier<SystemUpdateCheckResponse?> serverCheck = ValueNotifier(null);

  /// 本次会话是否已弹过提示（用户点「稍后」后不再重复弹）
  bool _prompted = false;
  bool get prompted => _prompted;

  bool _checking = false;

  /// 用户点了「取消」。
  ///
  /// 下载器抛出的错误会在 `startInstall` 的 catch 里被当成「失败」显示出来，
  /// 而用户刚刚明明是自己取消的 —— 只有这个标记能把两者分开。
  bool _cancelRequested = false;

  /// 安装器按平台条件导入（Web 端是空实现）
  final UpdateInstaller _installer = createUpdateInstaller();

  static const int _checkIntervalMs = 6 * 60 * 60 * 1000;

  bool get isWeb => kIsWeb;

  /// 是否该弹「发现新版本」：有新版本 && 本次会话没弹过 && 用户没点过「稍后」
  ///
  /// 与 `available.hasUpdate` 分开：点了「稍后」只是不再弹窗，红点仍然保留。
  bool get shouldPrompt {
    final info = available.value;
    if (info == null || !info.hasUpdate) return false;
    if (_prompted) return false;
    return SettingsStore.instance.getString('update.skipVersion') != info.latestSemver;
  }

  /// 当前平台对应的清单组件
  String get component {
    if (kIsWeb) return 'server';
    if (defaultTargetPlatform == TargetPlatform.android) return 'client_android';
    return 'client_pc';
  }

  bool get supportsClientUpdate => !kIsWeb;

  /// 登录成功后调用：6 小时内不重复查，失败静默（更新检查不该干扰登录）
  Future<void> checkOnLogin() async {
    final last = SettingsStore.instance.getInt('update.lastCheckAt') ?? 0;
    // 6 小时内查过就用上次结果：客户端是「打开才用」的，不需要定时轮询
    if (DateTime.now().millisecondsSinceEpoch - last < _checkIntervalMs) {
      final skipped = SettingsStore.instance.getString('update.skipVersion');
      final latest = SettingsStore.instance.getString('update.latestSemver');
      if (latest != null && latest.isNotEmpty && skipped != latest) {
        // 上次已经发现新版本：至少把红点保留下来（详情等用户点「检查更新」再取）
        status.value = const UpdateStatus(phase: UpdatePhase.available);
      }
      return;
    }
    await check();
  }

  /// 检查更新。`force` 忽略 6 小时节流（设置页「检查更新」用）。
  Future<void> check({bool force = false}) async {
    if (_checking) return;
    _checking = true;
    status.value = status.value.copyWith(
      phase: UpdatePhase.checking,
      message: '',
      error: '',
    );
    try {
      // 自报构建形态：服务端据此只给我们这一份包
      // （TV 拿不到手机包，相册端拿不到主客户端包，反之亦然）
      final buildKind = component == 'client_android'
          ? switch (clientApkKind) {
              'apk_tv' => 'tv',
              'apk_photo' => 'photo',
              _ => 'phone',
            }
          : null;
      Future<SystemUpdateCheckResponse> request(String? build) {
        return ApiSession.instance.client.systemUpdateCheck(
          component: component,
          current: kAppVersion,
          currentCode: kAppVersionCode,
          build: build,
          force: force ? '1' : '0',
        );
      }

      SystemUpdateCheckResponse res;
      try {
        res = await request(buildKind);
      } on ApiError catch (e) {
        // 老服务端的 querystring 校验只认 phone/tv，带 photo 会直接 400。
        // 只有这种情况才退回「不带 build」：服务端会把三份包都给出来，
        // 客户端自己按包身份挑（`assetFor` 仍然只认自己那一份），
        // 升级服务端后自动恢复精确过滤。离线 / 超时不重试，避免白等两遍。
        if (buildKind != 'photo' || e.statusCode != 400) rethrow;
        res = await request(null);
      }
      serverCheck.value = res;
      // 服务端把「清单源不可达」也返回 200 + error：不能当成「已是最新」
      if (res.error.isNotEmpty) {
        status.value = UpdateStatus(
          phase: UpdatePhase.failed,
          error: res.error,
        );
        await SettingsStore.instance.setInt(
          'update.lastCheckAt',
          DateTime.now().millisecondsSinceEpoch,
        );
        return;
      }
      await SettingsStore.instance.setInt(
        'update.lastCheckAt',
        DateTime.now().millisecondsSinceEpoch,
      );

      final raw = res.client;
      ClientUpdate? info;
      if (raw != null) {
        final notes = (res.notes['zh'] ??
                res.notes['en'] ??
                (res.notes.isEmpty ? '' : '${res.notes.values.first}'))
            .toString();
        final assets = (raw['assets'] as List? ?? const [])
            .map(UpdateAsset.fromJson)
            .whereType<UpdateAsset>()
            .toList();
        // 只有清单里真有「本端能装的包」才算有更新。
        //
        // 服务端已经按 `build=photo|tv|phone` 过滤，但两端版本对不上时会走到
        // 「不带 build」的兼容老服务端口径：那时服务端按主客户端的版本回
        // `hasUpdate=true`，相册端拿到的却只有 apk / apk_tv —— 于是界面上一直
        // 提示有新版本，点进去却没有可下载的包（用户反馈）。这里按包身份再收一次口。
        final hasOwnAsset = assetForPlatform(component, assets) != null;
        info = ClientUpdate(
          hasUpdate: raw['hasUpdate'] == true && hasOwnAsset,
          latestSemver: '${raw['latestSemver'] ?? ''}',
          latestVersionCode: (raw['latestVersionCode'] as num?)?.toInt() ?? 0,
          notes: notes,
          assets: assets,
        );
      }
      available.value = info;
      if (info != null && info.hasUpdate) {
        await SettingsStore.instance.setString('update.latestSemver', info.latestSemver);
        status.value = const UpdateStatus(phase: UpdatePhase.available);
      } else {
        // 没有「本端可装」的新版本：把上次缓存的新版本号清掉，避免 6 小时内
        // 登录时又凭它亮一个下载不了的更新红点（见 [checkOnLogin]）。
        await SettingsStore.instance.setString('update.latestSemver', '');
        status.value = const UpdateStatus(phase: UpdatePhase.idle);
      }
    } catch (e) {
      // 检查失败不算错误：NAS 可能没网，或者清单源暂时不可达
      status.value = UpdateStatus(
        phase: UpdatePhase.failed,
        error: '$e',
        message: '',
      );
    } finally {
      _checking = false;
    }
  }

  /// 用户点了「稍后」：记住这个版本，本次会话不再弹
  Future<void> dismiss() async {
    _prompted = true;
    final info = available.value;
    if (info != null && info.hasUpdate) {
      // 记住「这个版本已经问过了」：只影响弹窗，桌面红点仍然保留
      await SettingsStore.instance.setString('update.skipVersion', info.latestSemver);
    }
    if (status.value.phase == UpdatePhase.available) {
      status.value = const UpdateStatus(phase: UpdatePhase.idle);
    }
  }

  /// 用户点了「立即更新」：下载 → 校验 → 安装
  Future<void> startInstall() async {
    final info = available.value;
    if (info == null || !info.hasUpdate) return;
    final asset = info.assetFor(component);
    if (asset == null) {
      // 清单里没有本平台能自动安装的包（例如只发了便携版 / 只发了 TV 包）
      status.value = UpdateStatus(phase: UpdatePhase.failed, error: tr('update.noAsset'));
      return;
    }
    // 最后一道闸：安卓上装的包必须与自己这份构建同形态。
    // 宁可这次不更新，也不能把电视端换成手机 UI / 给相册端装上主客户端。
    if (!kIsWeb && component == 'client_android') {
      final want = clientApkKind;
      if (asset.kind != want) {
        status.value = UpdateStatus(
          phase: UpdatePhase.failed,
          error: tr('update.noAsset'),
        );
        return;
      }
    }
    _prompted = true;
    _cancelRequested = false;
    status.value = UpdateStatus(
      phase: UpdatePhase.downloading,
      total: asset.size,
      message: asset.kind,
    );
    try {
      final path = await _installer.download(
        asset: asset,
        onProgress: (loaded, total, speed) {
          final totalBytes = total > 0 ? total : asset.size;
          status.value = status.value.copyWith(
            phase: UpdatePhase.downloading,
            loaded: loaded,
            total: totalBytes,
            speed: speed,
            progress: totalBytes > 0 ? (loaded / totalBytes).clamp(0, 1).toDouble() : 0,
          );
        },
        onVerify: () {
          status.value = status.value.copyWith(phase: UpdatePhase.verifying, progress: 1);
        },
      );
      status.value = status.value.copyWith(phase: UpdatePhase.installing, progress: 1);
      await _installer.install(path: path, asset: asset);
      status.value = const UpdateStatus(phase: UpdatePhase.done);
    } catch (e) {
      // 自己点的取消不算失败：回 idle，别弹一条「更新失败」
      if (_cancelRequested) {
        status.value = const UpdateStatus(phase: UpdatePhase.idle);
        return;
      }
      status.value = UpdateStatus(phase: UpdatePhase.failed, error: '$e');
    }
  }

  /// 下载中途取消（已下片段保留，下次续传）
  void cancel() {
    _cancelRequested = true;
    _installer.cancel();
    if (status.value.busy) {
      status.value = const UpdateStatus(phase: UpdatePhase.idle);
    }
  }

  /// 界面文案用：把字节数变成「3.2 MB」
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i += 1;
    }
    return '${value.toStringAsFixed(value >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  static String formatSpeed(int bytesPerSec) =>
      bytesPerSec <= 0 ? '' : '${formatBytes(bytesPerSec)}/s';
}
