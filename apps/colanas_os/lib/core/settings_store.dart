import 'dart:convert';

import 'settings_backend_io.dart'
    if (dart.library.js_interop) 'settings_backend_web.dart' as backend;

/// 客户端本地设置存储（JSON 快照）。
///
/// - 桌面 / 移动：写到 `getApplicationSupportDirectory()/settings.json`；
/// - **Web：写入浏览器 localStorage**（键 `colanas.settings`），刷新与重开标签页都保留。
///
/// 自动登录依赖这里的 `auth.server / auth.username / auth.token`，Web 端不再「仅本次会话」。
/// 所有写入失败都吞掉：设置项丢了不该让应用起不来。
class SettingsStore {
  SettingsStore._();

  static final SettingsStore instance = SettingsStore._();

  final Map<String, dynamic> _data = <String, dynamic>{};

  /// 是否已走完 [load]：未初始化时只更新内存（widget 测试不落盘，也不会卡在插件通道上）
  bool _active = false;

  /// 当前平台是否真的落盘（设置页据此提示「仅本次会话」）
  bool get persistent => backend.persistent;

  Future<void> load() async {
    try {
      final raw = await backend.readAll();
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _data
            ..clear()
            ..addAll(decoded);
        }
      }
    } catch (_) {
      // 内容损坏：按空设置启动，避免整页起不来
    }
    _active = true;
  }

  String? getString(String key) {
    final value = _data[key];
    return value is String ? value : null;
  }

  bool? getBool(String key) {
    final value = _data[key];
    return value is bool ? value : null;
  }

  int? getInt(String key) {
    final value = _data[key];
    return value is int ? value : null;
  }

  Future<void> setString(String key, String? value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    await _flush();
  }

  Future<void> setBool(String key, bool? value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    await _flush();
  }

  Future<void> setInt(String key, int? value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    await _flush();
  }

  Future<void> _flush() async {
    if (!_active) return;
    await backend.writeAll(jsonEncode(_data));
  }
}