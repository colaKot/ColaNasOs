import '../../compat/getx.dart';

/// 曲目列表（主列表 / 子列表 / 歌单内列表）共用的多选契约。
///
/// 只声明视图与批量动作需要的最小集合；具体列表各自决定「选中项从哪来」、
/// 「删除走哪个接口」。两个派生 getter 让调用方不必每次自己判空。
abstract class MusicMultiSelectController {
  /// 当前选中的 indexId 集合
  RxSet<int> get selectedItems;

  /// 当前页是否全选
  bool get isAllCurrentSelected;

  /// 选中项是否都已收藏
  bool get isSelectedAllFavorited;

  /// 当前是否处在某个歌单内部（决定能不能「从歌单移除」）
  bool get isInPlayList;

  bool get hasSelection;

  int get selectedCount;

  void toggleSelectAllCurrent();

  Future<void> toggleFavoriteSelected();

  Future<void> downloadSelected();

  Future<void> deleteSelected();

  Future<void> addToPlayListSelected();

  Future<void> removeFromPlayListSelected();

  void exitMultiSelectMode();
}
