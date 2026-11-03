/// 展示格式化（纯 Dart，页面与测试共用）：时长 / 字节 / 时间。
library;

String _two(int v) => v.toString().padLeft(2, '0');

/// 毫秒 → `m:ss` 或 `h:mm:ss`
String formatDurationMs(int ms) {
  final total = ms ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '$m:${_two(s)}';
}

/// 毫秒 → 紧凑形式：`45s` / `12m` / `1h23m`
String formatDurationBrief(int ms) {
  final total = ms ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  if (h > 0) return '${h}h${m}m';
  if (m > 0) return '${m}m';
  return '${total}s';
}

/// 字节 → 人类可读（1 位小数）
String formatBytes(int bytes) {
  if (bytes < 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  final digits = i == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[i]}';
}

/// epoch 秒 → `yyyy-MM-dd HH:mm`
String formatDateTimeSec(int seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  return '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// epoch 秒 → `yyyy-MM-dd`
String formatDateSec(int seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}
