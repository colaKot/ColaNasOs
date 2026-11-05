import 'play_quality.dart';

/// 档位 × 片源：**片源能转出什么，菜单里就只列什么**。
///
/// 以前不管片源是 720p 还是 4K，菜单一律把 4K / 2K / 1080P / 720P / 480P 全列出来。
/// 选 1080P 去转一部 720p 的片，ffmpeg 只会做一次「放大再压缩」，纯浪费 CPU 和流量；
/// 菜单里那一堆选不动的档位才是真正的噪音。
///
/// 规则（2026-11-05 用户要求）：
///   1. 原画永远在，且永远排第一；
///   2. 只列 `height <= 片源高度` 的转码档 —— 没有 1080p 的片就不显示 1080P；
///   3. 片源高度未知（0）时退回全量列表，别因为查不到元数据就把菜单砍空。
///
/// 注意：这里只做「能选什么」，不做「该选什么」—— 后者见 [clampPresetForSource]。

/// 档位高度对片源高度的容忍度。
///
/// 4K 片源的扫描高度经常不是 2160：匹诺曹是 `3840x2076`，宽银幕片多是 1600 或
/// 2064。严格按 `height <= 片源高度` 过滤会把整部 4K 片的 4K 档一刀切掉，
/// 只能选到 2K —— 那才是真的掉画质。10% 的容差刚好覆盖裁边，又不会让
/// 1080p 片源（1080 × 1.1 = 1188）吃到 1440P。
const double _kHeightSlack = 1.1;

bool _fits(int presetHeight, int sourceHeight) =>
    presetHeight <= sourceHeight * _kHeightSlack;

/// 片源可选的档位（原画 + 不超过片源高度的转码档）。
List<PlayQualityPreset> presetsForSource(int sourceHeight) {
  if (sourceHeight <= 0) return playQualityPresets;
  final allowed = playQualityPresets
      .where((p) => p.copy || _fits(p.height, sourceHeight))
      .toList();
  // 片源比最低档（480P）还矮的怪文件：至少留一个转码档，否则只剩原画，
  // 而原画在这些片源上往往正是「必须转码」（HEVC / HDR）才打不开的那种。
  if (allowed.length <= 1) {
    final fallback = playQualityPresets.where((p) => !p.copy).toList();
    if (fallback.isEmpty) return allowed;
    return [allowed.isEmpty ? fallback.last : allowed.first, fallback.last];
  }
  return allowed;
}

/// 片源实际能到达的最高转码分辨率（没有转码档时返回 0）。
int maxPresetHeightForSource(int sourceHeight) {
  var h = 0;
  for (final p in presetsForSource(sourceHeight)) {
    if (!p.copy && p.height > h) h = p.height;
  }
  return h;
}

/// 把「用户偏好档位」贴到这部片实际能做到的档位上。
///
/// - 片源高度未知、或偏好档位本来就不超过片源 → 原样返回（尊重用户，不多花流量）；
/// - 偏好档位高于片源 → 收敛到片源能到达的最高分辨率，并在该分辨率下挑一个
///   **目标码率最接近**的档位。用户选档位时真正的约束是流量（0.9M 就是 0.9M），
///   分辨率只是片源给的天花板，所以宁可降分辨率也不要把码率悄悄抬上去。
///   例：偏好 `1080p_2m`（AV1 0.9M）落到 720p 片源 → `720p_2m`（AV1 仍是 0.9M）。
String clampPresetForSource(
  String presetKey,
  int sourceHeight, {
  String codec = 'h264',
}) {
  final want = playQualityPresetOf(presetKey);
  if (want == null || want.copy) return presetKey;
  if (sourceHeight <= 0 || _fits(want.height, sourceHeight)) return want.key;

  final cap = maxPresetHeightForSource(sourceHeight);
  if (cap <= 0) return want.key;
  final candidates = presetsForSource(sourceHeight)
      .where((p) => !p.copy && p.height == cap)
      .toList();
  if (candidates.isEmpty) return want.key;

  final target = want.bitrateFor(codec);
  var best = candidates.first;
  var bestDiff = (best.bitrateFor(codec) - target).abs();
  for (final p in candidates.skip(1)) {
    final diff = (p.bitrateFor(codec) - target).abs();
    // 打平时取更低的那一档：少花流量比多花流量安全
    if (diff < bestDiff ||
        (diff == bestDiff && p.bitrateFor(codec) < best.bitrateFor(codec))) {
      best = p;
      bestDiff = diff;
    }
  }
  return best.key;
}
