import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'settings_store.dart';

/// 一个「文件 App 快捷目录」：收藏或最近访问。
///
/// 只存 [path] 与 [name] 就够了 —— 目录可能被改名/删除，
/// 所以点开前一律重新 `files/list` 探测，失败就提示并从列表里清掉。
@immutable
class FileShortcut {
  const FileShortcut({required this.path, required this.name});

  /// 完整路径（`/downloads`、`C:/Users`、`//host/share/xx` 都可能）
  final String path;
  final String name;

  Map<String, dynamic> toJson() => {'path': path, 'name': name};

  static FileShortcut? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final name = raw['name'];
    return FileShortcut(
      path: path,
      name: name is String && name.isNotEmpty ? name : path,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FileShortcut && other.path == path && other.name == name;

  @override
  int get hashCode => Object.hash(path, name);
}

/// 文件 App 的「收藏」与「最近访问」。
///
/// **只存本机**（`SettingsStore`：桌面/移动写 settings.json，Web 写 localStorage）。
/// 为什么不是服务端：这两份是「这台设备上的使用习惯」，服务端目前也没有对应表；
/// 将来要做多端同步，只换掉这里的读写实现即可，调用方不用动。
class FileShortcuts extends ChangeNotifier {
  FileShortcuts._();

  static final FileShortcuts instance = FileShortcuts._();

  static const String _favoritesKey = 'files.favorites';
  static const String _recentKey = 'files.recent';

  /// 最近访问最多留这么多条（再多也没人往下翻，且要占设置文件体积）
  static const int recentLimit = 20;

  List<FileShortcut> _favorites = const [];
  List<FileShortcut> _recent = const [];
  bool _loaded = false;

  List<FileShortcut> get favorites => _favorites;
  List<FileShortcut> get recent => _recent;
  bool get hasFavorites => _favorites.isNotEmpty;
  bool get hasRecent => _recent.isNotEmpty;

  /// 首次读取时从 [SettingsStore] 反序列化；重复调用无副作用。
  void ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    _favorites = _decode(SettingsStore.instance.getString(_favoritesKey));
    _recent = _decode(SettingsStore.instance.getString(_recentKey));
  }

  /// 测试用：丢掉内存态，下次读盘（快照 → 反序列化 的往返测试要靠它）
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    _favorites = const [];
    _recent = const [];
  }

  bool isFavorite(String path) => _favorites.any((f) => f.path == path);

  /// 收藏 / 取消收藏；返回操作后是否处于收藏态（调用方据此出提示）
  Future<bool> toggleFavorite(FileShortcut shortcut) async {
    ensureLoaded();
    final exists = isFavorite(shortcut.path);
    // 收藏是「先加的排前面」，与最近访问一致，用户刚操作的那条总在最上面
    _favorites = exists
        ? [for (final f in _favorites) if (f.path != shortcut.path) f]
        : [shortcut, ..._favorites.where((f) => f.path != shortcut.path)];
    notifyListeners();
    await SettingsStore.instance.setString(
      _favoritesKey,
      jsonEncode([for (final f in _favorites) f.toJson()]),
    );
    return !exists;
  }

  /// 记一次目录访问（同一个路径只留最近一次，列表头插、超长截断）
  Future<void> recordRecent(FileShortcut shortcut) async {
    ensureLoaded();
    if (shortcut.path.isEmpty || shortcut.path == '/') return;
    if (_recent.isNotEmpty && _recent.first.path == shortcut.path) return;
    _recent = [
      shortcut,
      ..._recent.where((f) => f.path != shortcut.path),
    ].take(recentLimit).toList();
    notifyListeners();
    await SettingsStore.instance.setString(
      _recentKey,
      jsonEncode([for (final f in _recent) f.toJson()]),
    );
  }

  /// 目录已经不存在时把它从两份列表里都摘掉（点开失败时调用）
  Future<void> forget(String path) async {
    ensureLoaded();
    final fav = _favorites.where((f) => f.path != path).toList();
    final rec = _recent.where((f) => f.path != path).toList();
    if (fav.length == _favorites.length && rec.length == _recent.length) return;
    _favorites = fav;
    _recent = rec;
    notifyListeners();
    await SettingsStore.instance.setString(
      _favoritesKey,
      jsonEncode([for (final f in _favorites) f.toJson()]),
    );
    await SettingsStore.instance.setString(
      _recentKey,
      jsonEncode([for (final f in _recent) f.toJson()]),
    );
  }

  Future<void> clearRecent() async {
    ensureLoaded();
    if (_recent.isEmpty) return;
    _recent = const [];
    notifyListeners();
    await SettingsStore.instance.setString(_recentKey, null);
  }

  List<FileShortcut> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final e in list) ?FileShortcut.fromJson(e),
      ];
    } catch (_) {
      // 存坏了就当没有，别让文件页起不来
      return const [];
    }
  }
}
