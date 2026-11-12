import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 设备形态判断工具（右键菜单、布局断点使用）。
///
/// 只用 `defaultTargetPlatform` + 宽度断点，足够判断「手机 / 桌面」，
/// 且 Web 端可直接编译。
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
