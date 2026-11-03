import 'package:colanas_os/shell/app_launch.dart';

/// 相册独立端：入口只有一行——登录后直接进相册，不经过主客户端首页。
///
/// 业务代码全部来自 `colanas_os`（path 依赖），改主客户端这里自动生效。
void main() => runColanasApp(mode: AppLaunchMode.photo);