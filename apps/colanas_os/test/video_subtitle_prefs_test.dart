import 'package:colanas_os/core/video_subtitle_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';

VideoSubtitleFile sub(String name, String? lang) =>
    VideoSubtitleFile(name: name, lang: lang, format: 'srt', size: 1);

VideoSubtitleCue cue(int start, int end, String text) =>
    VideoSubtitleCue(startMs: start, endMs: end, text: text);

void main() {
  test('关闭字幕返回 null', () {
    expect(
      pickSubtitle([sub('a.zh.srt', 'zh'), sub('a.en.srt', 'en')], VideoSubtitlePrefs.off),
      isNull,
    );
  });

  test('自动返回第一条', () {
    final items = [sub('a.zh.srt', 'zh'), sub('a.en.srt', 'en')];
    expect(pickSubtitle(items, VideoSubtitlePrefs.auto), items.first);
  });

  test('语言标签前缀匹配（zh 命中 zh-CN）', () {
    final items = [sub('a.en.srt', 'en'), sub('a.zh-CN.srt', 'zh-CN')];
    expect(pickSubtitle(items, 'zh')!.name, 'a.zh-CN.srt');
    expect(pickSubtitle(items, 'en')!.name, 'a.en.srt');
  });

  test('偏好语言没有字幕时回退第一条', () {
    final items = [sub('a.en.srt', 'en'), sub('a.zh.srt', 'zh')];
    expect(pickSubtitle(items, 'ja')!.name, 'a.en.srt');
  });

  test('空列表返回 null', () {
    expect(pickSubtitle(const [], 'zh'), isNull);
  });

  test('没有语言标签的字幕不参与匹配', () {
    final items = [sub('plain.srt', null), sub('a.en.srt', 'en')];
    expect(pickSubtitle(items, 'zh')!.name, 'plain.srt');
    expect(pickSubtitle(items, 'en')!.name, 'a.en.srt');
  });

  group('activeSubtitleText', () {
    test('只在区间内显示，起止边界为左闭右开', () {
      final cues = [cue(1000, 3000, '第一句')];
      expect(activeSubtitleText(cues, 999), '');
      expect(activeSubtitleText(cues, 1000), '第一句');
      expect(activeSubtitleText(cues, 2999), '第一句');
      expect(activeSubtitleText(cues, 3000), '');
    });

    test('重叠 cue 按文件顺序换行合并', () {
      final cues = [
        cue(1000, 3000, '第一行'),
        cue(1200, 2600, '第二行'),
        cue(4000, 5000, '下一句'),
      ];
      expect(activeSubtitleText(cues, 2000), '第一行\n第二行');
      expect(activeSubtitleText(cues, 4500), '下一句');
    });

    test('空文本与空列表不显示', () {
      expect(activeSubtitleText(const [], 1000), '');
      expect(activeSubtitleText([cue(0, 5000, '   ')], 1000), '');
    });

    test('乱序 cue 也能取到', () {
      final cues = [cue(4000, 5000, '后'), cue(0, 2000, '先')];
      expect(activeSubtitleText(cues, 1000), '先');
      expect(activeSubtitleText(cues, 4500), '后');
    });
  });
}