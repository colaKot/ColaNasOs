/// 非 Web 端（Windows / Android / iOS / macOS / Linux）：播放走内嵌 ffmpeg，
/// AV1 / HEVC / H.264 都能解，不需要探测。
bool codecPlayable(String codecKey) => true;
