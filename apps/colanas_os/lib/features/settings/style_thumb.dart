import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

/// 风格缩略图：把某一套 [NasUiStyle] 的背景 + 面板材质画成一个「小截图」。
///
/// 用真实背景与 [NasPanel]（而不是静态图片），这样改材质时预览自动同步；
/// 内部的小色块代替文字，避免在 200px 宽的卡片里塞不清的字。
class StyleThumb extends StatelessWidget {
  const StyleThumb({super.key, required this.styleId});

  final String styleId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = NasStyles.spec(
      NasStyles.parse(styleId),
      Theme.of(context).brightness,
      scheme,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: NasStyleScope(
        spec: spec,
        child: Stack(
          fit: StackFit.expand,
          children: [
            spec.background,
            Padding(
              padding: const EdgeInsets.all(7),
              child: Row(
                children: [
                  // 迷你侧栏
                  SizedBox(
                    width: 34,
                    child: NasPanel(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  scheme.primary,
                                  const Color(0xFF8B5CF6),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (var i = 0; i < 5; i++)
                            Container(
                              height: 5,
                              margin: const EdgeInsets.symmetric(vertical: 1.5),
                              decoration: BoxDecoration(
                                color: i == 0
                                    ? spec.navIndicator
                                    : scheme.onSurface.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      children: [
                        // 迷你顶栏
                        NasPanel(
                          radius: spec.radius * 0.6,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 5,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 30,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.55,
                                  ),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const Spacer(),
                              Container(
                                width: 34,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.10,
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 7),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: NasCard(
                                  padding: const EdgeInsets.all(6),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 20,
                                        height: 20,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              const Color(0xFFFF6B6B),
                                              const Color(0xFFFF9F43),
                                            ],
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      Container(
                                        width: 34,
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: scheme.onSurface.withValues(
                                            alpha: 0.5,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Container(
                                        width: 22,
                                        height: 3,
                                        decoration: BoxDecoration(
                                          color: scheme.onSurface.withValues(
                                            alpha: 0.18,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: NasCard(
                                  padding: const EdgeInsets.all(6),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 20,
                                        height: 20,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              const Color(0xFF6366F1),
                                              const Color(0xFF9F7AEA),
                                            ],
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      for (var i = 0; i < 2; i++)
                                        Container(
                                          height: 3,
                                          margin: const EdgeInsets.only(
                                            bottom: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: scheme.onSurface.withValues(
                                              alpha: i == 0 ? 0.45 : 0.16,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
