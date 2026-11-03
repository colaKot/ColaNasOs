import 'package:colanas_os/shell/app_launch.dart';

/// 音乐独立端：入口只有一行——登录后直接进音乐库。
///
/// 业务代码全部来自 `colanas_os`（path 依赖），改主客户端这里自动生效。
void main() => runColanasApp(mode: AppLaunchMode.music);