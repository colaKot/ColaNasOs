import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 「加入合集」弹窗：列出我的合集，点一个即把 [itemIds] 加进去。
///
/// 单独成文件是为了避免 `video_page.dart` 与合集页互相 import（合集页要打开影片详情）。
Future<void> showAddToCollectionDialog(
  BuildContext context, {
  required List<String> itemIds,
}) async {
  if (itemIds.isEmpty) return;
  try {
    final res = await ApiSession.instance.client.videoCollectionList();
    if (!context.mounted) return;
    final items = res.items;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.collection.addTo')),
        content: SizedBox(
          width: 420,
          child: items.isEmpty
              ? Text(tr('video.collection.empty'))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (ctx2, i) {
                    final c = items[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.collections_bookmark_outlined),
                      title: Text(c.name),
                      subtitle: Text(
                        tr('video.collection.itemsCount', {'count': c.items}),
                      ),
                      onTap: () async {
                        Navigator.pop(ctx);
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await ApiSession.instance.client
                              .videoCollectionItemsSet(
                            body: VideoCollectionItemsBody(
                              id: c.id,
                              itemIds: itemIds,
                              action: 'add',
                            ),
                          );
                          NasSnack.showOn(messenger, 
                                tr('video.collection.added', {
                                  'count': itemIds.length,
                                }),
                              );
                        } catch (e) {
                          NasSnack.showOn(messenger, '$e');
                        }
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.close')),
          ),
        ],
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    NasSnack.show(context, '$e');
  }
}
