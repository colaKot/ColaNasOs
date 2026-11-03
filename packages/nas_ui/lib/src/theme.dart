import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import 'style.dart';
import 'tokens.dart';

/// 亮 / 暗两套主题（X-04 二期：主题切换）。
///
/// 语义色以 `ColorScheme` 为准。页面里不要再写 `Color(NasTokens.colorTextSecondary)`：
/// 那是暗色主题下的取值，放到浅色背景上对比度不足；改用 `context.nasTextSecondary` /
/// `context.nasDanger`（见文件末尾的扩展），两套主题都能正确取色。
///
/// 三层模型：
/// - **配色**（`NasColorSchemes`）：25 套主色，默认 `shadBlue`；
/// - **皮肤**（`NasSkins`）：4 套结构皮肤，影响圆角与密度；
/// - **明暗**：由 `Brightness` 派生，不重复定义颜色。
class NasTheme {
  const NasTheme._();

  static const _danger = Color(NasTokens.colorDanger);

  static ThemeData dark(
      {String schemeId = 'shadBlue',
      String skinId = 'windows11',
      String? fontFamily}) {
    final primary = NasColorSchemes.colorOf(schemeId);
    final skin = NasSkins.of(skinId);
    final scheme = ColorScheme.dark(
      primary: primary,
      error: _danger,
      surface: Color(NasTokens.colorSurface),
      surfaceContainerHighest: Color(NasTokens.colorSurfaceAlt),
      onSurface: Color(NasTokens.colorTextPrimary),
      onSurfaceVariant: Color(NasTokens.colorTextSecondary),
    );
    return _base(scheme, Brightness.dark, skin, fontFamily);
  }

  static ThemeData light(
      {String schemeId = 'shadBlue',
      String skinId = 'windows11',
      String? fontFamily}) {
    final primary = NasColorSchemes.colorOf(schemeId);
    final skin = NasSkins.of(skinId);
    final scheme = ColorScheme.light(
      primary: primary,
      error: _danger,
      surface: const Color(0xFFF7F8FA),
      surfaceContainerHighest: const Color(0xFFECEEF2),
      onSurface: const Color(0xFF12161B),
      onSurfaceVariant: const Color(0xFF5A6572),
    );
    return _base(scheme, Brightness.light, skin, fontFamily);
  }

  /// 风格化主题：在配色 / 皮肤之上再套一层 [NasUiStyle]（背景、面板材质、圆角、选中态）。
  ///
  /// 与 [dark] / [light] 的区别：
  /// - `scaffoldBackgroundColor` 置为透明 —— 背景由 [NasStyleSpec.background] 铺在 MaterialApp 底层；
  /// - 组件主题（分割线、对话框、按钮、输入框）按风格圆角统一，避免默认 M3 的「方+圆」混搭。
  static ThemeData styled({
    required String styleId,
    String schemeId = 'shadBlue',
    String skinId = 'windows11',
    Brightness brightness = Brightness.dark,
    String? fontFamily,
  }) {
    final base = brightness == Brightness.dark
        ? dark(schemeId: schemeId, skinId: skinId, fontFamily: fontFamily)
        : light(schemeId: schemeId, skinId: skinId, fontFamily: fontFamily);
    final spec =
        NasStyles.spec(NasStyles.parse(styleId), brightness, base.colorScheme);
    final scheme = base.colorScheme;
    final subtle = scheme.onSurface.withValues(alpha: 0.08);
    final fieldRadius = BorderRadius.circular(spec.radius * 0.55);

    return base.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      dividerTheme: DividerThemeData(color: subtle, space: 1, thickness: 1),
      dividerColor: subtle,
      cardTheme: CardThemeData(
        color: spec.panelColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(spec.cardRadius)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: spec.panelColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(spec.radius)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: spec.panelColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(spec.radius)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(spec.radius * 0.55)),
          padding: const EdgeInsets.symmetric(
              horizontal: NasTokens.spaceMd + 4, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(spec.radius * 0.55)),
          side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.18)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(spec.radius * 0.45)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.onSurface.withValues(alpha: 0.05),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: NasTokens.spaceMd, vertical: 12),
        border: OutlineInputBorder(
            borderRadius: fieldRadius, borderSide: BorderSide(color: subtle)),
        enabledBorder: OutlineInputBorder(
            borderRadius: fieldRadius, borderSide: BorderSide(color: subtle)),
        focusedBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.65)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: spec.panelColor,
        indicatorColor: spec.navIndicator,
        elevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(spec.radius * 0.5)),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(spec.radius * 0.5)),
      ),
    );
  }

  static ThemeData _base(
          ColorScheme scheme,
          Brightness brightness,
          NasSkin skin,
          String? fontFamily) =>
      ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorScheme: scheme,
        fontFamily: fontFamily,
        visualDensity: skin.density,
        scaffoldBackgroundColor: scheme.surface,
        // 键盘 / TV D-pad 焦点：Material 组件（按钮 / 列表项 / 输入框）用这层
        // 高亮叠加；自定义卡片在 `_Hoverable` 里另画一圈描边。
        focusColor: scheme.primary.withValues(alpha: 0.24),
        hoverColor: scheme.primary.withValues(alpha: 0.08),
        splashColor: scheme.primary.withValues(alpha: 0.12),
        // 标题栏不再用一块独立的深色底：透明后跟随页面主题背景，
        // 否则深色主题下会变成一条"纯黑条"（用户明确反馈过）。
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          foregroundColor: scheme.onSurface,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: scheme.surfaceContainerHighest,
          elevation: skin.cardElevation,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(skin.radius),
          ),
        ),
      );
}

/// 一套配色（id 存字符串，不存下标：将来增删不会让老用户设置错位）
class NasColorSchemeOption {
  const NasColorSchemeOption(this.id, this.label, this.color);

  final String id;
  final String label;
  final Color color;
}

class NasColorSchemes {
  const NasColorSchemes._();

  /// 精选 25 套（默认 shadBlue 排第一）
  static const options = <NasColorSchemeOption>[
    NasColorSchemeOption('shadBlue', '静谧蓝', Color(0xFF2F6FED)),
    NasColorSchemeOption('ocean', '深海', Color(0xFF0E7490)),
    NasColorSchemeOption('teal', '青碧', Color(0xFF0D9488)),
    NasColorSchemeOption('emerald', '翡翠', Color(0xFF059669)),
    NasColorSchemeOption('forest', '松林', Color(0xFF2F855A)),
    NasColorSchemeOption('olive', '橄榄', Color(0xFF65A30D)),
    NasColorSchemeOption('lime', '青柠', Color(0xFF84CC16)),
    NasColorSchemeOption('amber', '琥珀', Color(0xFFD97706)),
    NasColorSchemeOption('orange', '落日', Color(0xFFEA580C)),
    NasColorSchemeOption('coral', '珊瑚', Color(0xFFFF6B6B)),
    NasColorSchemeOption('red', '朱砂', Color(0xFFDC2626)),
    NasColorSchemeOption('rose', '玫瑰', Color(0xFFE11D48)),
    NasColorSchemeOption('pink', '樱粉', Color(0xFFDB2777)),
    NasColorSchemeOption('fuchsia', '品红', Color(0xFFC026D3)),
    NasColorSchemeOption('purple', '紫罗兰', Color(0xFF9333EA)),
    NasColorSchemeOption('violet', '暮紫', Color(0xFF7C3AED)),
    NasColorSchemeOption('indigo', '靛青', Color(0xFF4F46E5)),
    NasColorSchemeOption('blue', '晴空', Color(0xFF2563EB)),
    NasColorSchemeOption('sky', '天蓝', Color(0xFF0284C7)),
    NasColorSchemeOption('cyan', '湖水', Color(0xFF0891B2)),
    NasColorSchemeOption('slate', '石板', Color(0xFF475569)),
    NasColorSchemeOption('gray', '灰岩', Color(0xFF6B7280)),
    NasColorSchemeOption('brown', '咖啡', Color(0xFF92400E)),
    NasColorSchemeOption('sand', '沙丘', Color(0xFFA16207)),
    NasColorSchemeOption('plum', '梅子', Color(0xFF86198F)),
  ];

  static Color colorOf(String id) {
    for (final option in options) {
      if (option.id == id) return option.color;
    }
    return options.first.color;
  }

  static String labelOf(String id) {
    for (final option in options) {
      if (option.id == id) return option.label;
    }
    return options.first.label;
  }
}

/// 一套结构皮肤：只影响圆角、密度与卡片投影，不改配色
class NasSkin {
  const NasSkin(
      this.id, this.label, this.radius, this.density, this.cardElevation);

  final String id;
  final String label;
  final double radius;
  final VisualDensity density;
  final double cardElevation;
}

class NasSkins {
  const NasSkins._();

  static const options = <NasSkin>[
    NasSkin('windows11', 'Windows 11', 8, VisualDensity.standard, 1),
    NasSkin('macos', 'macOS', 12, VisualDensity.comfortable, 0),
    NasSkin('material3', 'Material 3', 16, VisualDensity.standard, 2),
    NasSkin('compact', '紧凑', 4, VisualDensity.compact, 0),
  ];

  static NasSkin of(String id) {
    for (final skin in options) {
      if (skin.id == id) return skin;
    }
    return options.first;
  }
}

/// 界面字体选项：id 持久化，实际字体族按平台映射（不随包分发字体文件）。
class NasFonts {
  const NasFonts._();

  static const system = 'system';
  static const sans = 'sans';
  static const serif = 'serif';
  static const mono = 'mono';

  static const ids = <String>[system, sans, serif, mono];
}

/// 字体 id → 平台字体族；`system` 返回 null（走 Material 默认）
String? nasFontFamily(String id) {
  if (id.isEmpty || id == NasFonts.system) return null;
  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isMac = defaultTargetPlatform == TargetPlatform.macOS;
  switch (id) {
    case NasFonts.sans:
      return isWindows
          ? 'Microsoft YaHei'
          : isMac
              ? 'PingFang SC'
              : 'Noto Sans CJK SC';
    case NasFonts.serif:
      return isWindows
          ? 'SimSun'
          : isMac
              ? 'Songti SC'
              : 'Noto Serif CJK SC';
    case NasFonts.mono:
      return isWindows
          ? 'Consolas'
          : isMac
              ? 'Menlo'
              : 'DejaVu Sans Mono';
    default:
      return null;
  }
}

/// 语义色取用入口（所有配色 / 皮肤共用同一套 API）
extension NasThemeContext on BuildContext {
  ColorScheme get nas => Theme.of(this).colorScheme;

  /// 次要正文 / 说明
  Color get nasTextSecondary => Theme.of(this).colorScheme.onSurfaceVariant;

  Color get nasDanger => Theme.of(this).colorScheme.error;

  // 警告与成功只用于图标与角标，暗 / 亮两套背景上都可辨认，维持 tokens 原值
  Color get nasWarning => const Color(NasTokens.colorWarning);

  Color get nasSuccess => const Color(NasTokens.colorSuccess);
}
