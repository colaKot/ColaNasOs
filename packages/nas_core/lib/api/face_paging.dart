/// 人脸相关列表的聚合封装。
///
/// 服务端按页返回（默认 500，单页上限 5000）+ `nextCursor`，本身不设总量上限；
/// 这里逐页请求，**通过 onPageItems 把每一页立刻交给调用方渐进显示**，避免
/// 「等全量拉完才出画面」。人脸管理页的合并 / 改封面 / 关系操作依赖完整候选集，
/// 所以最终仍返回全量列表 —— 这是刻意保留的语义，不要改成只返回第一页。
library;

import 'client.dart';
import 'models.dart';

/// 单页张数（服务端上限 5000，这里取折中值，兼顾往返次数与单次响应大小）
const int kFacePageSize = 1000;

/// 聚合硬上限：异常库 / 服务端游标不推进时也要能停，不能 while(true) 无界拉
const int kFaceMaxItems = 10000;

extension PhotoFacePaging on ApiClient {
  /// 全部人脸簇（按人数倒序；minCount 交给服务端按 AI 设置过滤）
  Future<List<PhotoFaceClusterItem>> photoFaceClustersAll({
    int? minCount,
    int pageSize = kFacePageSize,
    int maxItems = kFaceMaxItems,
    void Function(int loaded)? onPage,
    void Function(List<PhotoFaceClusterItem> page)? onPageItems,
  }) async {
    final out = <PhotoFaceClusterItem>[];
    var offset = 0;
    while (out.length < maxItems) {
      final page = await photoFaceClusters(
        minCount: minCount,
        limit: pageSize,
        cursor: offset,
      );
      if (page.items.isEmpty) break;
      final take = page.items.take(maxItems - out.length).toList(growable: false);
      out.addAll(take);
      onPageItems?.call(take);
      onPage?.call(out.length);
      final next = page.nextCursor;
      if (next == null) break;
      final parsed = int.tryParse(next);
      // 游标没往前走就停：服务端异常时否则会无限循环同一页
      if (parsed == null || parsed <= offset) break;
      offset = parsed;
    }
    return out;
  }

  /// 某个人脸簇下的全部照片（按拍摄时间倒序）
  Future<List<PhotoFaceItem>> photoFacesAll(
    String id, {
    int pageSize = kFacePageSize,
    int maxItems = kFaceMaxItems,
    void Function(int loaded)? onPage,
    void Function(List<PhotoFaceItem> page)? onPageItems,
  }) async {
    final out = <PhotoFaceItem>[];
    var offset = 0;
    while (out.length < maxItems) {
      final page = await photoFaces(id: id, limit: pageSize, cursor: offset);
      if (page.items.isEmpty) break;
      final take = page.items.take(maxItems - out.length).toList(growable: false);
      out.addAll(take);
      onPageItems?.call(take);
      onPage?.call(out.length);
      final next = page.nextCursor;
      if (next == null) break;
      final parsed = int.tryParse(next);
      if (parsed == null || parsed <= offset) break;
      offset = parsed;
    }
    return out;
  }
}
