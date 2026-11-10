import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../controller/cola_list_controller.dart';
import '../../../compat/host.dart';

class MusicListFilterMenu extends StatelessWidget {
  final MusicListController controller;
  const MusicListFilterMenu({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final localTheme = Theme.of(context);
    return Obx(() {
      final localAlbums = controller.availableAlbums.toList();
      final localArtists = controller.availableArtists.toList();
      final localGenres = controller.availableGenres.toList();

      Widget chip({
        required String text,
        required bool selected,
        required VoidCallback onTap,
      }) {
        final localFg = selected
            ? localTheme.colorScheme.primary
            : localTheme.colorScheme.onSurface;
        final localBg = selected
            ? localTheme.colorScheme.primary.withValues(alpha: 0.14)
            : Colors.transparent;
        return Material(
          color: localBg,
          borderRadius: BorderRadius.all(Radius.circular(8)),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.all(Radius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: Text(
                text,
                style: localTheme.textTheme.bodyMedium?.copyWith(
                  color: localFg,
                ),
              ),
            ),
          ),
        );
      }

      Widget groupRow({required String label, required List<Widget> options}) {
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
                    style: localTheme.textTheme.bodyMedium?.copyWith(
                      color: localTheme.colorScheme.onSurface.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Wrap(spacing: 10, runSpacing: 10, children: options),
              ),
            ],
          ),
        );
      }

      List<Widget> artistOptions() {
        if (localArtists.isEmpty) {
          return [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
              child: Text('no_data'.tr, style: localTheme.textTheme.bodyMedium),
            ),
          ];
        }
        return [
          chip(
            text: 'all'.tr,
            selected: controller.artists.isEmpty,
            onTap: () {
              controller.artists.clear();
              controller.refreshList(showLoading: true);
            },
          ),
          ...localArtists.map((a) {
            final selected = controller.artists.contains(a);
            return chip(
              text: a,
              selected: selected,
              onTap: () => controller.toggleArtist(a),
            );
          }),
        ];
      }

      List<Widget> albumOptions() {
        if (localAlbums.isEmpty) {
          return [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
              child: Text('no_data'.tr, style: localTheme.textTheme.bodyMedium),
            ),
          ];
        }
        return [
          chip(
            text: 'all'.tr,
            selected: controller.albums.isEmpty,
            onTap: () {
              controller.albums.clear();
              controller.refreshList(showLoading: true);
            },
          ),
          ...localAlbums.map((a) {
            final selected = controller.albums.contains(a);
            return chip(
              text: a,
              selected: selected,
              onTap: () => controller.toggleAlbum(a),
            );
          }),
        ];
      }

      List<Widget> genreOptions() {
        if (localGenres.isEmpty) {
          return [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
              child: Text('no_data'.tr, style: localTheme.textTheme.bodyMedium),
            ),
          ];
        }
        return [
          chip(
            text: 'all'.tr,
            selected: controller.genres.isEmpty,
            onTap: () {
              controller.genres.clear();
              controller.refreshList(showLoading: true);
            },
          ),
          ...localGenres.map((g) {
            final selected = controller.genres.contains(g);
            return chip(
              text: g,
              selected: selected,
              onTap: () => controller.toggleGenre(g),
            );
          }),
        ];
      }

      final localCount = controller.activeFilterCount;

      return CustomHoverMenuAnchor(
        menuChildren: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860, minWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  groupRow(
                    label: 'music_list_filter_artists'.tr,
                    options: artistOptions(),
                  ),
                  groupRow(
                    label: 'music_list_filter_albums'.tr,
                    options: albumOptions(),
                  ),
                  groupRow(
                    label: 'music_list_filter_genres'.tr,
                    options: genreOptions(),
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
          count: localCount,
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
}
