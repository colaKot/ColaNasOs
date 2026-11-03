/// 设计 tokens（X-04）：颜色 / 间距 / 圆角 / 字体 / 层级 / 动效 / 图标 / 断点。
///
/// 只放**语义化** token：页面里禁止直接写颜色值与魔法间距。
/// 纯 Dart 常量（不依赖 Flutter 类型），便于在线 Dart 测试与多端复用。
class NasTokens {
  const NasTokens._();

  // 间距：4 的倍数，命名按用途而非数值
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 16;
  static const double spaceLg = 24;
  static const double spaceXl = 32;

  // 圆角
  static const double radiusSm = 4;
  static const double radiusMd = 8;
  static const double radiusLg = 16;

  // 字号：标题 5 级 + 正文 3 级 + 等宽
  static const double fontDisplay = 32;
  static const double fontHeadline = 24;
  static const double fontTitle = 18;
  static const double fontSubtitle = 16;
  static const double fontBody = 14;
  static const double fontCaption = 12;
  static const double fontMicro = 11;
  static const double fontMono = 13;

  // 行高
  static const double lineHeightTight = 1.2;
  static const double lineHeightBody = 1.5;
  static const double lineHeightRelaxed = 1.7;

  // 层级（elevation 0–3）
  static const double elevation0 = 0;
  static const double elevation1 = 1;
  static const double elevation2 = 3;
  static const double elevation3 = 6;

  // 动效
  static const int durationFast = 150;
  static const int durationBase = 250;
  static const int durationSlow = 400;

  // 图标尺寸档
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;
  static const double iconXl = 32;

  // 响应式断点（与 responsive.dart 共用）
  static const double breakpointTablet = 600;
  static const double breakpointDesktop = 1024;

  // 语义色（ARGB，避免依赖 Flutter 类型，便于在线 Dart 测试与多端复用）
  static const int colorSurface = 0xFF101418;
  static const int colorSurfaceAlt = 0xFF161C22;
  static const int colorPrimary = 0xFF3B82F6;
  static const int colorDanger = 0xFFEF4444;
  static const int colorWarning = 0xFFF59E0B;
  static const int colorSuccess = 0xFF22C55E;
  static const int colorTextPrimary = 0xFFF5F7FA;
  static const int colorTextSecondary = 0xFF9BA6B2;
  static const int colorOverlay = 0x8A000000;
}
