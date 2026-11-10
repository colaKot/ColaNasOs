import 'dart:math';

import 'package:flutter/material.dart';

import '../../../compat/getx.dart';

import '../../../list/models/cola_list_models.dart';
import '../../../shared/music_primitives.dart';
import '../../controller/cola_player_controller.dart';

typedef MusicCoverUrlResolver = String Function(MusicListItem item, {int size});

/// 抽屉主体：标题栏 + 播放列表。两个 show 方法只负责各自的容器，
/// 重复的标题栏 / Obx / ListView.builder / ListTile / 封面都收在这里。
class _PlaylistEntries extends StatelessWidget {
  const _PlaylistEntries({
    required this.controller,
    required this.coverUrlResolver,
    required this.theme,
  });

  final MusicPlayServiceController controller;
  final MusicCoverUrlResolver coverUrlResolver;
  final ThemeData theme;

  Widget _titleBar(VoidCallback onClose) => SizedBox(
    height: 56,
    child: Row(
      children: <Widget>[
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            'player_playlist'.tr,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
        const SizedBox(width: 8),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      _titleBar(() => Navigator.of(context).pop()),
      Expanded(
        child: Obx(() {
          final localCurrent = controller.currentIndex.value;
          final localList = controller.playlist;
          return ListView.builder(
            itemCount: localList.length,
            itemBuilder: (c, i) {
              final localSelected = i == localCurrent;
              final localIt = localList[i];
              final localCoverUrl = coverUrlResolver(localIt, size: 120);
              return ListTile(
                selected: localSelected,
                leading: SizedBox(
                  width: 42,
                  height: 42,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: const BorderRadius.all(
                          Radius.circular(8),
                        ),
                        child: MusicCoverImage(
                          url: localCoverUrl,
                          width: 42,
                          height: 42,
                          fit: BoxFit.cover,
                        ),
                      ),
                      if (localSelected)
                        Container(
                          color: Colors.black.withValues(alpha: 0.35),
                          child: const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                          ),
                        ),
                    ],
                  ),
                ),
                title: Text(
                  localIt.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  localIt.artist.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  await controller.playAt(i);
                  if (context.mounted) Navigator.of(context).pop();
                },
              );
            },
          );
        }),
      ),
    ],
  );
}

class MusicPlayCtrlFullScreenPlaylistDrawer {
  static Future<void> showBottomSheet({
    required BuildContext context,
    required MusicPlayServiceController controller,
    required MusicCoverUrlResolver coverUrlResolver,
  }) async {
    final localMedia = MediaQuery.of(context);
    final localTheme = Theme.of(context);
    final localHeight = (localMedia.size.height * 0.86).clamp(
      380.0,
      localMedia.size.height,
    );

    await showModalBottomSheet(
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      context: context,
      builder: (ctx) => SizedBox(
        height: localHeight,
        child: _PlaylistEntries(
          controller: controller,
          coverUrlResolver: coverUrlResolver,
          theme: localTheme,
        ),
      ),
      backgroundColor: localTheme.colorScheme.surface,
    );
  }

  static Future<void> show({
    required BuildContext context,
    required MusicPlayServiceController controller,
    required MusicCoverUrlResolver coverUrlResolver,
  }) async {
    final localMedia = MediaQuery.of(context);
    final localTheme = Theme.of(context);
    final localAnchor = context.findRenderObject();
    final localScreenSize = localMedia.size;
    final localAnchorBox = localAnchor is RenderBox ? localAnchor : null;
    final localAnchorOffset = localAnchorBox == null
        ? Offset.zero
        : localAnchorBox.localToGlobal(Offset.zero);
    final localLeftPad = localAnchorOffset.dx.clamp(0.0, localScreenSize.width);
    final localAnchorSize = localAnchorBox?.size ?? localScreenSize;
    final localRightPad =
        (localScreenSize.width - (localAnchorOffset.dx + localAnchorSize.width))
            .clamp(0.0, localScreenSize.width);
    final localTopPad = localAnchorOffset.dy.clamp(0.0, localScreenSize.height);
    final localBottomPad =
        (localScreenSize.height -
                (localAnchorOffset.dy + localAnchorSize.height))
            .clamp(0.0, localScreenSize.height);
    final localDrawerMinWidth = min(
      380.0,
      localAnchorSize.width * 0.92,
    ).toDouble();
    final localDrawerMaxWidth = min(
      520.0,
      localAnchorSize.width * 0.92,
    ).toDouble();

    await showGeneralDialog(
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (ctx, anim, _, child) {
        final localOffset = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
        return SlideTransition(position: localOffset, child: child);
      },
      pageBuilder: (ctx, a1, a2) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            localLeftPad,
            localTopPad,
            localRightPad,
            localBottomPad,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: localTheme.colorScheme.surface,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: localDrawerMaxWidth,
                  minWidth: localDrawerMinWidth,
                ),
                child: _PlaylistEntries(
                  controller: controller,
                  coverUrlResolver: coverUrlResolver,
                  theme: localTheme,
                ),
              ),
            ),
          ),
        );
      },
      context: context,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.35),
    );
  }
}
