import 'dart:math';

import 'package:flutter/material.dart';

import '../../../compat/host.dart';
import '../../../compat/base_components.dart';
import '../../../compat/cola_api_controller.dart';
import '../../models/cola_album_artist_models.dart';

class AlbumArtistItemCard extends StatelessWidget {
  final double width;
  final VoidCallback onTap;
  final AlbumArtistGroupItem item;
  final double coverSize;
  final String badgeLabel;

  const AlbumArtistItemCard({
    required this.width,
    required this.onTap,
    super.key,
    required this.item,
    required this.coverSize,
    required this.badgeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localTitleStyle = theme.textTheme.titleSmall;
    final localSubtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );
    final localSubtitle = '${max(0, item.indexCount)}首';

    // 整卡可点：封面之外，标题 / 曲目数那两行也要能点开。
    // CustomAlbum 内部虽然也有 onTap，但它只覆盖封面方块，文字区在它外面。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        children: <Widget>[
          SizedBox(
            width: coverSize,
            height: coverSize,
            child: CustomAlbum(
              preview: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _buildCover(theme),
                  if (badgeLabel.trim().isNotEmpty)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.all(Radius.circular(6)),
                        ),
                        child: Text(
                          badgeLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              onTap: onTap,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 46,
            child: Column(
              children: <Widget>[
                Tooltip(
                  waitDuration: const Duration(milliseconds: 300),
                  message: item.name,
                  child: SizedBox(
                    width: width,
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: localTitleStyle,
                    ),
                  ),
                ),
                if (localSubtitle.isNotEmpty)
                  SizedBox(
                    width: width,
                    child: Text(
                      localSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: localSubtitleStyle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCover(ThemeData theme) {
    final localCoverFilePath = item.firstFilePath.trim();
    if (localCoverFilePath.isNotEmpty) {
      final localUrl = ApiController.instance.getMusicCoverUrl(
        filePath: localCoverFilePath,
        size: 200,
      );
      if (localUrl.isNotEmpty) {
        return CustomExtendedImage(
          showLoading: false,
          imageUrl: localUrl,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _fallbackCover(theme),
          borderRadius: 0,
        );
      }
    }
    return _fallbackCover(theme);
  }

  Widget _fallbackCover(ThemeData theme) {
    final localAssetPath = _pickFallbackCoverAsset();
    return Container(
      color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.4),
      child: Image.asset(
        localAssetPath,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      ),
    );
  }

  String _pickFallbackCoverAsset() {
    final localSeed = item.name.hashCode;
    final localRng = Random(localSeed);
    final localIdx = localRng.nextInt(20) + 1;
    return 'assets/music/musicCover/other$localIdx.jpg';
  }
}
