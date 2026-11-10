import 'package:flutter/widgets.dart';

/// 影视三级页的一项（影片详情 / 剧集详情都是一个 entry）。
///
/// 为什么不 `Navigator.push`：那样会盖住左侧一二级栏，和音乐模块改造后的
/// 交互不一致（用户 2026-11-09 明确要求：除播放器外不要再有全屏页）。
/// 这里用「纯状态栈 + 外壳叠层」，返回走 `SubPageScope` → `ShellBack`。
///
/// 用 [ValueNotifier] 而不是 GetX：影视模块没有引入 GetX（音乐壳才有），
/// 没必要为一个栈拉一整套状态管理进来。
///
/// 栈里存的是「怎么建这一页」（[build]），不是具体页面类型 ——
/// 影片详情与剧集详情的入参完全不同，外壳不该关心这些细节。
class VideoDetailEntry {
  const VideoDetailEntry({required this.tag, required this.build});

  /// 去重键，例如 `video:123` / `series:进击的巨人`。
  /// 同一 key 重复 open 不叠加（避免连点两下压两层）。
  final String tag;

  /// 三级页的构造器。外壳负责套 `SubPageScope` / 背景 / key。
  final WidgetBuilder build;
}

class VideoDetailRouter {
  VideoDetailRouter._();

  static final VideoDetailRouter instance = VideoDetailRouter._();

  final List<VideoDetailEntry> _stack = <VideoDetailEntry>[];

  /// 栈变化时自增，外壳用 `ValueListenableBuilder` 监听
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 影视壳是否已挂载。没挂载时（比如从桌面卡片直接开详情）
  /// 调用方要退回 `Navigator.push` 整页。
  bool attached = false;

  /// 影视壳自己所在的 `ModalRoute`（外壳在 didChangeDependencies 里登记）。
  ///
  /// 作用：判断调用方**是不是还在内容区**。影视模块仍有几处整页 push
  /// （合集详情 / 智能相册 / 媒体查看器 / 人物作品列表），在那些页面里点条目时
  /// 如果照旧往三级栈塞，详情会被整页路由盖住 —— 表现为「点了没反应」。
  /// 只有调用方的 route 与外壳一致（= 在内容区）才允许叠层。
  Route<dynamic>? shellRoute;

  /// 日本电影库的 id 集合（外壳加载完库列表后登记）。
  ///
  /// 影视详情页的「演职人员」点下去，日本库要进**日本演员页**（有身高 / 三围 / 生日），
  /// 普通库才进「某人的作品」。`VideoItem` 里只有 `libraryId`、没有库类型，
  /// 所以由外壳把 jp 库 id 报上来，详情页按 id 判断。
  Set<String> jpLibraryIds = const <String>{};

  bool isJpLibrary(String? libraryId) =>
      libraryId != null && jpLibraryIds.contains(libraryId);

  VideoDetailEntry? get top => _stack.isEmpty ? null : _stack.last;

  bool get active => _stack.isNotEmpty;

  int get depth => _stack.length;

  /// 调用方是否处在影视壳的内容区（= 可以叠三级页）。
  ///
  /// 整页 push 出来的页面（route 与外壳不同）一律返回 false，让调用方走整页详情，
  /// 否则详情会叠在被盖住的内容区里、看着像没反应。
  bool embeddableFrom(BuildContext context) {
    if (!attached) return false;
    final route = ModalRoute.of(context);
    final shell = shellRoute;
    if (route == null || shell == null) return true;
    return identical(route, shell);
  }

  void open(VideoDetailEntry entry) {
    final current = top;
    if (current != null && current.tag == entry.tag) return;
    _stack.add(entry);
    revision.value += 1;
  }

  void back() {
    if (_stack.isEmpty) return;
    _stack.removeLast();
    revision.value += 1;
  }

  void closeAll() {
    if (_stack.isEmpty) return;
    _stack.clear();
    revision.value += 1;
  }

  /// 外壳销毁时清栈：**不发通知**。
  ///
  /// `dispose` 阶段 `revision` 的监听者（外壳里的 `ValueListenableBuilder`）可能
  /// 还没摘掉，此时 `revision.value++` 会让它在已 dispose 的 State 上 `setState`。
  /// 清干净数据就够，界面反正要没了。
  void reset() {
    _stack.clear();
  }
}
