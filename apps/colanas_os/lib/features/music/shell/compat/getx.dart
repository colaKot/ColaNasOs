/// 音乐模块专用的 GetX 导出。
///
/// 保留 `GetxController` / `Rx` / `Obx` / `Get.put` 等基础能力；GetX 自带的
/// `Trans` 扩展（`'key'.tr`）会与项目 `contracts/messages` 多语体系冲突，
/// 因此 hide 掉，改由 `i18n_music.dart` 提供固定中文文案。
library;

export 'package:get/get.dart' hide Trans;

export 'i18n_music.dart';
