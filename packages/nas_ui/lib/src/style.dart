import 'package:flutter/material.dart';

import 'tokens.dart';

/// 三套**视觉风格**（X-04 三期）：与「配色」「皮肤」「明暗」正交。
///
/// - 配色决定主色，皮肤决定圆角/密度/投影刻度；
/// - 风格决定**背景、面板材质、选中态与卡片形态**，是「看起来像不像产品」的那一层。
///
/// 页面只通过 `context.nasStyle` 取规格，不直接写死模糊半径或背景色。
enum NasUiStyle {
  /// 极光玻璃：深色渐变壁纸 + 半透明模糊面板 + 柔和光晕
  aurora,

  /// 卡片白板：纯色底 + 大圆角卡片 + 彩色图标块（贴近设计稿）
  card,

  /// Fluent 云母：低饱和底 + Mica 面板 + 细描边 + 左侧强调竖条
  fluent,
}

class NasStyleOption {
  const NasStyleOption(this.id, this.label, this.blurb);

  final String id;
  final String label;

  /// 一句话说明，设置页与预览页直接展示
  final String blurb;
}

class NasStyles {
  const NasStyles._();

  static const options = <NasStyleOption>[
    NasStyleOption('aurora', '极光玻璃', '深色渐变壁纸 + 半透明模糊面板，适合影音与相册'),
    NasStyleOption('card', '卡片白板', '纯色底 + 大圆角卡片 + 彩色图标块，信息密度适中'),
    NasStyleOption('fluent', '云母', '低饱和底色 + 细描边 + 强调竖条，最接近桌面系统'),
  ];

  static NasUiStyle parse(String id) => switch (id) {
        'card' => NasUiStyle.card,
        'fluent' => NasUiStyle.fluent,
        _ => NasUiStyle.aurora,
      };

  static String idOf(NasUiStyle style) => style.name;

  static NasStyleOption optionOf(String id) {
    for (final option in options) {
      if (option.id == id) return option;
    }
    return options.first;
  }

  /// 规格工厂：按风格 × 明暗 × 主色生成 [NasStyleSpec]。
  ///
  /// 用 `ColorScheme` 而不是固定色值，保证 25 套配色都能套同一套材质；
  /// 只有「壁纸光斑」用固定的品牌色（极光用青/紫，云母用中性灰）。
  static NasStyleSpec spec(
          NasUiStyle style, Brightness brightness, ColorScheme scheme) =>
      nasStyleSpec(style, brightness, scheme);
}

/// 一套风格的**具体规格**。所有数值都在这里，组件不要自己算。
class NasStyleSpec {
  const NasStyleSpec({
    required this.style,
    required this.brightness,
    required this.radius,
    required this.panelColor,
    required this.panelBorderColor,
    required this.panelBlur,
    required this.panelShadow,
    required this.navWidth,
    required this.navItemHeight,
    required this.navIndicator,
    required this.navAccentBar,
    required this.contentPadding,
    required this.cardRadius,
    required this.cardShadow,
    required this.background,
    required this.baseColor,
  });

  final NasUiStyle style;
  final Brightness brightness;

  final double radius;
  final Color panelColor;
  final Color panelBorderColor;

  /// 面板背后模糊强度（0 = 不模糊，纯色半透明）
  final double panelBlur;
  final List<BoxShadow> panelShadow;

  final double navWidth;
  final double navItemHeight;

  /// 侧栏选中态：`indicator` 为胶囊填充，`accentBar` 为左侧竖条宽度（0 = 不画）
  final Color navIndicator;
  final double navAccentBar;

  final EdgeInsets contentPadding;
  final double cardRadius;
  final List<BoxShadow> cardShadow;

  /// 背景层（铺满整个 App，页面本身透明）
  final Widget background;

  /// 背景的**基色**（渐变背后那一层纯色）。
  ///
  /// 用途：把半透明的 `panelColor` 合成成不透明的等价色，让卡片 / 弹窗 / 列表底色
  /// 既跟背景同色系、又绝不透明。以前用 `colorScheme.surface` 合成，深色主题下那里
  /// 是纯黑 —— 于是所有卡片都是「黑洞」（2026-11-09 用户反馈）。
  final Color baseColor;
}

/// 取当前上下文的风格规格；未包裹时退回极光玻璃。
class NasStyleScope extends InheritedWidget {
  const NasStyleScope({super.key, required this.spec, required super.child});

  final NasStyleSpec spec;

  @override
  bool updateShouldNotify(NasStyleScope oldWidget) => oldWidget.spec != spec;
}

extension NasStyleContext on BuildContext {
  NasStyleSpec get nasStyle =>
      dependOnInheritedWidgetOfExactType<NasStyleScope>()?.spec ??
      NasStyles.spec(NasUiStyle.aurora, Theme.of(this).brightness,
          Theme.of(this).colorScheme);
}

/// 规格工厂实现：`NasStyles.spec` 的独立函数体（[NasStyleSpec] 需要先定义）。
NasStyleSpec nasStyleSpec(
    NasUiStyle style, Brightness brightness, ColorScheme scheme) {
  final dark = brightness == Brightness.dark;
  final primary = scheme.primary;

  switch (style) {
    case NasUiStyle.aurora:
      return NasStyleSpec(
        style: style,
        brightness: brightness,
        radius: 20,
        panelColor: dark ? const Color(0x14FFFFFF) : const Color(0xB3FFFFFF),
        panelBorderColor:
            dark ? const Color(0x1FFFFFFF) : const Color(0x14000000),
        panelBlur: dark ? 22 : 16,
        panelShadow: const [
          BoxShadow(
              color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 12)),
        ],
        navWidth: 128,
        navItemHeight: 44,
        navIndicator: primary.withValues(alpha: dark ? 0.22 : 0.14),
        navAccentBar: 0,
        contentPadding: const EdgeInsets.all(NasTokens.spaceLg),
        cardRadius: 18,
        cardShadow: [
          BoxShadow(
              color: primary.withValues(alpha: dark ? 0.18 : 0.10),
              blurRadius: 28,
              offset: const Offset(0, 14)),
        ],
        background: _AuroraBackground(dark: dark, primary: primary),
        baseColor: dark ? const Color(0xFF0A0E17) : const Color(0xFFEEF2FB),
      );
    case NasUiStyle.card:
      return NasStyleSpec(
        style: style,
        brightness: brightness,
        radius: 16,
        panelColor: dark ? const Color(0xFF191E25) : const Color(0xFFFFFFFF),
        panelBorderColor:
            dark ? const Color(0x14FFFFFF) : const Color(0x0F000000),
        panelBlur: 0,
        panelShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.35 : 0.06),
              blurRadius: 18,
              offset: const Offset(0, 8)),
        ],
        navWidth: 128,
        navItemHeight: 42,
        navIndicator: primary.withValues(alpha: dark ? 0.20 : 0.12),
        navAccentBar: 0,
        contentPadding: const EdgeInsets.all(NasTokens.spaceLg),
        cardRadius: 16,
        cardShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.30 : 0.05),
              blurRadius: 16,
              offset: const Offset(0, 6)),
        ],
        background: _FlatBackground(dark: dark, primary: primary),
        baseColor: dark ? const Color(0xFF0E1218) : const Color(0xFFF4F6FA),
      );
    case NasUiStyle.fluent:
      return NasStyleSpec(
        style: style,
        brightness: brightness,
        radius: 8,
        panelColor: dark ? const Color(0xCC1F1F1F) : const Color(0xCCF6F6F6),
        panelBorderColor:
            dark ? const Color(0x1AFFFFFF) : const Color(0x11000000),
        panelBlur: 30,
        panelShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.25 : 0.04),
              blurRadius: 12,
              offset: const Offset(0, 4)),
        ],
        navWidth: 128,
        navItemHeight: 38,
        navIndicator: primary.withValues(alpha: dark ? 0.26 : 0.16),
        navAccentBar: 3,
        contentPadding: const EdgeInsets.all(NasTokens.spaceMd),
        cardRadius: 10,
        cardShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.24 : 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
        background: _MicaBackground(dark: dark, primary: primary),
        baseColor: dark ? const Color(0xFF1B1B1B) : const Color(0xFFF2F2F2),
      );
  }
}

/// 极光：深底 + 三团光斑 + 轻微暗角
class _AuroraBackground extends StatelessWidget {
  const _AuroraBackground({required this.dark, required this.primary});

  final bool dark;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    final base = dark ? const Color(0xFF0A0E17) : const Color(0xFFEEF2FB);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: base),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.95, -0.9),
              radius: 1.1,
              colors: [
                primary.withValues(alpha: dark ? 0.55 : 0.35),
                base.withValues(alpha: 0)
              ],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.95, -0.6),
              radius: 0.95,
              colors: [
                const Color(0xFF8B5CF6).withValues(alpha: dark ? 0.40 : 0.28),
                base.withValues(alpha: 0),
              ],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.3, 1.1),
              radius: 1.0,
              colors: [
                const Color(0xFF06B6D4).withValues(alpha: dark ? 0.32 : 0.22),
                base.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 卡片白板：纯色底 + 顶部一条极淡的主色渐变，避免大面积死板
class _FlatBackground extends StatelessWidget {
  const _FlatBackground({required this.dark, required this.primary});

  final bool dark;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0E1218) : const Color(0xFFF4F6FA),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            primary.withValues(alpha: dark ? 0.14 : 0.08),
            (dark ? const Color(0xFF0E1218) : const Color(0xFFF4F6FA))
                .withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

/// 云母：中性底色 + 斜向细纹（用极淡的线性渐变模拟，不引入位图）
class _MicaBackground extends StatelessWidget {
  const _MicaBackground({required this.dark, required this.primary});

  final bool dark;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1B1B1B) : const Color(0xFFF2F2F2),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary.withValues(alpha: dark ? 0.10 : 0.06),
            Colors.transparent,
            primary.withValues(alpha: dark ? 0.05 : 0.03),
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
    );
  }
}
