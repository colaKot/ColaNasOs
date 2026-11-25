import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../core/app_navigator.dart';
import '../core/app_settings.dart';
import '../core/audio_background.dart';
import '../core/client_log.dart';
import '../core/i18n_setup.dart';
import '../core/launch_mode.dart';
import '../core/perf_diagnostics.dart';
import '../core/session.dart';
import '../core/settings_store.dart';
import '../core/tv_mode.dart';
import '../core/video_render.dart';
import '../features/login/login_page.dart';
import '../features/music/music_page.dart';
import '../features/photo/backup/photo_backup_bootstrap.dart';
import '../features/photo/photo_shell.dart';
import '../features/sync/sync_page.dart';
import '../features/sync/sync_engine.dart';
import '../features/sync/sync_scheduler.dart';
import '../features/sync/sync_tray_bridge.dart';
import '../features/tv/tv_shell.dart';
import '../features/update/update_dialog.dart';
import '../features/update/update_service.dart';
import 'app_shell.dart';
import 'desktop_tray.dart';

export '../core/launch_mode.dart' show AppLaunchMode;

/// 客户端机器标识：PC 端与同步任务共用 SyncFs 的稳定设备 id；
/// 移动端 / 普通 Web 使用本地持久化的随机 id。
///
/// 同步任务按「用户 + 机器」隔离，这个 id 决定看得到哪一组任务；
/// 独立同步客户端与主客户端共用这份代码，因而在同一台机器上得到同一个值。
Future<void> _ensureClientId() async {
  final syncFs = SyncEngine.instance.fs;
  final isNativeDesktop =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);
  // PC Electron 也是 Web runtime；只有注入了本地文件桥才将它视为桌面端。
  if (isNativeDesktop || (kIsWeb && syncFs.canSync)) {
    try {
      final deviceId = await syncFs.resolveDeviceId();
      if (deviceId.isNotEmpty) {
        // 任务归属和请求隔离使用同一份机器 ID；避免 Web/Electron 的随机设置 ID
        // 与任务里的 deviceId 分裂，造成同机客户端看不到任务或机器间误共享。
        ColanasClientId.override = deviceId;
        return;
      }
    } catch (e) {
      debugPrint('[sync] resolve client identity failed: $e');
    }
  }
  // 移动端 / 普通浏览器没有稳定的桌面设备 ID，继续使用本地持久化随机标识。
  if (ColanasClientId.value.isNotEmpty) return;
  final saved = SettingsStore.instance.getString('client.id');
  if (saved != null && saved.isNotEmpty) {
    ColanasClientId.override = saved;
    return;
  }
  final rand = Random();
  final id =
      'app:${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${rand.nextInt(1 << 30).toRadixString(36)}';
  await SettingsStore.instance.setString('client.id', id);
  ColanasClientId.override = id;
}

/// 统一入口：初始化设置、恢复会话、初始化播放内核，然后启动应用
///
/// [tvEntry] 为 TV 专用入口（`main_tv.dart`）：强制 TV 模式 + 深色外观，
/// 首页直接进 [TvShell]。普通入口不传，行为与以前完全一致。
Future<void> runColanasApp({
  AppLaunchMode mode = AppLaunchMode.full,
  bool tvEntry = false,
}) async {
  currentLaunchMode = mode;
  WidgetsFlutterBinding.ensureInitialized();
  // 启动阶段耗时：用户反馈「打开就卡、完全点不了」时，先要分清是启动阶段
  // 卡在磁盘/网络（设置、会话恢复）还是渲染。这里只记几个时间点，结束后
  // 打一行日志；诊断开关打开时会带进上报里。
  final boot = Stopwatch()..start();
  final bootMarks = <String, int>{};
  void mark(String name) => bootMarks[name] = boot.elapsedMilliseconds;

  // 先加载设置与会话：避免启动时先用默认主题闪一下、再跳到用户主题
  await AppSettings.instance.load();
  mark('settings');
  if (tvEntry) {
    // 包身份：这是 TV 包，更新时只能拿 TV 安装包（不依赖 dart-define 是否写对）
    tvPackage = true;
    // TV 版面按深色 10-foot UI 设计；这里只改本次运行的缓存值，不写回用户设置。
    AppSettings.instance.tvMode.value = true;
    AppSettings.instance.themeMode.value = ThemeMode.dark;
  }
  await _ensureClientId();
  await initI18n();
  mark('i18n');
  /**
   * 登录成功即检查客户端更新（方案 §8.1）：与首页数据并行发出，不阻塞进主页。
   *
   * 客户端是「打开才用」的，所以只在这一刻查一次 —— 不做后台定时轮询。
   * 6 小时节流写在 `UpdateService.checkOnLogin` 里（同一设备重复登录不重复查）。
   */
  ApiSession.instance.authState.addListener(() {
    if (ApiSession.instance.authState.value) {
      unawaited(UpdateService.instance.checkOnLogin());
    }
  });
  await ApiSession.instance.restore();
  if (ApiSession.instance.authState.value) {
    // 自动登录已经在 restore 里完成：监听器加得比它晚，这里补一次
    unawaited(UpdateService.instance.checkOnLogin());
  }
  mark('session');
  // 前端异常也进服务端日志：日志页只有一份，排查时不用两头找。
  // 传端标识，dev 批量日志里能区分是完整端还是相册/音乐/同步端。
  ClientLogger.instance.install(app: mode.name);
  // 帧耗时 / 接口耗时 / 设备信息：默认关闭，设置页可开；关闭时只保留一行 60s 摘要
  PerfDiagnostics.instance.install(app: mode.name);
  PerfDiagnostics.instance.setBootMarks(bootMarks);
  MediaKit.ensureInitialized();
  // Android 前台服务：熄屏 / 切后台继续播，通知栏与锁屏才有控制。
  // Web 走浏览器自己的 Media Session、桌面窗口常驻，两端都是空实现。
  // 失败只打日志（内部已 catch），不能把启动挡在这里。
  await audioBackground.ensureStarted(
    channelName: I18n.instance.tr('audio.channelName'),
  );
  // 桌面端托盘：关窗缩到托盘常驻；初始化失败自动降级为普通关闭
  await desktopTray.init();
  mark('services');
  // 托盘的同步操作登录前就挂上；动作本身在未登录时会自己空转。
  unawaited(
    syncTrayBridge.install(
      SyncTrayHandlers(
        onSyncNow: () => SyncScheduler.instance.runAllNow(),
        onOpenTasks: () async => AppShell.openApp('sync'),
      ),
    ),
  );
  // 装好就把本机任务数报给托盘，「立即同步」据此置灰。
  // 未登录时 `localTaskCount` 返回 0，菜单里「立即同步」是灰的 —— 符合实际。
  unawaited(syncTrayBridge.refresh());
  runApp(ColaNasApp(launchMode: mode, tvEntry: tvEntry));
  if (mode == AppLaunchMode.full || mode == AppLaunchMode.sync) {
    // 每任务间隔是唯一的定时配置；客户端启动后立即检查到期任务。
    SyncScheduler.instance.start();
  }
  // 首帧出来后再补一个时间点：启动阶段到底是卡在磁盘 / 网络 / 首帧渲染，
  // 这一行日志就能分开（帧耗时单独由 PerfDiagnostics 每 60s 打一次）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    mark('firstFrame');
    ClientLogger.instance.info(
      '启动 ${boot.elapsedMilliseconds}ms '
      '${bootMarks.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
      route: 'perf.boot',
    );
  });
  // 相册备份开关是整机状态：必须在 App 启动时就把控制器挂到进程上。
  // 挂在页面里的话，用户切出备份页 / 最小化时 State.dispose 会把网络监听
  // 一起取消，后台上传和通知栏进度全断（2026-11-07 反馈）。
  // 独立端里只有完整客户端与相册端需要它。
  if (mode == AppLaunchMode.full || mode == AppLaunchMode.photo) {
    unawaited(startPhotoBackupService());
  }
}

class ColaNasApp extends StatelessWidget {
  const ColaNasApp({
    super.key,
    this.launchMode = AppLaunchMode.full,
    this.tvEntry = false,
  });

  final AppLaunchMode launchMode;
  final bool tvEntry;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([settings.listenable, i18nRevision]),
      builder: (context, _) {
        // 流畅模式：NasPanel 读这个静态开关决定是否创建 BackdropFilter。
        // 必须在 builder 里赋值（设置一变就在这里重建），外层 build 不会因为
        // settings.listenable 变化而重跑。
        NasEffects.reduceBlur = settings.reduceBlur.value;
        return MaterialApp(
          // 全局 Navigator key：无 context 的 GetX controller 靠它弹对话框
          // （`Get.context` 在 MaterialApp 下恒为 null，见 core/app_navigator.dart）
          navigatorKey: kAppNavigatorKey,
          title: switch (launchMode) {
            AppLaunchMode.full => 'ColaNasOs 客户端',
            AppLaunchMode.photo => tr('ui.shell.h2aea9e'),
            AppLaunchMode.music => tr('ui.shell.h8d6e63'),
            AppLaunchMode.sync => tr('ui.shell.hsync'),
          },
          debugShowCheckedModeBanner: false,
          theme: NasTheme.styled(
            styleId: settings.styleId.value,
            schemeId: settings.schemeId.value,
            skinId: settings.skinId.value,
            fontFamily: nasFontFamily(settings.fontId.value),
            brightness: Brightness.light,
          ),
          darkTheme: NasTheme.styled(
            styleId: settings.styleId.value,
            schemeId: settings.schemeId.value,
            skinId: settings.skinId.value,
            fontFamily: nasFontFamily(settings.fontId.value),
            brightness: Brightness.dark,
          ),
          themeMode: settings.themeMode.value,
          // 背景层铺在 MaterialApp 之下、页面之上：Scaffold 透明，切换风格即刻生效
          builder: (context, child) {
            final spec = NasStyles.spec(
              NasStyles.parse(settings.styleId.value),
              Theme.of(context).brightness,
              Theme.of(context).colorScheme,
            );
            final tv = settings.tvMode.value;
            // TV 模式：整体放大字号（10-foot UI），并把遥控器确认键补进快捷键表
            final media = MediaQuery.of(context);
            return NasStyleScope(
              spec: spec,
              child: TvScope(
                enabled: tv,
                child: Shortcuts(
                  shortcuts: tv
                      ? kTvShortcuts
                      : const <ShortcutActivator, Intent>{},
                  child: MediaQuery(
                    data: tv
                        ? media.copyWith(
                            textScaler: const TextScaler.linear(kTvTextScale),
                          )
                        : media,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 背景（极光风格是 3 层全屏径向渐变）必须独立成一个图层。
                        //
                        // 不放 RepaintBoundary 时，页面里任何一次重绘（滚动、悬停、
                        // 图片渐显）都会把背景一起重新光栅化：2.5K 窗口下 3 层全屏
                        // 渐变约 20ms/帧，直接吃满 60Hz 预算的一半以上。实测（AMD
                        // 780M，2560×1369）：裸动画 UI raster 0.9ms → 加这 3 层渐变
                        // 后 20.4ms；页面滚动时再叠加内容后达到 40~60ms（约 16fps）。
                        // 独立图层后背景只在尺寸/主题变化时重绘一次，滚动只重绘内容。
                        //
                        // 原生视频播放时这一层必须让路：它画在 Navigator 下面，
                        // 不收起会把 Activity 底层的视频整个盖住（透明洞失效）。
                        ValueListenableBuilder<bool>(
                          valueListenable: nativeVideoLayerActive,
                          builder: (context, nativeVideo, _) => nativeVideo
                              ? const SizedBox.shrink()
                              : RepaintBoundary(child: spec.background),
                        ),
                        // 页面内容同样独立：内容重绘不再带动背景，反过来主题切换
                        // 重绘背景也不会带着整棵树。
                        RepaintBoundary(
                          child: child ?? const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
          home: UpdatePromptHost(
            child: ValueListenableBuilder<bool>(
              valueListenable: ApiSession.instance.autoLoginChecking,
              builder: (context, checking, _) {
                if (checking) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                return ValueListenableBuilder<bool>(
                  valueListenable: ApiSession.instance.authState,
                  builder: (context, authed, _) {
                    if (!authed) return const LoginPage();
                    if (tvEntry) return const TvShell();
                    return switch (launchMode) {
                      AppLaunchMode.full => const AppShell(),
                      // 相册独立端也走相册模块外壳：登录后只有相册各页，
                      // 没有「回工作台」的房子（见 PhotoShellPage）。
                      AppLaunchMode.photo => const PhotoShellPage(),
                      AppLaunchMode.music => const MusicPage(),
                      AppLaunchMode.sync => const SyncPage(),
                    };
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}
