import 'package:colanas_os/core/play_quality.dart';
import 'package:colanas_os/core/play_quality_scope.dart';
import 'package:flutter_test/flutter_test.dart';

/// 档位文案 + 档位 × 片源收敛。
///
/// 这两块都是纯函数，也最容易在改动档位表时悄悄坏掉：
///   - 文案：以前是 `label` + 码率两段拼，现在合成 `1080P 0.9Mbps`；
///   - 收敛：片源只有 720p 时不能列出 1080P，也不能把用户选的 0.9M 悄悄抬到 3.8M。
void main() {
  group('labelFor 只显示一个码率', () {
    test('1080p_2m 在 AV1 下是 1080P 0.9Mbps', () {
      expect(playQualityPresetOf('1080p_2m')!.labelFor('av1'), '1080P 0.9Mbps');
      expect(playQualityPresetOf('1080p_2m')!.labelFor('h264'), '1080P 2Mbps');
    });

    test('整兆不带小数：4K AV1 = 4K 7Mbps，H.264 = 4K 15Mbps', () {
      expect(playQualityPresetOf('2160p_15m')!.labelFor('av1'), '4K 7Mbps');
      expect(playQualityPresetOf('2160p_15m')!.labelFor('h264'), '4K 15Mbps');
    });

    test('原画不显示码率（不转码，码率无意义）', () {
      expect(playQualityPresetOf('original')!.labelFor('av1'), '原画');
      expect(playQualityPresetOf('original')!.bitrateLabelFor('av1'), '不转码');
    });

    test('codec 认不出时回落到 H.264 的码率', () {
      expect(playQualityPresetOf('720p_1m')!.labelFor('vp9'), '720P 1Mbps');
    });
  });

  group('presetsForSource 只列片源转得出来的档', () {
    test('720p 片源没有 1080P / 2K / 4K', () {
      final keys = presetsForSource(720).map((p) => p.key).toList();
      expect(keys.first, 'original');
      expect(keys, contains('720p_3m'));
      expect(keys, contains('480p_1m'));
      expect(keys.any((k) => k.startsWith('1080p')), isFalse);
      expect(keys.any((k) => k.startsWith('1440p')), isFalse);
      expect(keys.any((k) => k.startsWith('2160p')), isFalse);
    });

    test('2160p 片源全量可选', () {
      expect(presetsForSource(2160).length, playQualityPresets.length);
    });

    test('裁边的 4K 片源（3840x2076）仍然能选 4K 档', () {
      // 《匹诺曹》这类宽银幕 4K 片扫描高度是 2076，严格按 <= 过滤会把 4K 档切掉
      final keys = presetsForSource(2076).map((p) => p.key).toList();
      expect(keys, contains('2160p_15m'));
      expect(clampPresetForSource('2160p_15m', 2076, codec: 'av1'), '2160p_15m');
      expect(maxPresetHeightForSource(2076), 2160);
    });

    test('高度未知时退回全量，别把菜单砍空', () {
      expect(presetsForSource(0).length, playQualityPresets.length);
      expect(presetsForSource(-1).length, playQualityPresets.length);
    });

    test('片源比最低档还矮时仍留一个转码档', () {
      final list = presetsForSource(240);
      expect(list.first.key, 'original');
      expect(list.where((p) => !p.copy), isNotEmpty);
    });

    test('maxPresetHeightForSource', () {
      expect(maxPresetHeightForSource(720), 720);
      expect(maxPresetHeightForSource(1080), 1080);
      expect(maxPresetHeightForSource(0), 2160);
    });
  });

  group('码率文案：源码率也用同一套写法', () {
    test('mbpsLabel 带单位、拿不到时给破折号', () {
      expect(mbpsLabel(19600), '19.6 Mbps');
      expect(mbpsLabel(1400), '1.4 Mbps');
      expect(mbpsLabel(0), '—');
    });

    test('源码率 = 字节 × 8 ÷ 时长（匹诺曹 17.2GB / 117min ≈ 19.7Mbps）', () {
      final kbps = sourceKbpsOf(17245608381, 117 * 60 * 1000);
      expect(kbps, inInclusiveRange(19400, 19800));
      expect(mbpsLabel(kbps), '19.7 Mbps');
    });

    test('缺 size / 时长时返回 0，不显示 0 Mbps', () {
      expect(sourceKbpsOf(0, 1000), 0);
      expect(sourceKbpsOf(1000, 0), 0);
    });
  });

  group('clampPresetForSource 按片源收敛偏好档位', () {
    test('片源够高时原样保留（尊重用户，不多花流量）', () {
      expect(clampPresetForSource('1080p_2m', 1080, codec: 'av1'), '1080p_2m');
      expect(clampPresetForSource('2160p_15m', 2160, codec: 'av1'), '2160p_15m');
    });

    test('原画永远原样返回', () {
      expect(clampPresetForSource('original', 480), 'original');
    });

    test('1080p 偏好落到 720p 片源：留在同一流量档（AV1 仍是 0.9M）', () {
      expect(clampPresetForSource('1080p_2m', 720, codec: 'av1'), '720p_2m');
      expect(
        playQualityPresetOf(clampPresetForSource('1080p_2m', 720, codec: 'av1'))!
            .labelFor('av1'),
        '720P 0.9Mbps',
      );
    });

    test('4K 偏好落到 1080p 片源：取 1080P 里最接近的档，不越界', () {
      final key = clampPresetForSource('2160p_15m', 1080, codec: 'av1');
      expect(key, '1080p_8m');
      expect(playQualityPresetOf(key)!.height, 1080);
    });

    test('偏好档位低于片源高度时不动（只往上贴不上去）', () {
      expect(clampPresetForSource('480p_1m', 1080), '480p_1m');
    });

    test('片源高度未知时不收敛', () {
      expect(clampPresetForSource('2160p_15m', 0), '2160p_15m');
    });

    test('未知档位原样返回（调用方自己兜底）', () {
      expect(clampPresetForSource('nope', 720), 'nope');
    });
  });
}
