# ADR-0003 ffmpeg 固定 jellyfin-ffmpeg，二进制落 vendor

- 状态：已采纳（2026-10-28）
- 相关：[06-产品与运维 §媒体](../06-产品与运维.md)、[09-任务清单 SP3-03](../09-任务清单.md)

## 背景

影视探测、海报抽帧、音乐 tag / 封面、缩略图都依赖 ffmpeg。系统 PATH 上的 ffmpeg 版本不可控
（本机实测是 ImageMagick 附带的裁剪版，**没有 ffprobe**），而 NAS 场景需要 HDR→SDR、字幕烧录、
QSV/VAAPI/NVENC 等媒体服务器补丁。

## 决策

1. 固定使用 **jellyfin-ffmpeg v8.1.3-1**（`ffmpeg 8.1.3-Jellyfin`）；
2. 二进制**不入仓库**，`npm run ffmpeg:fetch` 下载 + sha256 校验后解到 `vendor/ffmpeg/`，
   支持 `--archive=` 离线安装、`npm run ffmpeg:check` 检查就绪；
3. 运行时探测顺序：`COLANAS_FFMPEG` → `vendor/ffmpeg/ffmpeg` → `vendor/ffmpeg/bin/ffmpeg`；
   **默认不回落系统 PATH**，确需时设 `COLANAS_FFMPEG_ALLOW_PATH=1`。

## 后果

**正面**：能力与版本可复现；分发体积可控；不会静默用错 ffmpeg。

**负面**：首次安装需联网（或离线包）；升级 ffmpeg 要改锁定版本 + 重新校验 sha256；
GPL 分发需随包提供对应源码地址（已在 06 文档记录）。

## 替代方案

- **系统 PATH ffmpeg**：版本与编解码能力不可控，实测缺 ffprobe，否决。
- **随包内置**：仓库膨胀数百 MB，且每个平台一份，否决。