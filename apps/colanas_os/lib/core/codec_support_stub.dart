import 'dart:io' show Platform;

/// 桌面端走内嵌 libmpv（AV1 / HEVC / H.264 都能解）；
/// 移动端（Android / iOS）的内嵌解码器对 **AV1 fMP4** 支持并不稳，
/// 实测安卓拿到 AV1 的 init.mp4 + 分片后会一直停在缓冲、不出画面。
///
/// 这里保守一点：手机上只认 H.264，转码档位自动落回兼容性最好的编码。
/// 用户之前在设置里选过 AV1 也没关系：`player_page` 会把不 playable 的编码
/// 换成 h264，并顺手建一个新的 H.264 会话（不会复用旧的 AV1 会话）。
bool codecPlayable(String codecKey) {
  if (Platform.isAndroid || Platform.isIOS) return codecKey == 'h264';
  return true;
}
