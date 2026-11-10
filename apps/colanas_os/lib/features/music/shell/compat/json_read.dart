/// 音乐壳内部的 JSON 取值工具。
///
/// 移植过来的模型以前每处都写一遍 `(json['x'] as num?)?.toInt() ?? 0`，
/// 同一个字段还要兼容 `snake_case` 与 `camelCase` 两套键，解析闭包散落在
/// 每个 `fromJson` 里 —— 改一个字段要翻十几处，也容易两侧不同步。
///
/// 这里收口成一套带默认值语义的读取器：键按优先级传（`pick(['file_hash', 'fileHash'])`），
/// 类型转换统一兜底（字符串数字也能读）。**只做读取，不做业务判断**，
/// 缺失值一律走调用方给的 fallback，避免模型层出现隐式默认值。
library;

extension JsonReader on Map<String, dynamic> {
  /// 按优先级取第一个非 null 的键；全空返回 null
  Object? pick(List<String> keys) {
    for (final key in keys) {
      final value = this[key];
      if (value != null) return value;
    }
    return null;
  }

  String readString(List<String> keys, {String fallback = ''}) {
    final value = pick(keys);
    if (value == null) return fallback;
    return value is String ? value : value.toString();
  }

  String? readStringOrNull(List<String> keys) {
    final value = pick(keys);
    if (value == null) return null;
    return value is String ? value : value.toString();
  }

  int readInt(List<String> keys, {int fallback = 0}) =>
      readIntOrNull(keys) ?? fallback;

  int? readIntOrNull(List<String> keys) {
    final value = pick(keys);
    if (value == null) return null;
    if (value is num) return value.toInt();
    if (value is String) return num.tryParse(value.trim())?.toInt();
    return null;
  }

  /// `true` / `1` / `"1"` / `"true"` 都算真；其余算假
  bool readBool(List<String> keys, {bool fallback = false}) {
    final value = pick(keys);
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value.toString().trim().toLowerCase();
    return text == 'true' || text == '1';
  }

  Map<String, dynamic>? readMap(List<String> keys) {
    final value = pick(keys);
    return value is Map ? value.cast<String, dynamic>() : null;
  }

  /// 字符串数组：去空白、去空串、去 null 项
  List<String> readStringList(List<String> keys) {
    final value = pick(keys);
    if (value is! List) return const <String>[];
    final out = <String>[];
    for (final item in value) {
      if (item == null) continue;
      final text = item.toString().trim();
      if (text.isNotEmpty) out.add(text);
    }
    return out;
  }

  /// `Map` 数组 → 模型列表；非法项直接丢弃，不抛
  List<T> readList<T>(
    List<String> keys,
    T Function(Map<String, dynamic> json) parse,
  ) {
    final value = pick(keys);
    if (value is! List) return const [];
    final out = <T>[];
    for (final item in value) {
      if (item is Map) out.add(parse(item.cast<String, dynamic>()));
    }
    return out;
  }
}
