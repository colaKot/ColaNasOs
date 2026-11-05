import 'package:colanas_os/core/play_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

/// 《匹诺曹》实测数据：库里 7,065,540 ms = 1:57:45，刚起播时 HLS 只转出 1:40。
const _pinocchio = Duration(milliseconds: 7065540);
const _transcoded = Duration(minutes: 1, seconds: 40);

void main() {
  group('timelineDuration：总长恒定，不许跟着转码进度跳', () {
    test('转码中（已转出 1:40 / 整片 1:57:45）显示整片', () {
      expect(
        timelineDuration(reported: _transcoded, source: _pinocchio),
        _pinocchio,
      );
    });

    test('播放列表刷新把 duration 刷成 0 时，数值不跟着变', () {
      // 这就是用户看到「一会 1:40 一会 1:57」的机制：归零那一刻回落，之后又拿回 1:40
      final a = timelineDuration(reported: _transcoded, source: _pinocchio);
      final b = timelineDuration(reported: Duration.zero, source: _pinocchio);
      expect(a, b);
    });

    test('直链播放：片源时长与流报的一致', () {
      expect(
        timelineDuration(reported: _pinocchio, source: _pinocchio),
        _pinocchio,
      );
    });

    test('片源时长未知时才用播放器报的值', () {
      const five = Duration(minutes: 5);
      expect(
        timelineDuration(reported: five, source: Duration.zero),
        five,
      );
    });

    test('两边都没有就是 0（界面显示 --:--）', () {
      expect(
        timelineDuration(reported: Duration.zero, source: Duration.zero),
        Duration.zero,
      );
    });
  });

  group('seekLimit：转码只能跳到已转出的位置', () {
    test('转码中上限 = 已转出长度', () {
      expect(
        seekLimit(
          reported: _transcoded,
          source: _pinocchio,
          isTranscode: true,
        ),
        _transcoded,
      );
    });

    test('刚起播 reported 还是 0 时不要锁死成 0', () {
      expect(
        seekLimit(
          reported: Duration.zero,
          source: _pinocchio,
          isTranscode: true,
        ),
        _pinocchio,
      );
    });

    test('直链播放整片都能跳', () {
      expect(
        seekLimit(
          reported: _pinocchio,
          source: _pinocchio,
          isTranscode: false,
        ),
        _pinocchio,
      );
    });

    test('流转出的长度超过片源时长时以片源为准（元数据不一致兜底）', () {
      const longer = Duration(hours: 2, minutes: 10);
      expect(
        seekLimit(
          reported: longer,
          source: _pinocchio,
          isTranscode: true,
        ),
        _pinocchio,
      );
    });
  });
}
