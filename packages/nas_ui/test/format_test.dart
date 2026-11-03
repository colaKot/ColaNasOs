import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

void main() {
  test('时长：分秒与时分秒', () {
    expect(formatDurationMs(0), '0:00');
    expect(formatDurationMs(9000), '0:09');
    expect(formatDurationMs(125000), '2:05');
    expect(formatDurationMs(3725000), '1:02:05');
  });

  test('时长紧凑形式', () {
    expect(formatDurationBrief(45000), '45s');
    expect(formatDurationBrief(12 * 60 * 1000), '12m');
    expect(formatDurationBrief(83 * 60 * 1000), '1h23m');
  });

  test('字节格式化', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(formatBytes(-1), '0 B');
  });

  test('时间格式化（本地时区）', () {
    final d = DateTime(2024, 1, 2, 3, 4, 5);
    final sec = d.millisecondsSinceEpoch ~/ 1000;
    expect(formatDateTimeSec(sec), '2024-01-02 03:04');
    expect(formatDateSec(sec), '2024-01-02');
  });
}