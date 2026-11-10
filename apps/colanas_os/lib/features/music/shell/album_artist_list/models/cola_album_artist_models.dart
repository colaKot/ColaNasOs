import '../../compat/json_read.dart';
import '../../list/models/cola_list_models.dart';
import '../../shared/music_item_logic.dart';

/// 专辑 / 歌手聚合列表里的一行
///
/// 两个列表共用同一个模型：`keyType` 区分是「专辑」还是「歌手」，
/// 聚合出来的名字放 `name`，封面用组内第一首的路径去取。
class AlbumArtistGroupItem {
  final String keyType;
  final String name;
  final String firstFilePath;
  final int indexCount;

  const AlbumArtistGroupItem({
    required this.keyType,
    required this.name,
    required this.firstFilePath,
    required this.indexCount,
  });

  bool get isAlbum => keyType.trim().toLowerCase() == 'album';

  bool get isArtist => keyType.trim().toLowerCase() == 'artist';

  factory AlbumArtistGroupItem.fromJson(Map<String, dynamic> json) =>
      AlbumArtistGroupItem(
        keyType: json.readString(const ['key_type', 'keyType']),
        name: json.readString(const ['name']).trim(),
        firstFilePath: json.readString(const [
          'first_file_path',
          'firstFilePath',
        ]),
        indexCount: json.readInt(const ['index_count', 'indexCount']),
      );
}

/// 专辑 / 歌手列表的一次返回
class AlbumArtistListPagedResult {
  final List<AlbumArtistGroupItem> items;
  final MusicListPagination pagination;
  final List<MusicListPathItem> validPaths;

  const AlbumArtistListPagedResult({
    required this.items,
    required this.pagination,
    required this.validPaths,
  });

  const AlbumArtistListPagedResult.empty()
    : items = const <AlbumArtistGroupItem>[],
      pagination = const MusicListPagination.empty(),
      validPaths = const <MusicListPathItem>[];

  factory AlbumArtistListPagedResult.fromJson(Map<String, dynamic> json) {
    final envelope = MusicPagedEnvelope.read(json);
    return AlbumArtistListPagedResult(
      // 名字为空的组没法点进去，属于脏数据，直接丢
      items: json
          .readList(const ['items'], AlbumArtistGroupItem.fromJson)
          .where((item) => item.name.isNotEmpty)
          .toList(),
      pagination: envelope.pagination,
      validPaths: envelope.validPaths,
    );
  }
}
