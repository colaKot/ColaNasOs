import '../../compat/getx.dart';

/// 三级页面类型：专辑 / 歌手 / 歌单
enum MusicDetailKind { album, artist, playlist }

/// 一次「打开详情页」的目标。
///
/// [artist] 只对专辑有意义：同名专辑（现场版 / 不同歌手翻唱）靠它消歧，
/// 歌手名本身已经是 [name]。
class MusicDetailTarget {
  const MusicDetailTarget({
    required this.kind,
    required this.name,
    this.artist = '',
    this.listId = 0,
  });

  const MusicDetailTarget.album({required this.name, this.artist = ''})
    : kind = MusicDetailKind.album,
      listId = 0;

  const MusicDetailTarget.artist(this.name)
    : kind = MusicDetailKind.artist,
      artist = '',
      listId = 0;

  /// 歌单：`listId` 是 `music_playlists` 的 rowid（接口口径）
  const MusicDetailTarget.playlist({required this.name, required this.listId})
    : kind = MusicDetailKind.playlist,
      artist = '';

  final MusicDetailKind kind;
  final String name;
  final String artist;

  /// 仅歌单用：`music_playlists.rowid`
  final int listId;

  bool get isAlbum => kind == MusicDetailKind.album;
  bool get isArtist => kind == MusicDetailKind.artist;
  bool get isPlaylist => kind == MusicDetailKind.playlist;

  /// 唯一键：同类型的同名目标算同一个页面，不重复压栈
  String get key => switch (kind) {
    MusicDetailKind.album => 'album:$name|$artist',
    MusicDetailKind.artist => 'artist:$name',
    MusicDetailKind.playlist => 'playlist:$listId',
  };
}

/// 音乐模块的**三级页面栈**。
///
/// 为什么不用 `Navigator.push`：用户要求「专辑 / 歌手页要留在右侧内容区，
/// 左侧一二级栏不动」。`Navigator.push` 盖的是整页（连左侧栏一起没了），
/// 所以这里用一个纯状态栈，由 `MusicShellView` 在内容区里叠一层页面。
///
/// 返回入口都指向 [back]：
/// - 顶栏返回按钮（`SubPageScope` 注册到 `ShellBack`，手机 / 桌面都有）；
/// - 桌面宽屏左面板顶部的返回文字按钮。
/// 手机端详情页不再自带返回条：顶栏那条已经够用，避免两个箭头叠在一起。
class MusicDetailRouter extends GetxController {
  static MusicDetailRouter get instance {
    if (!Get.isRegistered<MusicDetailRouter>()) Get.put(MusicDetailRouter());
    return Get.find<MusicDetailRouter>();
  }

  final RxList<MusicDetailTarget> stack = <MusicDetailTarget>[].obs;

  bool get active => stack.isNotEmpty;

  MusicDetailTarget? get top => stack.isEmpty ? null : stack.last;

  void open(MusicDetailTarget target) {
    if (target.name.trim().isEmpty) return;
    final current = top;
    if (current != null && current.key == target.key) return;
    stack.add(target);
  }

  /// 一页一页退（歌手页里打开专辑，退回来还在歌手页）
  void back() {
    if (stack.isEmpty) return;
    stack.removeLast();
  }

  void closeAll() {
    if (stack.isEmpty) return;
    stack.clear();
  }
}
