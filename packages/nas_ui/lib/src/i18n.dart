import 'package:nas_core/nas_core.dart';

/// 文案快捷方式（放在 nas_ui 是为了让页面只依赖一个包）：
/// `tr(I18nKeys.appPhoto)` / `tr('files.upload.progress', {'done': 1, 'total': 3})`。
///
/// 回退链与运行时见 `nas_core` 的 [I18n]：当前语言 → zh-CN → 键本身。
String tr(String key, [Map<String, Object?>? args]) =>
    I18n.instance.tr(key, args);
