import 'package:flutter_test/flutter_test.dart';

import 'package:colanas_os/features/music/lyrics_sync.dart';

void main() {
  test('空歌词不高亮', () {
    expect(activeLyricIndex(const [], 1000), -1);
  });

  test('尚未到第一行时不高亮', () {
    expect(activeLyricIndex(const [1000, 2000], 500), -1);
  });

  test('取最后一个不晚于播放位置的行', () {
    const times = [1000, 2000, 3000];
    expect(activeLyricIndex(times, 1000), 0);
    expect(activeLyricIndex(times, 2500), 1);
    expect(activeLyricIndex(times, 9999), 2);
  });

  test('无时间戳的行被忽略', () {
    expect(activeLyricIndex(const [null, 1500, null], 1600), 1);
  });
}
