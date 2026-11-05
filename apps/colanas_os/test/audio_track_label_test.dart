import 'package:colanas_os/core/audio_track_label.dart';
import 'package:flutter_test/flutter_test.dart';

/// 《匹诺曹》的真实 ffprobe 输出（3 条音轨），用来钉住菜单文案。
void main() {
  group('audioTrackLabel：音轨菜单要能看出是哪条语言', () {
    test('标题优先：英语 TrueHD 7.1', () {
      expect(
        audioTrackLabel(
          ordinal: 0,
          language: 'eng',
          title: '英语',
          codec: 'truehd',
          channelLayout: '7.1',
          channels: 8,
        ),
        '1 · 英语 · TrueHD 7.1',
      );
    });

    test('同一语言有两条时靠标题区分（上海领声国语 / 台配国语）', () {
      String label(int i, String title) => audioTrackLabel(
            ordinal: i,
            language: 'chi',
            title: title,
            codec: 'ac3',
            channelLayout: '5.1(side)',
            channels: 6,
          );
      expect(label(1, '上海领声国语'), '2 · 上海领声国语 · AC3 5.1');
      expect(label(2, '台配国语'), '3 · 台配国语 · AC3 5.1');
    });

    test('没有标题时按语言代码查表', () {
      expect(
        audioTrackLabel(ordinal: 0, language: 'jpn', codec: 'flac', channels: 2),
        '1 · 日本語 · FLAC 2ch',
      );
    });

    test('ISO 639-1 与 639-2 都认', () {
      expect(audioTrackLabel(ordinal: 0, language: 'zh'), startsWith('1 · 中文'));
      expect(audioTrackLabel(ordinal: 0, language: 'chi'), startsWith('1 · 中文'));
    });

    test('语言和标题都没有时只留序号与编码，不硬编「未知语言」', () {
      expect(
        audioTrackLabel(ordinal: 3, codec: 'eac3', channels: 6),
        '4 · E-AC3 6ch',
      );
    });

    test('什么都不给也不炸，至少有序号', () {
      expect(audioTrackLabel(ordinal: 0), '1');
    });

    test('5.1(side) 的括号部分不显示', () {
      expect(
        audioTrackLabel(ordinal: 0, title: 'x', codec: 'ac3', channelLayout: '5.1(side)'),
        '1 · x · AC3 5.1',
      );
    });
  });
}
