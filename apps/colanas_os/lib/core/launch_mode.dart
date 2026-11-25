/// 启动端形态：完整客户端 / 相册独立端 / 音乐独立端 / 同步独立端。
///
/// 独立端复用主客户端代码（`photo_client` / `music_client` / `sync_client`
/// 只调 `runColanasApp(mode: ...)`），运行时需要知道自己是哪一端 ——
/// 例如相册独立端没有「回工作台」这个去处，顶栏的房子要隐藏。
enum AppLaunchMode { full, photo, music, sync }

/// 当前进程实际启动的端形态。由 [runColanasApp] 在启动时写入。
AppLaunchMode currentLaunchMode = AppLaunchMode.full;
