import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:nas_core/nas_core.dart';

import 'settings_store.dart';

export 'package:nas_ui/nas_ui.dart' show tr;

/// 语言切换后自增，宿主据此重建（`nas_core` 不依赖 flutter，所以适配放在 app 侧）
final ValueNotifier<int> i18nRevision = ValueNotifier<int>(0);

/// 语言选择列表：**只展示已翻译完成的语言**（`enabled` 由 `npm run gen:locales`
/// 按覆盖率派生，阈值 95%）。未达标的语言不再出现在下拉框里，避免"切过去
/// 整页回退中文"的假支持。
List<(String code, String native)> get supportedLocales =>
    enabledLocales.map((l) => (l.code, l.native)).toList(growable: false);

/// 加载语言包（assets/i18n/<code>.json，由 `npm run gen:i18n` 从契约生成）
Future<void> initI18n() async {
  I18n.instance.configure((code) async {
    final raw = await rootBundle.loadString('assets/i18n/$code.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final messages = (json['messages'] as Map?) ?? const {};
    return messages.map((key, value) => MapEntry(key.toString(), '$value'));
  });
  final saved =
      SettingsStore.instance.getString('ui.locale') ?? I18n.fallbackLocale;
  // 旧版本可能存了已停用的语言（如 ja-JP）：回退到默认语言，避免加载缺失的语言包
  final usable = supportedLocales.any((l) => l.$1 == saved);
  await I18n.instance.load(usable ? saved : I18n.fallbackLocale);
  i18nRevision.value += 1;
}

/// 切换语言并落盘
Future<void> setLocale(String code) async {
  await I18n.instance.load(code);
  await SettingsStore.instance.setString('ui.locale', code);
  i18nRevision.value += 1;
}

/// 页面侧的 `tr` 由 `package:nas_ui` 导出（同一实现），这里再导出一次方便 core 引用
