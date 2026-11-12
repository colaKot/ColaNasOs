import '../../compat/json_read.dart';
import '../../list/models/cola_list_models.dart';
import '../../shared/music_item_logic.dart';

/// 专辑 / 歌手聚合列表中的一行。
///
/// 两种列表共用本模型：`keyType` 标记分组维度，`name` 是聚合后的组名，
/// 封面取组内第一首曲目的路径。
class AlbumArtistGroupItem {
  final String name;
  final String keyType;
  final int indexCount;
  final String firstFilePath;

  const AlbumArtistGroupItem({
    required this.name,
    required this.keyType,
    required this.indexCount,
    required this.firstFilePath,
  });

  bool get isAlbum => _type == 'album';

  bool get isArtist => _type == 'artist';

  String get _type => keyType.trim().toLowerCase();

  factory AlbumArtistGroupItem.fromJson(Map<String, dynamic> json) =>
      AlbumArtistGroupItem(
        name: json.readString(const ['name']).trim(),
        keyType: json.readString(const ['key_type', 'keyType']),
        indexCount: json.readInt(const ['index_count', 'indexCount']),
        firstFilePath: json.readString(const [
          'first_file_path',
          'firstFilePath',
        ]),
      );
}

/// 专辑 / 歌手列表的一次分页返回。
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
      // 组名为空时无法进入详情，视为脏数据丢弃。
      items: json
          .readList(const ['items'], AlbumArtistGroupItem.fromJson)
          .where((item) => item.name.isNotEmpty)
          .toList(),
      pagination: envelope.pagination,
      validPaths: envelope.validPaths,
    );
  }
}
