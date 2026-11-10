import '../../compat/getx.dart';
import '../../sub_list/controller/cola_sub_list_controller.dart';
import '../../detail/controller/music_detail_controllers.dart';

/// 歌单详情页状态。
///
/// 和专辑页共用 `MusicDetailActions`（播放全部 / 随机 / 收藏 / 下载 / 复制），
/// 差别只有两点：
/// - 数据来源：`keyType: 'playlist'` + `listId`，走 `/compat/list` 的 `list_id` 过滤；
/// - 没有专辑的元信息（年份 / 流派 / 简介），封面直接取列表第一首的内嵌封面。
class PlaylistDetailController extends GetxController with MusicDetailActions {
  PlaylistDetailController({required this.name, required this.listId});

  final String name;
  final int listId;

  @override
  MusicSubListController? tracks;

  String get tracksTag => 'playlist_tracks::$listId';

  @override
  void onInit() {
    super.onInit();
    tracks = Get.isRegistered<MusicSubListController>(tag: tracksTag)
        ? Get.find<MusicSubListController>(tag: tracksTag)
        : Get.put(
            MusicSubListController(
              keyType: 'playlist',
              name: name,
              listId: listId,
              // 歌单内固定按文件名排（与旧版歌单遮罩一致），不跟随曲库的排序缓存
              initialSortBy: MusicSubListSortBy.filename,
              initialSortOrder: MusicSubListSortOrder.asc,
              ignoreStoredSort: true,
            ),
            tag: tracksTag,
          );
  }

  @override
  String get summaryText {
    final count = tracks?.total.value ?? 0;
    return '$name（$count 首）';
  }

  /// 歌单封面：取第一首有内嵌封面的曲目；没有就回落到默认图
  String get coverUrl => tracks?.headerCoverUrl ?? '';
}
