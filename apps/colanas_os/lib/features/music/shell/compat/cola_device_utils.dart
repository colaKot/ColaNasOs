import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 既有实现 `utils/cola_device_utils.dart` 的最小等价实现。
///
/// 参考版依赖 `device_utils_io.dart` / `device_utils_web.dart` 两个平台文件
/// （要读 dart:io / window.navigator），这里只用 `defaultTargetPlatform` +
/// 宽度断点，够音乐模块判断「是不是手机/桌面」，且 Web 可编译。
class DeviceUtils {
  const DeviceUtils._();

  static const double phoneBreakpoint = 600;
  static const double desktopBreakpoint = 600;

  static bool get isWeb => kIsWeb;

  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  static bool get isMobile => !isDesktop;

  static bool get isDesktopOrWeb => isDesktop || isWeb;

  static bool isPhone(BuildContext context) =>
      MediaQuery.sizeOf(context).width < phoneBreakpoint;

  static bool isDesktopLayout(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= desktopBreakpoint;
}
