import 'package:flutter/material.dart';

import '../../../shell/app_nav_shell.dart';
import 'compat/getx.dart';
import 'discover_controller.dart';
import 'discover_view.dart';

/// 是否启用影视发现的 1:1 移植版。
/// 置 false 可一行回退到旧的 `DiscoverShellPage`（便于对比与排障）。
const bool kDiscoverShell = true;

/// 影视发现应用入口。
///
/// 2026-11-08 起改走统一的 [AppNavShell]：手机端是底部 5 个标签、桌面端是二级侧栏，
/// 和相册 / 音乐 / 影视库形态一致。以前 `DiscoverView` 自己画顶部 5 个胶囊，
/// 手机上没有底部标签、也没有回工作台的入口，用户反馈「布局和其它应用不一样」。
///
/// `DiscoverView`（自带胶囊的整页版本）保留在文件里作回退，不再从这里进入。
class DiscoverShellView extends StatelessWidget {
  const DiscoverShellView({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.isRegistered<DiscoverController>()
        ? Get.find<DiscoverController>()
        : Get.put(DiscoverController());
    return AppNavShell(
      appId: 'discover',
      defaultKey: 'discover',
      content: (key) => discoverTabContent(controller, key),
    );
  }
}
