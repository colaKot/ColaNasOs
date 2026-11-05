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

/// kbps → `19.6 Mbps`；拿不到时给破折号，别在界面上显示 `0 Mbps`。
String mbpsLabel(int kbps) => kbps <= 0 ? '—' : '${mbpsText(kbps)} Mbps';

/// 片源码率（整片平均）：文件字节数 × 8 ÷ 时长。
///
/// 库里的 `video_items` 没有存码率列，但 `size` 和 `duration_ms` 都有 ——
/// 对「从什么码率转到什么码率」这个问题，平均码率就是用户能感知的那个数
/// （《匹诺曹》17.2 GB / 117 min ≈ 19.7 Mbps）。
int sourceKbpsOf(int bytes, int durationMs) {
  if (bytes <= 0 || durationMs <= 0) return 0;
  // bit/s = bytes × 8 ÷ (ms / 1000) = bytes × 8000 ÷ ms；再 /1000 换 kbps
  return (bytes * 8 / durationMs).round();
}

/// 把「用户偏好档位」贴到这部片实际能做到的档位上。
///
/// - 片源高度未知、或偏好档位本来就不超过片源 → 原样返回（尊重用户，不多花流量）；
/// - 偏好档位高于片源 → 收敛到片源能到达的最高分辨率，并在该分辨率下挑
///   **同一流量名次**的档位。
///
/// 「同一流量名次」而不是「最接近的绝对码率」（2026-11-05 用户确认）：
/// 每档分辨率给的是它自己的一组码率，`1080P` 的 0.9M 不该原封不动搬到 720P ——
/// 720P 用 0.9M 是画质过剩，用户要的是「720P 按 AV1 实际该多大就多大」。
/// 所以取偏好档位在它那组里的名次（码率从高到低第几档），落到目标分辨率组的同名次；
/// 名次越界（目标组档位更少）就取该组最低档。
///
/// 例：偏好 `1080p_2m`（1080P 组第 4 档，AV1 0.9M）落到 720p 片源
/// → 720P 组只有 3 档，取最低档 `720p_1m`（AV1 0.48M ≈ 0.5M）。
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
  final group = _groupByBitrateDesc(
    presetsForSource(sourceHeight).where((p) => !p.copy && p.height == cap),
    codec,
  );
  if (group.isEmpty) return want.key;

  final wantGroup = _groupByBitrateDesc(
    playQualityPresets.where((p) => !p.copy && p.height == want.height),
    codec,
  );
  final rank = wantGroup.indexWhere((p) => p.key == want.key);
  if (rank < 0) return want.key;
  return group[rank < group.length ? rank : group.length - 1].key;
}

/// 同一分辨率的档位按码率从高到低排（名次 0 = 该分辨率里码率最高的一档）。
List<PlayQualityPreset> _groupByBitrateDesc(
  Iterable<PlayQualityPreset> presets,
  String codec,
) =>
    presets.toList()
      ..sort((a, b) => b.bitrateFor(codec).compareTo(a.bitrateFor(codec)));
