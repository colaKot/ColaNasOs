import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import 'settings_store.dart';
import 'tv_mode.dart';

/// 外观设置：明暗 + 配色（25 套）+ 皮肤（4 套）+ 界面风格（3 套），**持久化**到本地设置文件。
///
/// id 一律存**字符串**（`shadBlue` / `windows11` / `aurora`），不存下标：
/// 将来增删配色或皮肤时，老用户的设置不会错位到另一套主题上。
class AppSettings {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  final ValueNotifier<ThemeMode> themeMode = ValueNotifier<ThemeMode>(
    ThemeMode.dark,
  );
  final ValueNotifier<String> schemeId = ValueNotifier<String>('shadBlue');
  final ValueNotifier<String> skinId = ValueNotifier<String>('windows11');

  /// 界面风格：`aurora` / `card` / `fluent`（见 `NasStyles`）
  final ValueNotifier<String> styleId = ValueNotifier<String>('aurora');

  /// 界面字体：`system` / `sans` / `serif` / `mono`（见 `NasFonts`）
  final ValueNotifier<String> fontId = ValueNotifier<String>(NasFonts.system);

  /// TV / 大屏模式：大字号 + 常显侧栏 + D-pad 焦点导航
  final ValueNotifier<bool> tvMode = ValueNotifier<bool>(kTvBuild);

  /// 是否在页面顶部显示「× 在当前端为受限能力」横幅。
  ///
  /// **默认关闭**。理由：绝大多数人在固定设备上用，横幅每次进页面都占一行、
  /// 还说不到具体哪个按钮不能用，属于噪音；真要排查端差异时在「设置 → 外观」打开。
  /// 能力矩阵数据仍然保留（导航 / 文档 / 测试在用），只是不再默认打扰用户。
  final ValueNotifier<bool> capabilityNotice = ValueNotifier<bool>(false);

  Listenable get listenable => Listenable.merge(
        [themeMode, schemeId, skinId, styleId, fontId, tvMode, capabilityNotice],
      );

  Future<void> load() async {
    await SettingsStore.instance.load();
    final mode = SettingsStore.instance.getString('theme.mode');
    if (mode == 'light') themeMode.value = ThemeMode.light;
    if (mode == 'system') themeMode.value = ThemeMode.system;
    if (mode == 'dark') themeMode.value = ThemeMode.dark;

    final scheme = SettingsStore.instance.getString('theme.scheme');
    if (scheme != null && scheme.isNotEmpty) schemeId.value = scheme;

    final skin = SettingsStore.instance.getString('theme.skin');
    if (skin != null && skin.isNotEmpty) skinId.value = skin;

    final style = SettingsStore.instance.getString('theme.style');
    if (style != null && style.isNotEmpty) styleId.value = style;

    final font = SettingsStore.instance.getString('theme.font');
    if (font != null && NasFonts.ids.contains(font)) fontId.value = font;

    // 未保存过时沿用构建开关（电视盒子固件可直接编 `COLANAS_TV=1`）
    final tv = SettingsStore.instance.getString('ui.tv');
    tvMode.value = tv == null ? kTvBuild : tv == '1';

    // 未保存过 = 关（默认不打扰）
    capabilityNotice.value =
        SettingsStore.instance.getString('ui.capabilityNotice') == '1';
  }

  Future<void> setCapabilityNotice(bool on) async {
    capabilityNotice.value = on;
    await SettingsStore.instance.setString('ui.capabilityNotice', on ? '1' : '0');
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await SettingsStore.instance.setString(
      'theme.mode',
      mode == ThemeMode.light
          ? 'light'
          : mode == ThemeMode.system
          ? 'system'
          : 'dark',
    );
  }

  Future<void> setScheme(String id) async {
    schemeId.value = id;
    await SettingsStore.instance.setString('theme.scheme', id);
  }

  Future<void> setSkin(String id) async {
    skinId.value = id;
    await SettingsStore.instance.setString('theme.skin', id);
  }

  Future<void> setStyle(String id) async {
    styleId.value = id;
    await SettingsStore.instance.setString('theme.style', id);
  }

  Future<void> setFont(String id) async {
    fontId.value = NasFonts.ids.contains(id) ? id : NasFonts.system;
    await SettingsStore.instance.setString('theme.font', fontId.value);
  }

  Future<void> setTvMode(bool enabled) async {
    tvMode.value = enabled;
    await SettingsStore.instance.setString('ui.tv', enabled ? '1' : '0');
  }
}
