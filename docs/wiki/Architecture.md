# 架构总览

> 这一页讲「ColaNasOs 是怎么搭起来的」。细节见仓库 `docs/01-架构总览.md`（架构蓝图，v9.0）。

## 为什么这么设计

本项目**没有老用户、没有覆盖升级包袱**，所以能一开始就定死后来的很多东西：

| 决策点 | 选型 | 理由 |
| --- | --- | --- |
| 标识 | `name` / `appId` / `bundleName` 自由定 | **一次定死**（见下方「标识与命名」） |
| HTTP | **Fastify** | route schema 即契约，OpenAPI 直接生成 |
| 应用更新 | **版本目录式更新器** | `versions/D<NNN>` + 指针，原子切换、可回滚 |
| 服务端模块 | TS + 规范模块 | 没有 CJS/ESM 撕裂，编译产物一致 |
| API 设计 | 可重新设计 | 功能覆盖即可，不背逐字兼容负担 |
| 数据迁移 | 正式**迁移框架**（Kysely migration） | 版本化、可回滚 |

仍然要背的工程约束：Electron ABI 原生模块、ONNX 版本回归、SQLite 999 变量上限、单实例锁。

## 进程模型

**`electron/main` 只做外壳**（窗口 / 托盘 / 单实例 / 更新器），**内核跑在 `utilityProcess`**（Electron 官方多进程 API，Node 环境、可独立重启）。

| 进程 | 职责 | 崩溃影响 |
| --- | --- | --- |
| `main` | 外壳、托盘、更新、生命周期 | 退出应用 |
| `kernel`（`utilityProcess`） | Fastify + 内核 + 域模块 | **只影响服务**，外壳可以重新拉起它 |
| `ai-infer` / `media` / `indexer` / `photo-ai` / `mcp` | 重活 | 仅该 sidecar，任务重投 |

收益：API 与 UI 互不拖累；内核崩溃可独立重启；外壳先起、服务并行就绪。

> 铁律：**不要在 `main` 里直接 `require` 内核** —— 那样外壳与内核就无法独立重启。

## 三条主线

1. **内核只做通用能力**：认证、权限、DB、迁移、队列、事件、资源、i18n、契约、进程守护。
2. **域功能一律进域模块**：`src/modules/<domain>/` 内自带 routes / services / repo / migrations / i18n。
3. **重活一律下放 sidecar**：AI 推理、媒体转码、索引扫描、同步执行全部独立进程。

## 技术选型

| 层 | 选型 | 说明 |
| --- | --- | --- |
| 语言 | **TypeScript（strict）** | 主进程编译到 CJS（Electron 兼容），sidecar 用 ESM |
| HTTP | **Fastify** + `@fastify/swagger` + `@fastify/websocket` | 性能、schema 校验、原生 OpenAPI |
| 契约 | **TypeBox**（与 Fastify route schema 同源） | 单一真源，一路生成 OpenAPI → Dart |
| DB | **better-sqlite3** + **Kysely** | 类型安全；`node:sqlite` 是可选优化项 |
| 迁移 | **Kysely migration**（版本化、可回滚） | 新增表不再整包重打 |
| 向量 | **sqlite-vec** | ANN 索引，告别全量余弦 |
| 队列 | 自建 **SQLite 持久化队列** | 优先级 / 限流 / 暂停 / 进度 / 重试 / 撤销；不引 Redis |
| 日志 | **pino** | Fastify 原生，结构化 |
| 实时 | Fastify WebSocket + **yjs** | 协同编辑器保留 |
| Sidecar 通信 | NDJSON over named pipe（Windows） | 超时、心跳、崩溃重启 |
| 客户端 | **Flutter 单栈**（`flutter_ohos` 覆盖鸿蒙） | 见 [客户端](Client) |
| 客户端本地库 | **SQLite + Drift** | 类型安全 ORM + 迁移机制 |
| 产物目录 | `D<NNN>` | 避免 `dist_vN` 序号；更新器按版本号单调递增选，回滚 = 切回上一目录 |

### 版本基线

| 组件 | 基线 | 说明 |
| --- | --- | --- |
| Electron | **44.9.x**（精确锁定，不带 `^`） | 变更 = 全部原生模块重编 + 回归；升级前必须跑 `npm run smoke:abi` |
| Node | 跟随 Electron 内置 | 不单独安装 Node |
| better-sqlite3 | **12.11.1** | Electron 44 实测可用（SQLite 3.53.2） |
| Flutter | **3.47.x** | 与 `flutter_ohos` 版本锁对 |
| flutter_ohos | **必须与 Flutter 3.47 配套** | 单方面升 Flutter 会断鸿蒙 |
| Android 构建 | Gradle 8.14 / AGP 8.11.1 / Kotlin 2.2.20 | |
| Web 构建 | 默认 dart2js；`--wasm` 是试验项 | 不通过就回退 dart2js |

## 目录结构（真实仓库）

```
ColaNasOs/
├─ kernel/                 # 服务端内核（TS）
│  ├─ index.ts             # 内核入口：迁移 → 模块挂载 → 路由
│  ├─ auth.ts  db.ts  migrator.ts  queue.ts  bus.ts
│  ├─ registry.ts  route.ts  contract.ts  contracts.ts
│  ├─ sidecar/             # supervisor / protocol / media-bridge / indexer-bridge
│  ├─ migrations/          # 基线迁移（见「迁移时序」注意）
│  ├─ updater.ts  watchdog.ts  watchdog-supervisor.ts
│  ├─ https-proxy.ts  proxy-fetch.ts  secret-box.ts  tls.ts
│  └─ llm/  tts/  cache-stats.ts  catalog-store.ts  transfer-store.ts …
├─ src/modules/            # 15 个服务端域模块（目录即模块）
│  └─ <domain>/{routes,services,repo,migrations,i18n,index.ts}
├─ sidecars/               # ai-infer / media / indexer / photo-ai / mcp / gpu
├─ contracts/              # TypeBox → OpenAPI → 生成产物；locales/errors/apps/i18n 单一真源
├─ electron/               # 外壳：main / preload / tray / installer / updater
├─ packages/               # 客户端共享包：nas_core / nas_ui / nas_media
├─ apps/                   # 客户端：colanas_os（主端，含 main.dart / main_tv.dart / main_photo.dart 三入口）+ music/photo/sync 脚手架（历史）
├─ docs/                   # 设计文档、ADR、基准、API 参考、用户/运维手册
├─ tool/                   # gen/ check/ build/ bench/ split/ verify 等工具
├─ vendor/                 # 随包分发的第三方二进制与模型（ffmpeg / llama / transmission）
├─ site/                   # 官网静态站
└─ sdk/                    # 生成的 TS / Python SDK
```

## 标识与命名（发布后不可改）

| 项 | 值 | 说明 |
| --- | --- | --- |
| productName | `ColaNasOs` | 安装包 / 快捷方式显示名 |
| `package.json` name | `colanas_os_server` | 决定数据目录 `%APPDATA%\colanas_os_server` |
| appId | `com.colanas.os` | Electron 安装标识 |
| 相册独立端 applicationId | `com.colanas.photo` | 与主客户端**并存安装**，非替换；检查更新带 `build=photo` 只回 `apk_photo` |
| Flutter `pubspec` name | `ColaNasOs` | Dart 包前缀 |
| 鸿蒙 `bundleName` | `com.colanas.os` | 鸿蒙应用标识 |
| 构建产物目录 | `D<NNN>` | `build/D<NNN>` → 安装后 `versions/D<NNN>`，更新器按版本号单调递增选 |

> 首个发行版发布后主标识**不可再改**（改 = 数据目录 / 安装标识漂移）。相册独立端用**新增**的 `com.colanas.photo`，不影响主客户端标识。安卓三份包 `apk` / `apk_tv` / `apk_photo` 身份不同、绝不互通。

## 数据流举例：看一部没转过的电影

1. 客户端 `GET /api/v1/video/items/:id` 拿条目 → 发现容器/编码浏览器解不了。
2. 客户端 `POST /api/v1/player/sessions` 建转码会话，服务端起 `media` sidecar 跑 ffmpeg，**2 秒一片**往 `hls/pN/` 落盘。
3. 客户端拿到 `index.m3u8`（**静态 VOD 列表 + ENDLIST**，一次列全部分片），交给 media_kit / libmpv 播放。
4. 播放器按需拉分片；用户快进到还没转出来的位置时，客户端**先等转码追上**（服务端 `GET /player/sessions/:id?pos=` 同时也是「续转」信号），等不到就重建会话。
5. 播放进度写回服务端（`POST /player/sessions/:id/progress`），影视首页「最近在看」就能读到。

## 相关页面

- [服务端内核](Server-Kernel) —— 内核各子系统
- [客户端](Client) —— 多端怎么共用一套代码
- [契约与 API](Contracts-API) —— 单一真源与生成链
- [功能模块](Modules) —— 14 个应用分别做什么
