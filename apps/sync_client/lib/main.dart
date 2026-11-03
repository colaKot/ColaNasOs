import 'package:colanas_os/shell/app_launch.dart';

/// 同步独立端：入口只有一行——登录后直接进同步。
///
/// 业务代码全部来自 `colanas_os`（path 依赖），改主客户端这里自动生效；
/// 「开机自启」在同步页的自动同步设置里配置（Windows 注册表 / macOS LaunchAgent / Linux autostart）。
void main() => runColanasApp(mode: AppLaunchMode.sync);
