import '../../compat/json_read.dart';

/// 后端同一字段存在 snake_case / camelCase 两套键，这里集中声明，
/// `MusicSource.fromJson` 只引用常量，避免逐个字段重复拼键数组。
const _kId = <String>['id'];
const _kPath = <String>['path'];
const _kExists = <String>['exists'];
const _kScanWhenStart = <String>['scan_when_start', 'scanWhenStart'];
const _kScanWhenChange = <String>['scan_when_change', 'scanWhenChange'];
const _kIsShow = <String>['is_show', 'isShow'];
const _kShowType = <String>['show_type', 'showType'];
const _kCtime = <String>['ctime'];
const _kScanInterval = <String>['scan_interval', 'scanInterval'];
const _kScanIntervalMs = <String>['scan_interval_ms', 'scanIntervalMs'];
const _kScanIntervalConfig = <String>[
  'scan_interval_config',
  'scanIntervalConfig',
];
const _kLastScanTime = <String>['last_scan_time', 'lastScanTime'];

/// 取值方式：把 `fromJson` 里散落的 readX 调用收成一张键表，
/// 循环读取时按 kind 分派到对应的 JsonReader 方法（含各自兜底）。
enum _ReadKind { asInt, intOne, boolTrue, asString, nullableString }

class _FieldSpec {
  const _FieldSpec(this.keys, this.kind);

  final List<String> keys;
  final _ReadKind kind;

  dynamic read(Map<String, dynamic> json) {
    if (kind == _ReadKind.asInt) return json.readInt(keys);
    if (kind == _ReadKind.intOne) return json.readInt(keys, fallback: 1);
    if (kind == _ReadKind.boolTrue) return json.readBool(keys, fallback: true);
    if (kind == _ReadKind.asString) return json.readString(keys);
    return json.readStringOrNull(keys);
  }
}

/// 字段名 -> 读取规则。fromJson 与 copyWith 共用同一套字段名，
/// 由 [_fromValues] 把 Map 落回强类型构造参数。
const _kFields = <String, _FieldSpec>{
  'id': _FieldSpec(_kId, _ReadKind.asInt),
  'path': _FieldSpec(_kPath, _ReadKind.asString),
  'exists': _FieldSpec(_kExists, _ReadKind.boolTrue),
  'scanWhenStart': _FieldSpec(_kScanWhenStart, _ReadKind.asInt),
  'scanWhenChange': _FieldSpec(_kScanWhenChange, _ReadKind.intOne),
  'isShow': _FieldSpec(_kIsShow, _ReadKind.intOne),
  'showType': _FieldSpec(_kShowType, _ReadKind.asString),
  'ctime': _FieldSpec(_kCtime, _ReadKind.nullableString),
  'scanInterval': _FieldSpec(_kScanInterval, _ReadKind.asInt),
  'scanIntervalMs': _FieldSpec(_kScanIntervalMs, _ReadKind.asInt),
  'scanIntervalConfig': _FieldSpec(
    _kScanIntervalConfig,
    _ReadKind.nullableString,
  ),
  'lastScanTime': _FieldSpec(_kLastScanTime, _ReadKind.asInt),
};

/// 从字段名 Map 落回强类型构造；fromJson / copyWith 共用这一处出口。
MusicSource _fromValues(Map<String, dynamic> v) => MusicSource(
  id: v['id'] as int,
  path: v['path'] as String,
  exists: v['exists'] as bool,
  scanWhenStart: v['scanWhenStart'] as int,
  scanWhenChange: v['scanWhenChange'] as int,
  isShow: v['isShow'] as int,
  showType: v['showType'] as String,
  ctime: v['ctime'] as String?,
  scanInterval: v['scanInterval'] as int,
  scanIntervalMs: v['scanIntervalMs'] as int,
  scanIntervalConfig: v['scanIntervalConfig'] as String?,
  lastScanTime: v['lastScanTime'] as int,
);

/// 音乐来源（= 扫描目录）的设置项
///
/// 三个扫描开关都和数据库列一一对应：
/// - `scanWhenStart`：启动时扫一次
/// - `scanWhenChange`：目录变动时增量扫
/// - `scanIntervalMs`：每库独立的间隔扫描周期（0 = 跟随全局校验）
///
/// 旧结构里 `scanInterval`（0/1）和 `scanIntervalMs` 是**冗余**的，前者只是
/// 后者的开关形态；这里保留字段以兼容接口，但判定一律看 `scanIntervalMs`。
class MusicSource {
  final int id;
  final String path;
  final bool exists;
  final int scanWhenStart;
  final int scanWhenChange;
  final int isShow;
  final String showType;
  final String? ctime;
  final int scanInterval;
  final int scanIntervalMs;
  final String? scanIntervalConfig;
  final int lastScanTime;

  const MusicSource({
    required this.id,
    required this.path,
    required this.exists,
    required this.scanWhenStart,
    required this.scanWhenChange,
    required this.isShow,
    required this.showType,
    required this.ctime,
    required this.scanInterval,
    required this.scanIntervalMs,
    required this.scanIntervalConfig,
    required this.lastScanTime,
  });

  factory MusicSource.fromJson(Map<String, dynamic> json) {
    final values = <String, dynamic>{
      for (final entry in _kFields.entries) entry.key: entry.value.read(json),
    };
    // 后端没给 show_type 时按音乐来源处理，否则 UI 会落进未知分支
    if ((values['showType'] as String).isEmpty) {
      values['showType'] = 'music';
    }
    return _fromValues(values);
  }

  /// 间隔扫描是否生效：只看毫秒周期，`scanInterval` 只是它的 0/1 投影
  bool get hasIntervalScan => scanIntervalMs > 0;

  bool get scanOnStart => scanWhenStart != 0;

  bool get scanOnChange => scanWhenChange != 0;

  MusicSource copyWith({
    String? path,
    bool? exists,
    int? scanWhenStart,
    int? scanWhenChange,
    int? isShow,
    String? showType,
    String? ctime,
    int? scanInterval,
    int? scanIntervalMs,
    String? scanIntervalConfig,
    int? lastScanTime,
  }) {
    // 先把当前值写入 Map，再用「仅非 null」的覆盖 Map 合并；id 不参与覆盖。
    final values = <String, dynamic>{
      'id': id,
      'path': this.path,
      'exists': this.exists,
      'scanWhenStart': this.scanWhenStart,
      'scanWhenChange': this.scanWhenChange,
      'isShow': this.isShow,
      'showType': this.showType,
      'ctime': this.ctime,
      'scanInterval': this.scanInterval,
      'scanIntervalMs': this.scanIntervalMs,
      'scanIntervalConfig': this.scanIntervalConfig,
      'lastScanTime': this.lastScanTime,
    };
    final overrides = <String, Object?>{
      'path': path,
      'exists': exists,
      'scanWhenStart': scanWhenStart,
      'scanWhenChange': scanWhenChange,
      'isShow': isShow,
      'showType': showType,
      'ctime': ctime,
      'scanInterval': scanInterval,
      'scanIntervalMs': scanIntervalMs,
      'scanIntervalConfig': scanIntervalConfig,
      'lastScanTime': lastScanTime,
    };
    for (final entry in overrides.entries) {
      if (entry.value != null) values[entry.key] = entry.value;
    }
    return _fromValues(values);
  }
}
