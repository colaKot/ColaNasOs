// tray_manager 0.8.x / window_manager 0.6.x 的新式 nativeapi 接口需要手动管理
// 图标与菜单事件流；这里沿用稳定的兼容层，等插件接口定稿再迁移。
// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:nas_ui/nas_ui.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/legacy.dart';

import '../core/app_settings.dart';
import '../core/autostart.dart';
import 'desktop_tray.dart';

class _DesktopTray with TrayListener, WindowListener implements DesktopTray {
  bool _ready = false;

  @override
  bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  Future<void> init() async {
    if (!supported || _ready) return;
    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      await trayManager.setIcon('assets/icons/tray.png');
      await trayManager.setToolTip('ColaNasOs 客户端');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: tr('tray.show')),
            // 开机自启勾选态跟着本地设置走；点一下当场写系统启动项
            MenuItem.checkbox(
              key: 'autostart',
              label: tr('tray.autostart'),
              checked: AppSettings.instance.startAtBoot.value,
              disabled: !autostartSupported,
              onClick: _toggleAutostart,
            ),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: tr('tray.quit')),
          ],
        ),
      );
      trayManager.addListener(this);
      // 托盘就绪后才拦截关闭：否则窗口藏起来就再也叫不回来
      await windowManager.setPreventClose(true);
      _ready = true;
    } catch (_) {
      windowManager.removeListener(this);
      _ready = false;
    }
  }

  Future<void> _toggleAutostart(MenuItem item) async {
    // 库里点完会按 menuItem.checked 回写原生勾选态，所以这里必须自己翻一次
    final next = !(item.checked ?? false);
    item.checked = next;
    await AppSettings.instance.setStartAtBoot(next);
  }

  @override
  Future<void> dispose() async {
    if (!_ready) return;
    _ready = false;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await windowManager.setPreventClose(false);
      await trayManager.destroy();
    } catch (_) {
      /* 退出路径上失败无需处理 */
    }
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    await dispose();
    exit(0);
  }

  @override
  void onTrayIconMouseDown() {
    _show();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _show();
      case 'quit':
        _quit();
    }
  }

  @override
  void onWindowClose() {
    if (!_ready) return;
    windowManager.hide();
  }
}

DesktopTray createPlatformDesktopTray() => _DesktopTray();