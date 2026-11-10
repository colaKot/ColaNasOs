/// 参考实现 影视发现模块专用的 GetX 导出。
///
/// 参考源码用 `GetxController` / `Rx` / `Obx` / `Get.put`，这些原样保留；
/// 但 GetX 自带的 `Trans` 扩展（`'key'.tr`）会与本项目 `contracts/messages`
/// 多语体系打架，所以这里 hide 掉，改由 [i18n.dart] 提供固定中文文案。
library;

export 'package:get/get.dart' hide Trans;
