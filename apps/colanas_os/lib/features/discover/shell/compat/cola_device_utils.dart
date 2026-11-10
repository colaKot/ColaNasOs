import 'package:flutter/foundation.dart';

/// 既有实现 `DeviceUtils.isDesktopOrWeb` 的最小等价实现（右键菜单开关用）。
/// 用 `defaultTargetPlatform` 而不是 `dart:io`，保持 Web 端可编译。
class DeviceUtils {
  const DeviceUtils._();

  static bool get isWeb => kIsWeb;

  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  static bool get isDesktopOrWeb => isDesktop || isWeb;
}
