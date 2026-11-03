# ADR-0009 缩略图走 media sidecar（按需拉起）而不是内核直调 ffmpeg

- 状态：已采纳（2026-10-28）
- 相关：[09-任务清单 SP2-03 / SP3-02](../09-任务清单.md) · [进度 §22](../进度与下一步.md) · [ADR-0003](0003-jellyfin-ffmpeg.md) · [ADR-0008](0008-zero-dep-parsers.md)

## 背景

相册墙此前直接向 `/files/download` 要原图：一张 12 MP 的 JPEG 有 4–8 MB，滚动一屏就是几十 MB，
既吃带宽也吃客户端解码内存。`nas_media.thumbnail()` 早就生成了 `/api/v1/files/thumb` 的 URL，
但服务端一直没有这个接口。

生成缩略图有两条现成路径：

1. **内核直接调 ffmpeg**——`video/poster`、`music/cover` 现在就是这样（`src/modules/media/ffmpeg-run.ts`）；
2. **走 media sidecar**——`sidecars/media/main.js` 已有 `thumb` 方法（限流并发 4、`scale=lanczos`），
   `smoke:media` 用 500 张实测过 13.9 张/秒。

第 2 条是既定方向（`src/modules/video/index.ts` 的注释就写着「海报与探测后续收敛到 media sidecar」），
但当时内核**不管理任何 sidecar**：indexer 的超级进程只在冒烟里手工拉起。

## 决策

新增内核级 `MediaBridge`（`kernel/sidecar/media-bridge.ts`），**按需**拉起 media sidecar：

- 第一次真正需要缩略图时才 `spawn`，之后复用同一进程；心跳 / 僵死重启沿用 `SidecarSupervisor`；
- 内核 `onClose` 调 `stop()`，优雅退出 → SIGTERM → SIGKILL，不留孤儿进程；
- 依赖探测（脚本 + ffmpeg）在拉起前完成：缺任一条件就返回 `E_MEDIA_UNAVAILABLE`，
  路由回 **503**（不是 404，明确「能力缺失」而非「文件不存在」）；
- 对外只暴露 `KernelApi.media.{ thumb, available }`，模块不接触协议帧。

`GET /api/v1/files/thumb` 在此之上做三件事：路径越界 / 扩展名校验、`<dataDir>/thumbs` 文件缓存
（key = `sha1(rel|size|fileSize|mtimeMs)`，ETag 同源）、并发闸门 4 + 同图 in-flight 合并。

## 后果

**正面**

- 纯 API 场景（启动、检索、分享）不为 ffmpeg 付进程与内存代价；sidecar 只在有媒体请求时存在。
- 媒体类重活集中到一个限流进程，缩略图不会把内核的事件循环和转码 / AI 抢在一起。
- 缓存 key 含 `mtimeMs` 与 `size`，源文件替换后自动失效，无需显式失效逻辑。
- 关闭内核可验证子进程已退出（`smoke:thumb` 就断言了这点）。

**负面 / 代价**

- 内核多了子进程生命周期：sidecar 起不来时缩略图整屏占位（客户端已有占位图，不会崩）。
- 冷启动首张图会多一次 sidecar 握手（实测 < 1 s，之后走缓存）。
- `video/poster` 与 `music/cover` 仍直接调 ffmpeg，两套用法并存；收敛它们要动这两个域的冒烟。

**已知缺口**

- 缩略图目录没有配额与 LRU（可整目录删除重建），归到 SP4 / 运维策略。
- Electron 打包尚未把 `sidecars/` 放进 `extraResources`（SP4-03 安装器一起做），
  当前 `MediaBridge` 按 `__dirname/../../sidecars` 与 `cwd/sidecars` 探测。

## 替代方案

| 方案 | 否决理由 |
| --- | --- |
| 内核直接调 ffmpeg（复制 `video/poster` 的做法） | 与既定收敛方向相反；且每张图都起进程，没有跨请求的限流与复用 |
| 常驻 media sidecar（随内核启动） | 纯 API 部署白养一个进程；启动链路多一个失败点 |
| 引入 `sharp` 做缩略图 | 又一个按 Electron ABI 重建的原生模块，且 libvips 跨端分发成本高于 ffmpeg（ADR-0008） |
| 客户端缩放原图 | 带宽与内存问题原封不动，长列表尤其明显 |