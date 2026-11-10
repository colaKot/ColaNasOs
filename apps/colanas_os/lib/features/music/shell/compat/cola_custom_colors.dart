import 'package:flutter/material.dart';

/// 音乐 / 发现等模块共用的主题色扩展。
///
/// 字段是本项目实际在用的几块表面色；`hairlineBorderColor` 是扁平卡片的
/// 细边框，浅色用中性灰半透、深色用半透白。
class CustomColors extends ThemeExtension<CustomColors> {
  const CustomColors({
    required this.nestedCardColor,
    required this.emptyCardColor,
    required this.leftTreeBgColor,
    required this.mainContentBgColor,
    required this.oprationBarBgColor,
    this.hairlineBorderColor = const Color(0x1F000000),
  });

  final Color nestedCardColor;
  final Color emptyCardColor;
  final Color leftTreeBgColor;
  final Color mainContentBgColor;
  final Color oprationBarBgColor;
  final Color hairlineBorderColor;

  @override
  ThemeExtension<CustomColors> copyWith({
    Color? nestedCardColor,
    Color? secondaryCardColor,
    Color? tertiaryCardColor,
    Color? emptyCardColor,
    Color? leftTreeBgColor,
    Color? mainContentBgColor,
    Color? oprationBarBgColor,
    Color? hairlineBorderColor,
  }) {
    return CustomColors(
      nestedCardColor: nestedCardColor ?? this.nestedCardColor,
      emptyCardColor: emptyCardColor ?? this.emptyCardColor,
      leftTreeBgColor: leftTreeBgColor ?? this.leftTreeBgColor,
      mainContentBgColor: mainContentBgColor ?? this.mainContentBgColor,
      oprationBarBgColor: oprationBarBgColor ?? this.oprationBarBgColor,
      hairlineBorderColor: hairlineBorderColor ?? this.hairlineBorderColor,
    );
  }

  @override
  ThemeExtension<CustomColors> lerp(
    ThemeExtension<CustomColors>? other,
    double t,
  ) {
    if (other is! CustomColors) return this;
    Color blend(Color from, Color to) => Color.lerp(from, to, t)!;
    return CustomColors(
      nestedCardColor: blend(nestedCardColor, other.nestedCardColor),
      emptyCardColor: blend(emptyCardColor, other.emptyCardColor),
      leftTreeBgColor: blend(leftTreeBgColor, other.leftTreeBgColor),
      mainContentBgColor: blend(mainContentBgColor, other.mainContentBgColor),
      oprationBarBgColor: blend(oprationBarBgColor, other.oprationBarBgColor),
      hairlineBorderColor: blend(hairlineBorderColor, other.hairlineBorderColor),
    );
  }
}
