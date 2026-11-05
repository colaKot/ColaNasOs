import 'play_quality.dart';

import 'codec_support_stub.dart'
    if (dart.library.js_interop) 'codec_support_web.dart' as impl;

/// 某个编码在**当前运行环境**里能不能真的解出来。
///
/// 以前这里是按平台一刀切（`kIsWeb ? 'h264'`），理由是「hls.js 建不出 AV1 / HEVC
/// 的 SourceBuffer」。2026-11-05 用真 Chrome 156 + hls.js 1.4.10 复测，这个前提是错的：
/// `MediaSource.isTypeSupported('video/mp4; codecs="av01.0.05M.08"')` 返回 true，
/// 我们的 AV1 fMP4 产物（哪怕播放列表里没有 CODECS）也能正常起播 ——
/// `FRAG_BUFFERED` / `playing` / `readyState=4` 全部到位。
///
/// 所以改成问浏览器自己。桌面 / 移动端走内嵌 ffmpeg，一律为 true。
bool codecPlayable(String codecKey) => impl.codecPlayable(codecKey);

/// 当前环境**能选**的编码，顺序与 [playCodecs] 一致。
///
/// 菜单只该列解得出来的：列出来能点、点了黑屏，比不列更糟。
List<PlayCodec> playableCodecs() =>
    playCodecs.where((c) => codecPlayable(c.key)).toList();
