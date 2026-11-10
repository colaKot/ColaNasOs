# ColaNasOs

> 个人 NAS 操作系统。独立实现，代码、界面与数据模型均为自有。

## 文档

主索引：[`docs/00-索引.md`](docs/00-索引.md)

| 册  | 内容                                   |
| --- | -------------------------------------- |
| 00  | 索引与版本                             |
| 01  | 架构总览                               |
| 02  | 服务端内核                             |
| 03  | 契约与接口                             |
| 04  | 客户端                                 |
| 05  | 工程与交付                             |
| 06  | 产品与运维                             |
| 07  | 附录（功能需求 / 数据需求 / 页面清单） |
| 08  | **施工手册**                           |
| 09  | **任务清单**                           |
| 10  | **完成定义 DoD**                       |

## 技术栈

Electron 44.9.3（外壳）+ `utilityProcess` 内核（TypeScript / Fastify / Kysely / SQLite）+ Sidecar（AI / 媒体 / 索引 / 同步）+ Flutter 客户端（6 端）+ AppleTV 原生壳。

## 快速开始

本地起服务端（**默认方式**，内核与 Flutter 都热更新）：

```bat
dev.bat
```

- 开发内核 **7888**（改服务端 1s 内自动重启）+ Flutter 页面 5173（保存即热重载）；正式服务端固定 7788，两套互不干扰。
- 只有需要验证「桌面形态 / 生产配置」时才用 `start.bat`（Electron 壳 + 无 dev-token / 无 CORS）。
- 交付或验收需要刷新 `apps/colanas_os/build/web` 时用 `build-web.bat`。

首次准备与门禁：

```bash
npm install          # 依赖精确锁定（见 package.json）
npm run build        # tsc 编译（增量）
npm test             # node:test 单元测试
npm run smoke:db     # DB 完整性 / 迁移 / 任务队列验收
npm run smoke:api    # 鉴权 / 越权 / 路径越界 / 队列验收
npm run smoke:upload # 分片上传：check / chunk / merge
npm run smoke:download # 下载：Range / ETag / If-Range
npm run gen          # 从运行实例导出 contracts/openapi.json
npm run gen:client   # OpenAPI → Dart ApiClient + DTO（packages/nas_core）
npm run verify       # 全量门禁
```

> 冒烟与生成脚本会自动自举 Electron 运行时（`ELECTRON_RUN_AS_NODE=1`），因为 `better-sqlite3` 是 Electron ABI。

## 许可

GPL-3.0。第三方组件见 `docs/06-产品与运维.md` 的「第三方上游与许可清单」。

## 致谢与参考

功能规划阶段参考了以下产品的**产品化思路**：

- **[NasCabOS](https://github.com/nascab/NasCabOS)** —— 跨平台 NAS 软件，覆盖照片、影音、音乐、图书与文件管理。相册、影视、发现等域的功能规划参考了它的产品化思路。
- **[TrailSnap](https://github.com/LC044/TrailSnap)** —— 独立开发的 AI 相册应用（Vue3 + FastAPI + PostgreSQL/pgvector），定位是「把旅行从拍过变成可留念、可展示、可分享」。相册域的功能规划参考了它的产品化思路。

界面图标使用 Flutter 内置的 Material Icons 与 Cupertino Icons。

### 随包分发的第三方二进制

- **Transmission**：`vendor/transmission-win/` 随包分发 Windows 版 `transmission-daemon.exe` 及其运行依赖 DLL，
  取自官方 `transmission-4.1.4-x64.msi`，原样提取、未做修改；`vendor/transmission-web/` 是官方 Web 界面静态文件（3.00）。
  两者均来自 [transmission/transmission](https://github.com/transmission/transmission)，按 **GPL-3.0** 使用，
  版权归 Transmission 项目作者所有（详见两个目录下的 `NOTICE.md`）。内核在用户未配置外部 RPC 时自动拉起该 daemon，
  并同源代理 Web UI —— 应用内称为 **内置 transmission 下载器**，也支持连接用户自己填写的 Transmission RPC。
- **Transmission Web Control**：`vendor/transmission-web-control/` 内置中文 Web UI（v1.6.1，MIT），
  用于「下载器 → 完整界面」。官方 Transmission Web UI 3.00 没有语言机制（整页英文），4.x 官方版也无内置中文，
  因此优先使用该中文前端，缺失时回退官方包。
- **FFmpeg / ffprobe**：`vendor/ffmpeg/`（Jellyfin 定制构建，GPL-2.0+，含 x264/x265），用于转码、抽帧与缩略图；
  分发时按 GPL 提供对应源码获取方式。
- **llama.cpp**：`vendor/llama/` 的 `llama-server` / `llama-tts`，用于本地 GGUF 模型推理。
- 其它随包资源：`vendor/geo/` 的地名库、`vendor/voices/` 的内置参考音色。

完整版本与许可口径见 `docs/06-产品与运维.md` 的「第三方上游与许可清单」。

### 本地推理模型

以下模型全部在用户本机离线推理，位于 `vendor/models/`，随安装包分发（不入库）；
版权归各自作者所有，按各自许可证使用：

| 模型 / 目录 | 用途 | 运行时 |
| --- | --- | --- |
| `faces/faceLandMark` | 人脸检测与 106 点关键点、人脸对齐 | ONNX Runtime |
| `faces/edgeface` | 512 维人脸特征向量（聚类 / 检索） | ONNX Runtime |
| `places365`（ResNet50） | 365 类场景分类 | ONNX Runtime |
| `clip`（视觉塔 + 文本嵌入） | 语义检索、场景打分与图像特征 | ONNX Runtime |
| `ppocrv6`（det / cls / rec） | 图片文字识别 | ONNX Runtime |
| `activity`（零样本视觉编码器 + 候选标签文本嵌入） | 活动 / 事件识别 | ONNX Runtime |
| `mt`（Qwen3-1.7B GGUF） | 本地短文本翻译 | llama.cpp `llama-server` |
| `qwen3-tts`（Qwen3-TTS-12Hz-1.7B GGUF） | 语音合成（配合内置音色） | llama.cpp `llama-tts` |

## 状态

SP0 骨架 **12/12 完成**：内核（注册器 / DB / 迁移 / 认证 / 队列 / 契约导出）+ `files` 列表 / 分片上传 / Range 下载 + Electron 外壳（单实例 / 托盘 / 内核守护）。冷启动 → `/health` 约 1.2 s。

SP1 完成（4/4）：`contracts/` 三份真源（OpenAPI / apps / i18n）→ Dart `ApiClient`（10 operations）、`app_registry.dart`（12 App × 6 端）、`keys.dart` + 13 语言骨架（46 键）；`npm run verify` 15 项门禁 13s 全绿，`dart analyze` No issues found（Flutter 3.47.8 / Dart 3.13.7）。
