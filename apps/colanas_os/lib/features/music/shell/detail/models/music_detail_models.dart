import '../../compat/json_read.dart';

/// 专辑 / 歌手详情页的数据模型。
///
/// 全部来自 `/compat/album/detail` 与 `/compat/artist/detail` 两个聚合口；
/// 曲目列表不在这里 —— 它仍走 `/compat/list`，由 `MusicSubListController` 管分页。

/// Last.fm 热度（未配置 API Key 时全部是 0，页面据此隐藏热度行）
class MusicCrowd {
  final bool configured;
  final bool cached;
  final int playcount;
  final int listeners;
  final String url;
  final String summary;
  final String image;
  final List<String> tags;

  const MusicCrowd({
    this.configured = false,
    this.cached = false,
    this.playcount = 0,
    this.listeners = 0,
    this.url = '',
    this.summary = '',
    this.image = '',
    this.tags = const <String>[],
  });

  const MusicCrowd.empty()
    : configured = false,
      cached = false,
      playcount = 0,
      listeners = 0,
      url = '',
      summary = '',
      image = '',
      tags = const <String>[];

  /// 有没有可展示的热度数字
  bool get hasStats => playcount > 0 || listeners > 0;

  factory MusicCrowd.fromJson(Map<String, dynamic> json) => MusicCrowd(
    configured: json.readBool(const ['configured']),
    cached: json.readBool(const ['cached']),
    playcount: json.readInt(const ['playcount']),
    listeners: json.readInt(const ['listeners']),
    url: json.readString(const ['url']),
    summary: json.readString(const ['summary']),
    image: json.readString(const ['image']),
    tags: json.readStringList(const ['tags']),
  );
}

/// 专辑详情头部
class AlbumDetailInfo {
  final bool found;
  final String name;
  final String artist;
  final String coverPath;
  final int trackCount;

  /// 秒
  final int totalDuration;
  final String year;
  final String genre;
  final int firstIndexId;
  final MusicCrowd crowd;

  const AlbumDetailInfo({
    required this.found,
    required this.name,
    required this.artist,
    required this.coverPath,
    required this.trackCount,
    required this.totalDuration,
    required this.year,
    required this.genre,
    required this.firstIndexId,
    required this.crowd,
  });

  const AlbumDetailInfo.empty()
    : found = false,
      name = '',
      artist = '',
      coverPath = '',
      trackCount = 0,
      totalDuration = 0,
      year = '',
      genre = '',
      firstIndexId = 0,
      crowd = const MusicCrowd.empty();

  factory AlbumDetailInfo.fromJson(Map<String, dynamic> json) =>
      AlbumDetailInfo(
        found: json.readBool(const ['found']),
        name: json.readString(const ['name']),
        artist: json.readString(const ['artist']),
        coverPath: json.readString(const ['cover_path', 'coverPath']),
        trackCount: json.readInt(const ['track_count', 'trackCount']),
        totalDuration: json.readInt(const ['total_duration', 'totalDuration']),
        year: json.readString(const ['year']),
        genre: json.readString(const ['genre']),
        firstIndexId: json.readInt(const ['first_index_id', 'firstIndexId']),
        crowd: MusicCrowd.fromJson(json.readMap(const ['crowd']) ?? const {}),
      );
}

/// 歌手页「收录专辑」横向卡片
class ArtistAlbumItem {
  final String name;
  final String coverPath;
  final String year;
  final int indexCount;

  const ArtistAlbumItem({
    required this.name,
    required this.coverPath,
    required this.year,
    required this.indexCount,
  });

  factory ArtistAlbumItem.fromJson(Map<String, dynamic> json) =>
      ArtistAlbumItem(
        name: json.readString(const ['name']).trim(),
        coverPath: json.readString(const ['cover_path', 'coverPath']),
        year: json.readString(const ['year']),
        indexCount: json.readInt(const ['index_count', 'indexCount']),
      );
}

/// 歌手详情头部
class ArtistDetailInfo {
  final bool found;
  final String name;
  final String coverPath;
  final int trackCount;
  final int albumCount;
  final int totalDuration;
  final String genre;
  final List<ArtistAlbumItem> albums;
  final MusicCrowd crowd;

  const ArtistDetailInfo({
    required this.found,
    required this.name,
    required this.coverPath,
    required this.trackCount,
    required this.albumCount,
    required this.totalDuration,
    required this.genre,
    required this.albums,
    required this.crowd,
  });

  const ArtistDetailInfo.empty()
    : found = false,
      name = '',
      coverPath = '',
      trackCount = 0,
      albumCount = 0,
      totalDuration = 0,
      genre = '',
      albums = const <ArtistAlbumItem>[],
      crowd = const MusicCrowd.empty();

  factory ArtistDetailInfo.fromJson(Map<String, dynamic> json) =>
      ArtistDetailInfo(
        found: json.readBool(const ['found']),
        name: json.readString(const ['name']),
        coverPath: json.readString(const ['cover_path', 'coverPath']),
        trackCount: json.readInt(const ['track_count', 'trackCount']),
        albumCount: json.readInt(const ['album_count', 'albumCount']),
        totalDuration: json.readInt(const ['total_duration', 'totalDuration']),
        genre: json.readString(const ['genre']),
        albums: json
            .readList(const ['albums'], ArtistAlbumItem.fromJson)
            .where((a) => a.name.isNotEmpty)
            .toList(),
        crowd: MusicCrowd.fromJson(json.readMap(const ['crowd']) ?? const {}),
      );
}

/// Last.fm 配置与绑定状态（设置页）
class LastfmConfig {
  final bool configured;
  final String apiKeyMasked;

  /// Secret 只在服务端参与签名，客户端只知道「填没填」
  final bool secretConfigured;

  /// 当前用户是否已授权（拿到 session key）
  final bool linked;
  final String username;

  const LastfmConfig({
    required this.configured,
    required this.apiKeyMasked,
    this.secretConfigured = false,
    this.linked = false,
    this.username = '',
  });

  factory LastfmConfig.fromJson(Map<String, dynamic> json) => LastfmConfig(
    configured: json.readBool(const ['configured']),
    apiKeyMasked: json.readString(const ['api_key_masked', 'apiKeyMasked']),
    secretConfigured: json.readBool(const [
      'secret_configured',
      'secretConfigured',
    ]),
    linked: json.readBool(const ['linked']),
    username: json.readString(const ['username']),
  );
}

/// 绑定流程的返回（`link/complete`）
class LastfmLinkResult {
  final bool ok;
  final String message;
  final String username;

  const LastfmLinkResult({
    required this.ok,
    required this.message,
    this.username = '',
  });

  factory LastfmLinkResult.fromJson(Map<String, dynamic> json) =>
      LastfmLinkResult(
        ok: json.readBool(const ['ok']),
        message: json.readString(const ['reason']),
        username: json.readString(const ['username']),
      );
}

/// Last.fm 连通性测试结果
class LastfmTestResult {
  final bool ok;
  final String message;
  final List<String> samples;

  const LastfmTestResult({
    required this.ok,
    required this.message,
    required this.samples,
  });

  factory LastfmTestResult.fromJson(Map<String, dynamic> json) =>
      LastfmTestResult(
        ok: json.readBool(const ['ok']),
        message: json.readString(const ['message', 'reason']),
        samples: json.readStringList(const ['samples']),
      );
}
