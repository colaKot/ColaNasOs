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

- 内核 7788（改服务端 1s 内自动重启）+ Flutter 页面 5173（保存即热重载）。
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

相册智能分析在本地推理，使用以下开源模型，版权归各自作者所有，按各自许可证使用：

| 模型 | 用途 |
| --- | --- |
| faceLandMark | 人脸关键点 |
| EdgeFace | 人脸特征向量 |
| PP-OCRv6 | 文字识别 |
| Places365 | 场景分类 |
| CLIP | 语义与相似度 |
| DETR | 活动检测 |

## 状态

SP0 骨架 **12/12 完成**：内核（注册器 / DB / 迁移 / 认证 / 队列 / 契约导出）+ `files` 列表 / 分片上传 / Range 下载 + Electron 外壳（单实例 / 托盘 / 内核守护）。冷启动 → `/health` 约 1.2 s。

SP1 完成（4/4）：`contracts/` 三份真源（OpenAPI / apps / i18n）→ Dart `ApiClient`（10 operations）、`app_registry.dart`（12 App × 6 端）、`keys.dart` + 13 语言骨架（46 键）；`npm run verify` 15 项门禁 13s 全绿，`dart analyze` No issues found（Flutter 3.47.8 / Dart 3.13.7）。
