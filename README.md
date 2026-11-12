# ColaNasOs

> **Windows NAS 系统 / WindowsNas** —— 在一台 Windows 主机上，把照片、影视、音乐、文件、下载、同步与本地 AI 收进同一个自托管 NAS OS；桌面 / 手机 / Web / Android TV / Apple TV / 鸿蒙六端共用一套 Flutter 界面。独立实现，代码、界面与数据模型均为自有。

**检索关键词**：Windows NAS · WindowsNas · NAS 系统 · NAS OS · 自托管 NAS · 家庭 NAS · personal NAS · Flutter NAS · Electron NAS

## 项目亮点

- **为 Windows NAS 而生**：面向单台 Windows 主机设计，装好即用；Fastify + SQLite 内核直接读写本机目录，不依赖云账号或额外数据库服务，一个 Electron 外壳 + `utilityProcess` 内核即可跑起来。
- **契约驱动，改一处生成全链路**：`contracts/openapi.json` / `apps.json` / `i18n.json` 是唯一真源，`build → gen → gen:client → api:doc → sdk → gen:i18n → migrate:verify` 一条链生成 Dart `ApiClient` 与 DTO、TypeScript/Python SDK、API 文档和多语言骨架；另有破坏性变更检测、生成物一致性、迁移清单与菜单双向对账兜底。
- **六端一套代码**：`desktop / mobile / web / tv_android / tv_apple / harmony` 由同一份 Flutter 代码与同一份导航契约驱动，二级侧栏、页面栈、权限域在各端一致；Apple TV 另有原生壳，鸿蒙端保留独立工程骨架。端能力矩阵按 `contracts/apps.json#capabilities` 的 6 类能力 × 6 端档位收敛。
- **一套多选交互**：相册、影视、音乐的选中态统一走 `packages/nas_ui` 的选择态基座 —— 工具栏勾选进入、卡片勾选角标、内联操作条（全选 / 业务动作 / 关闭），不再各页各写一套。
- **大规模媒体库也不卡**：日志倒读真分页、图片墙滚到底再加载、记忆列表每页 10 条、人脸结果渐进返回，数万到数十万张照片不会一次全量拉取。
- **本地 AI 全离线**：人脸检测与对齐、人脸聚类与人物关系、365 类场景、CLIP 语义检索、OCR、活动识别、短文本翻译、TTS 朗读，全部由 ONNX Runtime / llama.cpp 在本机推理，图片不上传。
- **媒体链路闭环**：TMDB / 豆瓣评分与刮削、NFO 读写与「用户手改优先」冲突合并、剧集识别、字幕、海报缓存、HLS 分片续转；下载完成经文件监控自动入库并触发「入库即刮」。
- **内置下载器与优雅退出**：随包内置 transmission-daemon 与同源 Web UI 代理，也支持外部 RPC；退出应用前先 `torrent-stop` 发 `stopped` 公告再停进程，内核热重启不打断做种，也不会被 tracker 当成新的做种位置。
- **鉴权与隔离**：JWT 密钥落盘持久化（重启不踢客户端）、自动登录与多端口服务发现、子账号权限域、路径越界拦截、分片上传与 Range 下载。
- **开发体验**：`dev.bat` 一键起开发内核（7888，改服务端秒级自动重启）+ Flutter 5173 热重载；正式服务端固定 7788，两套互不干扰；验收按改动范围选步，数十个定向 smoke 覆盖各模块。
- **可验证的交付**：错误码登记、i18n 缺键检查、权限域清单、迁移顺序对账、行为用例覆盖矩阵，全部纳入本地门禁。

## 功能模块

| 模块 | 主要能力 |
| --- | --- |
| **相册** | 时间轴 / 文件夹 / 收藏 / 足迹地图；那年今日、记忆、每日一帧、人生章节、票根、年度报告、时光对照（同一「月-日」跨年并排，优先锁定同一个人物）；人脸聚类与人物关系、以图搜图与语义检索、智能相册规则、相似与重复清理（原「重复洞察」已并入相似清理，先预演、再执行、按批次撤销）、GPS、动态照片；备份去重（墓碑表）、回收站、本地与 SMB 多来源 |
| **影视** | 多影视库与多来源、NFO / TMDB 刮削与海报、剧集与季集、演员作品与日系榜单、查重、自定义合集（新建 / 重命名 / 合并 / 手排）、观看进度、字幕、HLS 续转播放；下载完成自动入库并刮削 |
| **音乐** | 曲库 / 专辑 / 歌手 / 歌单 / 收藏 / 播放历史、列表与框选多选、播放队列与全屏播放器、LRC 与在线歌词刮削、Last.fm Scrobble、简繁与跳字搜索、目录源与缓存设置 |
| **发现** | 影视榜单与评分（TMDB / 豆瓣）、PT 站点搜索与择种、RSS 订阅与自动下载规则、订阅台账与任务面板 |
| **文件** | 网格 / 列表视图、统一目录选择器（可返回上一层）、分片上传、Range / ETag 下载、回收站、文件操作日志 |
| **传输 / 下载器** | 多端设备传输、内置 transmission 下载器与完整 Web UI、种子与规则管理 |
| **同步** | 多端目录同步计划、冲突策略、定时任务 |
| **AI 播客** | AI 新闻聚合、文稿生成、TTS 朗读与播放队列 |
| **监控 / 终端 / 账号 / 设置** | 系统状态与任务队列、日志真分页、Web 终端、子账号与权限域、2FA、全局与模块设置、多语言 |

服务端按域拆分为 `auth / photo / video / music / discover / rss / pt / files / transfer / sync / blog / system / media / videoPlayer / integrations`，每个域自带迁移、schema 与路由；文件监控（含 `.nfo` 变更）按库订阅，新增文件增量入库，避免整库重扫。

导航契约当前注册 14 个 App（`photo / files / video / discover / music / blog / ai / monitor / sync / transfer / transmission / accounts / terminal / settings`）。书模块与独立的「智能合集」页已下线：图书不再随包提供，合集改为用户自定义合集，相册的重复洞察并入相似清理。

## 架构与技术栈

Electron 44.9.3（外壳）+ `utilityProcess` 内核（TypeScript / Fastify / Kysely / SQLite）+ Sidecar（AI / 媒体 / 索引 / 同步）+ Flutter 客户端（6 端）+ AppleTV 原生壳。

- **内核**：模块注册器、迁移执行器、JWT 鉴权与权限域、任务队列（去重 / 重试 / 进度上报）、事件流、契约导出、静态 Web 托管。
- **客户端**：`packages/nas_core`（API / 模型 / i18n）+ `packages/nas_ui`（主题 / 组件）+ `apps/colanas_os`（各功能模块），导航来自 `contracts/apps.json#nav`。
- **Sidecar**：ONNX 推理、FFmpeg 抽帧与转码、索引与同步进程，由内核统一管理启动与心跳。

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

## 快速开始

下载安装（当前版本 **1.1.0**，全部产物见 [Releases](https://github.com/colaKot/ColaNasOs/releases/latest)）：

| 平台 | 产物 | 说明 |
| --- | --- | --- |
| Windows | `ColaNasOs-Setup-1.1.0.exe` | 安装版（含服务端内核与本地 AI 运行时） |
| Windows 便携 | `ColaNasOs-1.1.0-windows-x64.zip` | 解压即用，适合不想安装的场景 |
| Android | `ColaNasOs-1.1.0-arm64.apk` | arm64 手机 / 平板 |

服务端随 Windows 安装包一起分发（Electron 外壳内置内核），不单独提供安装包。

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

## 支持

如果 ColaNasOs 对你有帮助，欢迎扫码支持这个项目继续维护下去。

<p align="center">
  <img src="docs/assets/donate-wechat.webp" width="220" alt="微信收款码" />
</p>

微信扫码即可（收款码，金额随意）。也欢迎通过 Issue / PR 反馈问题、补充文档。

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

主干功能已成型：14 个应用全部开放、6 端界面、15 个服务端域，契约生成链与定向验收门禁保持全绿。当前迭代重点与待办见 `docs/09-任务清单.md`、`docs/10-DoD.md`。

冷启动 → `/health` 约 1.2 s；`flutter analyze lib` 0 error，服务端 `tsc` / ESLint / 生成物一致性 / 迁移清单 / i18n / 文件监控 / 影视等定向验收通过。
