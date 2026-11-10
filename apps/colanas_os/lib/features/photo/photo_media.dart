import 'package:nas_core/nas_core.dart';

/// 相册媒体的几个判定/格式化小工具（图片 / 视频 / 动态照片共用）。
///
/// 字段口径来自后端 `photo_items.media_kind` / `live_kind`：
///   mediaKind = image | video
///   liveKind  = '' | motion（JPEG 尾部带 mp4）| apple（配对 MOV）
bool isVideoItem(PhotoItem item) => item.mediaKind == 'video';

bool isLiveItem(PhotoItem item) => item.liveKind.isNotEmpty;

/// 视频封面抽帧位置（秒）。
///
/// 取时长的 10%，并夹在 0.5~3 秒之间：
///   - 太靠前（0 秒）常是黑场 / 转场，一整片黑的封面等于没有；
///   - 太长（长视频的前 30 秒）又会抽到片头字幕。
double? posterSeekOf(PhotoItem item) {
  if (!isVideoItem(item)) return null;
  final ms = item.durationMs ?? 0;
  if (ms <= 0) return 0.5;
  final sec = ms / 1000 * 0.1;
  return sec.clamp(0.5, 3.0);
}
