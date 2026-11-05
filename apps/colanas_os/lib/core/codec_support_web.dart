import 'package:web/web.dart' as web;

/// 每种编码的探测串（MSE 只认完整 codec 串，光写 `av01` 会一律 false）。
///
/// - AV1：Main profile / level 2.1（SVT-AV1 实际输出的就是这个档），8bit；
/// - HEVC：Main profile / level 4.0。
///
/// 探测串里的 level 不决定能不能解（Chrome 只按编码族 + 位深判定），
/// 所以不必按每个片源的真实 level 再问一遍。
const Map<String, String> _probeTypes = {
  'av1': 'video/mp4; codecs="av01.0.05M.08"',
  'h265': 'video/mp4; codecs="hvc1.1.6.L120.90"',
};

/// 问浏览器自己能不能解。H.264 是 MSE 的底线，不必问。
///
/// 拿不到 `MediaSource`（极老的浏览器 / 被策略禁用）时按不支持处理：
/// 这时候连 MSE 都没有，hls.js 本来就放不了，回落 H.264 也不会更差。
bool codecPlayable(String codecKey) {
  if (codecKey == 'h264') return true;
  final type = _probeTypes[codecKey];
  if (type == null) return true;
  try {
    return web.MediaSource.isTypeSupported(type);
  } catch (_) {
    return false;
  }
}
