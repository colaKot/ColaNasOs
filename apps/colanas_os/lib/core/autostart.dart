import 'autostart_stub.dart' if (dart.library.io) 'autostart_io.dart' as impl;

/// 「开机自动启动」的平台落地。
///
/// 状态本身存在客户端本地设置里（`boot.autostart`），这里只负责让系统生效：
///   - Windows：写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，
///     值指向**当前 exe 的实际路径**（`Platform.resolvedExecutable`），
///     所以安装版 / 便携版挪目录后重新勾一次就会重新对账；
///   - 其它平台（含 Web）：不支持，返回 false，界面按此隐藏 / 置灰开关。
///
/// 为什么不用 `app.setLoginItemSettings`：那是 Electron 的能力，Flutter 桌面端没有；
/// 也不想为这一个开关引第三方插件 —— `reg.exe` 是系统自带，零依赖。
bool get autostartSupported => impl.autostartSupported;

/// 让系统启动项与 [enabled] 一致；返回是否真的写成功
Future<bool> setAutostartEnabled(bool enabled) =>
    impl.setAutostartEnabled(enabled);

/// 启动时对账一次：开启状态下按当前 exe 路径重写启动项
Future<void> syncAutostartEntry(bool enabled) =>
    impl.syncAutostartEntry(enabled);
