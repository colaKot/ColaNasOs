import 'package:colanas_os/core/video_subtitle_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';

VideoSubtitleFile sub(String name, String? lang) =>
    VideoSubtitleFile(name: name, lang: lang, format: 'srt', size: 1);

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
}