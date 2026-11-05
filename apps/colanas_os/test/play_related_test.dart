import 'package:colanas_os/core/play_related.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('relatedBasename / relatedDir', () {
    test('去掉扩展名，兼容反斜杠路径', () {
      expect(relatedBasename('影库/abd-121-cd1.mkv'), 'abd-121-cd1');
      expect(relatedBasename(r'D:\影库\abd-121-cd2.mp4'), 'abd-121-cd2');
      expect(relatedDir('影库/分卷/abd-121-cd1.mkv'), '影库/分卷');
      expect(relatedDir('abd-121-cd1.mkv'), '');
    });

    test('多点文件名只去掉最后一段扩展名', () {
      expect(relatedBasename('a.b.c.mkv'), 'a.b.c');
      expect(relatedBasename('Movie.Part2.2020.BluRay'), 'Movie.Part2.2020');
    });
  });

  group('relatedPrefix：从文件名推出同组前缀', () {
    test('cd 分卷保留标记', () {
      final p = relatedPrefix('abd-121-cd1');
      expect(p, 'abd-121-cd');
      expect(relatedMatches(p!, 'abd-121-cd2'), isTrue);
      expect(relatedMatches(p, 'abd-121-cd3'), isTrue);
    });

    test('纯数字分卷保留分隔符，避免误收相邻番号', () {
      final p = relatedPrefix('abd-121-1');
      expect(p, 'abd-121-');
      expect(relatedMatches(p!, 'abd-121-2'), isTrue);
      // 别把 abd-1210-1 当成同一部（分隔符挡住了）
      expect(relatedMatches(p, 'abd-1210-1'), isFalse);
    });

    test('Part / Disc / 点分隔', () {
      final p = relatedPrefix('Movie.Part2');
      expect(p, 'movie.part');
      expect(relatedMatches(p!, 'Movie.Part10'), isTrue);
      expect(relatedPrefix('Movie Disc 1'), 'movie disc ');
    });

    test('中文「第 N 部」', () {
      final p = relatedPrefix('大话西游 第 1 部');
      expect(p, '大话西游 ');
      expect(relatedMatches(p!, '大话西游 第 2 部'), isTrue);
    });

    test('没有分卷号 / 前缀太短：不生成播放列表', () {
      expect(relatedPrefix('Pinocchio.2022.1080p'), isNull);
      expect(relatedPrefix('A-1'), isNull);
      expect(relatedPrefix('1'), isNull);
    });

    test('同前缀但结尾不是序号（花絮 / 预告）不算同组', () {
      final p = relatedPrefix('abd-121-cd1')!;
      expect(relatedMatches(p, 'abd-121-cd1-花絮'), isFalse);
      expect(relatedMatches(p, 'abd-121-cd2-预告'), isFalse);
    });

    test('大小写不敏感', () {
      final p = relatedPrefix('ABD-121-CD1')!;
      expect(relatedMatches(p, 'abd-121-cd2'), isTrue);
    });
  });

  group('compareRelatedNames：自然序', () {
    test('cd2 排在 cd10 前面', () {
      final names = ['abd-121-cd10', 'abd-121-cd2', 'abd-121-cd1'];
      names.sort(compareRelatedNames);
      expect(names, ['abd-121-cd1', 'abd-121-cd2', 'abd-121-cd10']);
    });

    test('纯数字分卷同理', () {
      final names = ['abd-121-10', 'abd-121-2', 'abd-121-1'];
      names.sort(compareRelatedNames);
      expect(names, ['abd-121-1', 'abd-121-2', 'abd-121-10']);
    });

    test('中文分卷号也能排序', () {
      final names = ['大话西游 第 2 部', '大话西游 第 1 部'];
      names.sort(compareRelatedNames);
      expect(names.first, '大话西游 第 1 部');
    });
  });
}
