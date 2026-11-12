/// 非 Web 端（Windows / Android / iOS / macOS / Linux）：播放走内嵌解码器，
/// AV1 / HEVC / H.264 都能解，不需要按编码探测。
///
/// 不做「移动端禁用 AV1」这类一刀切：AV1 fMP4 在浏览器 / PC / 安卓上都能播，
/// 之前「一直缓冲」的根因是 EVENT 播放列表被当成直播从末尾起播（与编码无关），
/// 见服务端播放列表的 EXT-X-START 与首片等待。
bool codecPlayable(String codecKey) => true;
