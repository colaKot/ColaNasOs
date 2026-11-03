import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_settings.dart';
import 'style_thumb.dart';

/// 界面风格预览：三套材质并排对比，点「采用」立即全局生效。
///
/// 缩略图用**真实组件**（[NasPanel] / [NasAppCard] / [NasFileTile]）在独立的
/// [NasStyleScope] 里渲染，所以预览与实际界面不会「预览一套、上线另一套」。
class StylePreviewPage extends StatelessWidget {
  const StylePreviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: context.nasStyle.contentPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  NasIconAction(
                    icon: Icons.arrow_back,
                    tooltip: tr('common.close'),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: NasTokens.spaceSm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('style.preview'),
                          style: TextStyle(
                            fontSize: NasTokens.fontHeadline,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        Text(
                          tr('style.previewHint'),
                          style: TextStyle(
                            fontSize: NasTokens.fontBody,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NasTokens.spaceLg),
              ValueListenableBuilder<String>(
                valueListenable: AppSettings.instance.styleId,
                builder: (context, current, _) => LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 1080
                        ? 3
                        : constraints.maxWidth >= 720
                        ? 2
                        : 1;
                    const gap = NasTokens.spaceMd;
                    final cardWidth =
                        (constraints.maxWidth - gap * (columns - 1)) / columns;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final option in NasStyles.options)
                          SizedBox(
                            width: cardWidth,
                            child: _StyleCard(
                              styleId: option.id,
                              selected: current == option.id,
                              scheme: scheme,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.styleId,
    required this.selected,
    required this.scheme,
  });

  final String styleId;
  final bool selected;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return NasCard(
      highlight: selected,
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: StyleThumb(styleId: styleId),
          ),
          const SizedBox(height: NasTokens.spaceMd),
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('style.$styleId'),
                  style: TextStyle(
                    fontSize: NasTokens.fontTitle,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (selected)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    tr('style.apply'),
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      color: scheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            tr('style.$styleId.desc'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: NasTokens.spaceMd),
          SizedBox(
            width: double.infinity,
            child: selected
                ? OutlinedButton(
                    onPressed: null,
                    child: Text(tr('style.apply')),
                  )
                : FilledButton(
                    onPressed: () => AppSettings.instance.setStyle(styleId),
                    child: Text(tr('style.apply')),
                  ),
          ),
        ],
      ),
    );
  }
}
