# 开发指南

> 给要改 ColaNasOs 代码的人。细节见仓库 `docs/05-工程与交付.md`。

## 环境

| 依赖 | 版本 |
| --- | --- |
| Node | 跟随 Electron 44 内置（**不单独安装**） |
| Flutter | 3.47.x（鸿蒙需配套 `flutter_ohos`） |
| Python | 3.13（部分工具脚本） |
| 平台 | **Windows**（本项目只面向 Windows NAS，不做 Linux/macOS 打包分支） |

```bash
npm install     # 依赖精确锁定
```

## 起服务

```bat
dev.bat
```

- **开发内核 7888**（改服务端 1 秒内自动重启）+ **Flutter 5173**（保存即热重载）。
- 正式服务端固定 **7788**，两套互不干扰。
- `dev.bat isolated` 用独立数据目录，不受正式版影响。
- `dev.bat` 会设置 `COLANAS_DEV_INSTANCE=1`：内核启动时探活 `127.0.0.1:7788/health`，发现另一个实例在跑就**只保留界面与接口，跳过全部后台任务**（扫描 / 监控 / 刮削 / AI / 定时任务），状态写进 `GET /ready` 的 `background` 字段与 `<dataDir>/dev-overlap.marker`。

其他入口：

| 脚本 | 用途 |
| --- | --- |
| `start.bat` | 生产形态（Electron 壳 + 无 dev-token / 无 CORS） |
| `build-web.bat` | 重建 `apps/colanas_os/build/web`（服务端内置的 Web 界面） |
| `TV.bat` | TV 版面预览（5175 + 控制口 5176） |
| `build-photo.bat` | 相册独立端出包（`main_photo.dart` + `-PnasApp=photo`，→ `ColaNasOs-Photo-<ver>-android-arm64.apk`） |

⚠️ **5173 的 `flutter run` 在跑时不要构建 web**（抢同一个 build 目录）。

## 常用命令

### 编译与测试

```bash
npm run build          # tsc 增量编译（唯一算「服务端编译」的步骤）
npm test               # node:test 单元测试
npm run verify         # 全量门禁
npm run verify:fast    # 快速门禁（发版前用）
npm run verify:full    # 发版全量
node tool/verify.js --only=<范围>   # 只跑某一块
```

### 契约生成链（顺序不可颠倒）

```bash
npm run build
npm run gen            # 从运行中的内核导出 contracts/openapi.json
npm run gen:client     # → Dart ApiClient + DTO
npm run api:doc        # → docs/api/api-reference.md
npm run sdk            # → sdk/
npm run gen:i18n       # → 多语言文案产物
npm run migrate:verify # 迁移清单核对
```

### 验收（smoke）

几十个定向 smoke，按域覆盖：

```bash
npm run smoke:api      # 鉴权 / 越权 / 路径越界 / 队列
npm run smoke:db       # DB 完整性 / 迁移 / 任务队列
npm run smoke:upload   # 分片上传：check / chunk / merge
npm run smoke:download # 下载：Range / ETag / If-Range
npm run smoke:player   # 播放器会话与转码
npm run smoke:photo    # 相册
npm run smoke:video    # 影视
npm run smoke:music    # 音乐
npm run smoke:packaged # 打包产物的冒烟
```

> 冒烟与生成脚本会**自动自举 Electron 运行时**（`ELECTRON_RUN_AS_NODE=1`），因为 `better-sqlite3` 是 Electron ABI —— 用系统 `node` 跑会报模块版本不匹配。

### 客户端

```bash
cd apps/colanas_os
flutter analyze lib            # 交付/验收必须全量跑
flutter test test/<某文件>.dart
flutter build web --release --no-wasm-dry-run
flutter build apk --release --target-platform android-arm64
flutter build apk --release --target-platform android-arm64 \
  --target lib/main_tv.dart --dart-define=COLANAS_TV=1     # Android TV
```

相册独立端在仓库根目录用 `build-photo.bat`（内部 `--target lib/main_photo.dart --android-project-arg=nasApp=photo`，applicationId `com.colanas.photo`，可装在主客户端旁边）。

⚠️ **安卓三份包不可互通**：`apk` / `apk_tv` / `apk_photo` 身份不同，客户端检查更新分别带 `build=phone|tv|photo`；`tool/release/release.js` 已加映射，发版要同时提供三份包（相册端当前待正式发版，`release/update.json` 尚未挂 `apk_photo`）。

⚠️ **只 analyze 改动过的文件是不够的** —— 会漏掉「被别处引用的库文件」。批量替换脚本曾把一个库文件清成 0 字节，单文件检查全绿、全量却报 7 个 error。批量改完顺手扫一遍提交内文件的字节数是否骤降。

## 工程红线（违反了按缺陷处理）

1. **Electron ABI**：`better-sqlite3` / `node-pty` / `node-datachannel` 每次 Electron 变更必须 `@electron/rebuild`，并跑 `npm run smoke:abi`（**不能用系统 node**）。
2. **ONNX 版本冻结**：继续用 `onnxruntime-node` 1.20，`getBestExecutionProviders()` 显式排除 `webgpu`。
3. **SQLite 变量上限 999**：批量 `whereIn` 分片（400/批）。
4. **单实例锁**：`app.setPath` 必须在取锁之前。
5. **`onnx_models` 不进 asar**：走 `extraFiles`。
6. **`flutter_ohos` 版本对齐**：禁止单方面升 Flutter 而不升 fork。
7. **批量改文件纪律**：先备份 → 脚本「读→改→校验→通过才落盘」→ 精确替换配 `assert count` 双重校验；**任何 assert 失败直接抛错、绝不落盘**。
8. **事务纪律**：单事务 ≤ 50 ms，事务内禁止 `await` / 文件 IO / 网络。
9. **代码隔离**：**禁止**复制外部源码、资源或译文；第三方库只能从**上游**引入。
10. **AGPL 默认禁止**：确需引入必须同时满足五条件（独立进程、不改源码、不静态链接、法务书面确认、SBOM 标注）。
11. **别在 `main` 里直接 require 内核** —— 那是单进程巨石的根因。
12. **契约生成物禁止手写**：生成物带 `AUTO-GENERATED` 头，`gen.check` 卡 CI。

## 提交约定

- 每次改完代码都要提交本地 git，**按本轮相关路径显式 `git add`**，别 `git add -A`（工作树里长期有大量在途文件）。
- 提交信息写明改动点；正文含反引号时写进文件后 `git commit -F`（否则会被 shell 的命令替换吃掉）。
- 拆提交 / 重建历史前先建备份分支；`git reset --mixed <基线>` 只动索引、不动工作树。
- ⚠️ 别把「首次入库的新文件」剥成未跟踪：它们可能已被 legit 文件 import，剥掉后 HEAD 直接编译不过。
- 批量改代码按**行号**定位并逐行断言，别按内容 replace（同名声明常有多处）。

## 加一个功能的标准流程

1. 改 **TypeBox schema**（新增路由 / 字段），不手写生成物。
2. 需要新文案 → 改 `contracts/i18n.json` + `contracts/messages/{zh-CN,en-US}.json` → `npm run gen:i18n`（键数写在 `packages/nas_core/lib/l10n/keys.dart` 的 `i18nKeyCount`，当前 3155）。
3. 需要新页面 → 走 `node tool/new-app.js`，并在 `contracts/apps.json` 里登记导航（否则 `tool/check/app-nav-check.js` 的双向对账会报 `nav-orphan`）。
4. 跑生成链：`build → gen → gen:client → api:doc → sdk → gen:i18n → migrate:verify`。
5. `flutter analyze lib` 全量 + 相关 smoke + `npm run verify`。
6. 提交。

## 相关页面

- [契约与 API](Contracts-API)
- [架构总览](Architecture)
- [发版与交付](Release)
