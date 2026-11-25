import 'shell/app_launch.dart';

/// 相册独立端入口：登录后直接进相册，不经过工作台。
///
/// 与 `apps/photo_client` 的区别：这里直接复用本工程的安卓工程（备份前台服务、
/// 更新安装通道、FileProvider、相册权限全都在），只由
/// `--android-project-arg=nasApp=photo` 换掉 applicationId 与桌面名称。
/// 出包用 `build-photo.bat`，产物是 `dist_installer/ColaNasOs-Photo-<版本>-android-arm64.apk`。
void main() => runColanasApp(mode: AppLaunchMode.photo);
