import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../core/app_navigator.dart';
import '../core/app_settings.dart';
import '../core/audio_background.dart';
import '../core/client_log.dart';
import '../core/i18n_setup.dart';
import '../core/session.dart';
import '../core/tv_mode.dart';
import '../features/login/login_page.dart';
import '../features/music/music_page.dart';
import '../features/photo/backup/photo_backup_bootstrap.dart';
import '../features/photo/photo_page.dart';
import '../features/sync/sync_page.dart';
import '../features/sync/sync_scheduler.dart';
import '../features/sync/sync_tray_bridge.dart';
import 'app_shell.dart';
import 'desktop_tray.dart';

/// 启动模式：完整客户端 / 相册独立端 / 音乐独立端 / 同步独立端。
///
/// 独立端**复用主客户端**：`photo_client` / `music_client` / `sync_client`
/// 通过 path 依赖复用本包，入口只有一行 `runColanasApp(mode: ...)`。
/// 改主客户端，各端同步生效。
enum AppLaunchMode { full, photo, music, sync }

/// 统一入口：初始化设置、恢复会话、初始化播放内核，然后启动应用
Future<void> runColanasApp({AppLaunchMode mode = AppLaunchMode.full}) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先加载设置与会话：避免启动时先用默认主题闪一下、再跳到用户主题
  await AppSettings.instance.load();
  await initI18n();
  await ApiSession.instance.restore();
  // 前端异常也进服务端日志：日志页只有一份，排查时不用两头找。
  // 传端标识，dev 批量日志里能区分是完整端还是相册/音乐/同步端。
  ClientLogger.instance.install(app: mode.name);
  MediaKit.ensureInitialized();
  // Android 前台服务：熄屏 / 切后台继续播，通知栏与锁屏才有控制。
  // Web 走浏览器自己的 Media Session、桌面窗口常驻，两端都是空实现。
  // 失败只打日志（内部已 catch），不能把启动挡在这里。
  await audioBackground.ensureStarted(
    channelName: I18n.instance.tr('audio.channelName'),
  );
  // 桌面端托盘：关窗缩到托盘常驻；初始化失败自动降级为普通关闭
  await desktopTray.init();
  // Electron 托盘的同步三项：**登录前就要挂上**，否则「同步任务」点了没反应
  // （页面停在登录页时 AppShell 还没创建）。动作本身在未登录时会自己空转。
  unawaited(
    syncTrayBridge.install(
      SyncTrayHandlers(
        onSyncNow: () => SyncScheduler.instance.runAllNow(),
        onToggleAutoSync: () async {
          await SyncScheduler.instance.setEnabled(
            !SyncScheduler.instance.enabled,
          );
        },
        onOpenTasks: () async => AppShell.openApp('sync'),
      ),
    ),
  );
  syncTrayBridge.bindScheduler();
  // 装好就把状态报一次：主进程据此画「暂停/恢复自动同步」「立即同步是否可点」。
  // 未登录时 `localTaskCount` 返回 0，菜单里「立即同步」是灰的 —— 符合实际。
  unawaited(syncTrayBridge.refresh());
  runApp(ColaNasApp(launchMode: mode));
  // 相册备份开关是整机状态：必须在 App 启动时就把控制器挂到进程上。
  // 挂在页面里的话，用户切出备份页 / 最小化时 State.dispose 会把网络监听
  // 一起取消，后台上传和通知栏进度全断（2026-11-07 反馈）。
  // 独立端里只有完整客户端与相册端需要它。
  if (mode == AppLaunchMode.full || mode == AppLaunchMode.photo) {
    unawaited(startPhotoBackupService());
  }
}

class ColaNasApp extends StatelessWidget {
  const ColaNasApp({super.key, this.launchMode = AppLaunchMode.full});

  final AppLaunchMode launchMode;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([settings.listenable, i18nRevision]),
      builder: (context, _) => MaterialApp(
        // 全局 Navigator key：无 context 的 GetX controller 靠它弹对话框
        // （`Get.context` 在 MaterialApp 下恒为 null，见 core/app_navigator.dart）
        navigatorKey: kAppNavigatorKey,
        title: switch (launchMode) {
          AppLaunchMode.full => 'ColaNasOs',
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
                      spec.background,
                      child ?? const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
        home: ValueListenableBuilder<bool>(
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
                return switch (launchMode) {
                  AppLaunchMode.full => const AppShell(),
                  AppLaunchMode.photo => const PhotoPage(),
                  AppLaunchMode.music => const MusicPage(),
                  AppLaunchMode.sync => const SyncPage(),
                };
              },
            );
          },
        ),
      ),
    );
  }
}
