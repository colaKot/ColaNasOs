import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../controller/cola_list_controller.dart';
import '../../../compat/host.dart';

class MusicListFilterMenu extends StatelessWidget {
  final MusicListController controller;
  const MusicListFilterMenu({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final albums = controller.availableAlbums.toList();
      final artists = controller.availableArtists.toList();
      final genres = controller.availableGenres.toList();

      return ColaHoverMenuAnchor(
        menuChildren: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860, minWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _optionGroup(
                    theme,
                    label: 'music_list_filter_artists'.tr,
                    values: artists,
                    chosen: controller.artists,
                    onToggle: controller.toggleArtist,
                    onClear: () {
                      controller.artists.clear();
                      controller.refreshList(showLoading: true);
                    },
                  ),
                  _optionGroup(
                    theme,
                    label: 'music_list_filter_albums'.tr,
                    values: albums,
                    chosen: controller.albums,
                    onToggle: controller.toggleAlbum,
                    onClear: () {
                      controller.albums.clear();
                      controller.refreshList(showLoading: true);
                    },
                  ),
                  _optionGroup(
                    theme,
                    label: 'music_list_filter_genres'.tr,
                    values: genres,
                    chosen: controller.genres,
                    onToggle: controller.toggleGenre,
                    onClear: () {
                      controller.genres.clear();
                      controller.refreshList(showLoading: true);
                    },
                  ),
                  const SizedBox(height: 6.0),
                  Row(
                    children: <Widget>[
                      const Spacer(),
                      TextButton.icon(
                        onPressed: controller.resetFilter,
                        label: Text('reset'.tr),
                        icon: const Icon(Icons.refresh, size: 18.0),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
        child: VideoListBadge(
          count: controller.activeFilterCount,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.filter_alt_outlined, size: 18.0),
              const SizedBox(width: 6.0),
              Text('filter'.tr),
            ],
          ),
        ),
      );
    });
  }

  Widget _optionGroup(
    ThemeData theme, {
    required String label,
    required List<String> values,
    required List<String> chosen,
    required ValueChanged<String> onToggle,
    required VoidCallback onClear,
  }) {
    final options = <Widget>[];
    if (values.isEmpty) {
      options.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
          child: Text('no_data'.tr, style: theme.textTheme.bodyMedium),
        ),
      );
    } else {
      options.add(
        _optionChip(
          theme,
          text: 'all'.tr,
          selected: chosen.isEmpty,
          onTap: onClear,
        ),
      );
      for (final value in values) {
        options.add(
          _optionChip(
            theme,
            text: value,
            selected: chosen.contains(value),
            onTap: () => onToggle(value),
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 92.0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 0),
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
          Expanded(child: Wrap(spacing: 10, runSpacing: 10, children: options)),
        ],
      ),
    );
  }

  Widget _optionChip(
    ThemeData theme, {
    required String text,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final foreground = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      borderRadius: BorderRadius.all(Radius.circular(8)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.all(Radius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
          ),
        ),
      ),
    );
  }
}
