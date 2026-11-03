import 'package:colanas_os/features/music/music_playback.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放模式是持久化的枚举：读坏时必须回落「不循环」，
/// 否则一个脏设置会让播放器永远停在单曲循环。
void main() {
  test('repeat mode 解析：未知值与 null 都回落 off', () {
    expect(musicRepeatModeOf('all'), MusicRepeatMode.all);
    expect(musicRepeatModeOf('one'), MusicRepeatMode.one);
    expect(musicRepeatModeOf('off'), MusicRepeatMode.off);
    expect(musicRepeatModeOf('loop'), MusicRepeatMode.off);
    expect(musicRepeatModeOf(''), MusicRepeatMode.off);
    expect(musicRepeatModeOf(null), MusicRepeatMode.off);
  });

  test('repeat mode 落盘值可原样读回', () {
    for (final mode in MusicRepeatMode.values) {
      expect(musicRepeatModeOf(musicRepeatModeId(mode)), mode);
    }
  });
}
