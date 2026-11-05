# ColaNasOs 项目约定（给 AI 助手与协作者）

> 本文件是长期约定，改动前先读；新约定按「一句话 + 为什么」补在对应小节。

## 1. 本地起服务端：默认用 `dev.bat`（不要再手敲 `npm run dev` / `npm start`）

```bat
dev.bat
```

- 开两个窗口：`tool/dev/watch-kernel.js`（`tsc --watch` + 自动重启内核，7788）+ `tool/dev/flutter-dev.js`（托管 `flutter run -d chrome --web-port 5173`，Dart 热重载）。
- 改服务端 1s 内自动重启，改 Flutter 保存即热重载，不需要反复 release 构建。
- `dev.bat` 会显式设置 `COLANAS_DEV_TOKEN=1` 与开发期 CORS；测试联调就用它。

### 1.1 「按 R」不用人敲（`tool/dev/flutter-dev.js`）

`flutter run` 的命令（`r`/`R`/`q`）只从**它自己的 stdin** 读，所以以前改完 `packages/**`
（`nas_core` / `nas_ui` 这类 path 依赖）必须人到窗口里敲 R，否则一直跑旧代码 ——
表现成「前端还是旧的」。现在由 `flutter-dev.js` 接管 flutter 的 stdin：

- **自动**：监听 `packages/**` 与 `apps/colanas_os/pubspec.yaml`，变化后 1.2s 去抖自动发 `R`；
- **手动（给助手 / 脚本用）**：控制口 `http://127.0.0.1:5174`，只绑 loopback + 校验 token：

```bash
curl -s http://127.0.0.1:5174/status                   # 状态 / 已重启次数 / 最后原因
curl -s -X POST "http://127.0.0.1:5174/hot-restart?token=colanas-dev-ctl"   # 等价 R
curl -s -X POST "http://127.0.0.1:5174/hot-reload?token=colanas-dev-ctl"    # 等价 r
```

> 原理（读过 flutter_tools 源码，别改成猜的）：`TerminalHandler.setupTerminal()` 只要
> `stayResident` 就装 stdin 监听、**不检查 stdin 是不是终端**；`terminal.keystrokes`
> 直接读 `_stdio.stdin` 原始字节；`singleCharMode` 的 setter 里有
> `if (!_stdio.stdinHasTerminal) return;`，所以管道下不抛异常。
> ⇒ 写入 `R`（**不带换行**，它读原始字节）就是一次热重启。
>
> `apps/colanas_os/lib/**` 不在此监视范围：flutter 自己会热重载，多余的 R 会白丢状态。
>
> ⚠️ 包装器是**原样透传**参数的，命令行里 `run` 子命令不能省：
> 少了它会报 `Could not find an option named "--web-port"` 并以 64 退出，
> 窗口一闪而过、浏览器也不会开。排查这类「窗口没了」先看 `.devdata/flutter-dev.log`。

其它脚本的定位（**只需记住这三行，不要再手写它们的命令**）：

| 脚本            | 它做什么                                                                                                                                          | 什么时候用                                                                             |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `dev.bat`       | 双窗口：`tool/dev/watch-kernel.js` + `tool/dev/flutter-dev.js`（托管 flutter，带 5174 控制口）                                                    | **默认**：本地调试、联调、跑手工验收                                                   |
| `start.bat`     | `npm start` → Electron 外壳 + 内核；窗口直接加载 `http://127.0.0.1:7788/`（不再是 `/health`）；缺 `dist/kernel/index.js` 会先自动 `npm run build` | 只在需要验证「桌面形态 / 生产配置（无 dev-token、无 CORS）」时用                       |
| `build-web.bat` | `flutter build web --release --no-wasm-dry-run` → `apps/colanas_os/build/web`                                                                     | **只在交付 / 打包 / 验收**需要刷新 7788 的正式产物时用；`dev.bat` 在跑时**不要**跑它（全量 30s，开发循环靠 5173 热重载） |
| `pack.bat`      | `npm run pack` → `dist_installer/win-unpacked`，随后跑 `installer.check`                                                                          | 只需验证打包形态、做安装前自检时用                                                     |
| `dist.bat`      | `npm run dist` → `dist_installer/ColaNasOs-Setup-<版本>.exe`（NSIS，含本地模型），随后跑 `installer.check`                                       | 交付完整安装器时用；出包前先跑 `build-web.bat`                                        |
| （精简包）      | `npm run dist:lite` → `dist_installer/ColaNasOs-<版本>-<arch>-lite-setup.exe`（不含 `vendor/models`，约 206 MB）                                  | 不需要本地 AI / 体积敏感时用                                                           |

打包冒烟：`npm run smoke:packaged`（独立端口 7799 + 隔离数据目录，校验 health / Web 首页 / 未登录 401 / 首启数据初始化）。
**排查"安装包点了没反应"先看 `ELECTRON_RUN_AS_NODE`**：该变量为 `1` 时 Electron 会退化成 Node，无脚本参数直接 exit 0。

## 2. 构建：release 构建必须带 `--no-wasm-dry-run`

`flutter build web --release --no-wasm-dry-run`（`build-web.bat` 已内置，出正式包就跑脚本，别手敲 `flutter build web`）。

- 手敲容易漏 `--no-wasm-dry-run`，白花 25~30s；脚本还负责定位 flutter 可执行文件与失败时报错。
- Flutter 3.47 默认会在 dart2js 之后额外跑一遍 dart2wasm 演练编译，本仓库不发 wasm，实测白花 25~30s（37s → 9s）。
- 实测基线与说明见 `docs/进度与下一步.md` §66。

## 3. 端口与同源

- 内核 **7788**（`PORT` 可改），`GET /health` 探活；`http://127.0.0.1:7788/` 由内核托管 `apps/colanas_os/build/web`。
- 开发期页面在 **5173**，客户端默认服务地址取「页面同源」；`dev.bat` 用 `--dart-define=COLANAS_API_BASE=http://127.0.0.1:7788` 把 API 固定到内核。

## 4. 改完必须跑的验证

> **CI 只在发布时跑**（打 `v*` tag 或手动 `workflow_dispatch`），日常提交不触发、不等 CI。
> 开发循环用 `dev.bat`（保存即热重载）；改完一个功能跑 `verify:fast`；提交前跑 `verify`。

> **给 AI 助手：不要每个功能都跑 `verify` / `verify:full`，更不要跑 CI。**
> 一个功能改完 → `npm run verify:fast`；跨域改动或用户说要提交 → 才 `npm run verify`。
> 编译只有两步：服务端 `npm run build`（tsc），Web 产物 `build-web.bat`。

> ⛔ **`dev.bat` 在跑的时候，禁止跑 `build-web.bat`。** 那是 `flutter build web --release`，
> dart2js **全量**编译（实测 30s，Web release 没有增量编译），而开发循环用的是 5173 的
> `flutter run`（DDC 增量：改 `apps/**` 保存即热重载 <1s，改 `packages/**` 自动发 `R` 约 2~4s）。
> `build/web` 只在内核 7788 要对外提供正式产物时才需要刷新 —— 即**交付 / 打包 / 验收**，
> 不是改完一个功能就刷。同理，日常改代码也不需要 `flutter test`（提交门禁才跑）。
>
> 判断口诀：**能靠刷新 5173 看到效果 → 一个编译命令都不敲。**

```bash
npm run build            # tsc（增量，1~2s）
flutter analyze          # 在 apps/colanas_os 下
flutter test             # 在 apps/colanas_os 下
npm run verify:fast      # 按 git 改动选步（本地日常，实测 ~23s）
npm run verify           # 全量并行门禁（76 项，实测 77s；串行基线 570s）
npm run verify:full      # 全量 + media 500 张基准（发版 / 每周）
npm run gen:template     # 重建内核迁移模板（迁移改了会自动失效，一般不用手动跑）
```

**日常节奏（16 核 / 24 GB 实测；其他 AI 工具的规则文件都以本表为准）**：

| 场景 | 用什么 | 耗时 |
| --- | --- | --- |
| 写代码 / 看页面 | `dev.bat`（一次启动，之后热重载） | 保存后 <1 s（Flutter）/ 1~2 s（内核重启） |
| 单个功能改完 | `npm run verify:fast` | ~23 s（只跑改动域） |
| 提交前 | `npm run verify` | ~77 s（全量） |
| 发布打包 | `git tag v1.x.x; git push origin v1.x.x` | CI 约 3~4 分钟（缓存后） |

门禁按改动自动选档，**不要每次再问「要不要跑全量」**：

| 改动 | 跑什么 |
| --- | --- |
| `src/modules/<域>/**` | `npm run verify:fast`（只跑该域 smoke + 该域 behavior，契约层照跑） |
| `apps/**` `packages/**` `sdk/**` | `npm run verify:fast`（dart-pkgs + dart 契约） |
| `contracts/**` | `npm run verify:fast`（全部 `gen.*.check` + `smoke:dart` / `smoke:i18n`） |
| `kernel/**` `tool/**` `electron/**` `package*.json` | `npm run verify`（全量，选择器会强制退全量） |
| 提交前 / 跨域改动 | `npm run verify` |
| 发版 / 打 tag / 升级依赖 | `npm run verify:full` |

- 选择规则在 `tool/verify.js` 的 `MODULE_RULES`；未识别的路径**退回全量**，不会漏检。
- `--changed` 会打印「按改动选择 N 步」+ 改动文件；`--dry-run` 只打印不执行，`--files=` 可模拟。
- 结果落 `dist/verify-report.json`（每步耗时、慢步 Top8），排查慢点直接看它。
- 并发默认 `min(6, cpus-2)`，可用 `--jobs=N` 调整；behavior / dart-pkgs 内部并行度跟随该值。
- 每个 smoke 复制「已跑完迁移」的空库模板（`COLANAS_KERNEL_TEMPLATE`，缓存 key = 迁移文件内容），省掉重复迁移；生成失败会自动回退逐次迁移。
- 门禁默认 `LOG_LEVEL=warn`（启动 info 日志约占 1~2s I/O），排查问题时加 `--verbose`。

涉及 Web 产物时再跑 `npm run smoke:web`（11 项）与 `npm run fonts:check`（115 项）。

## 5. 文案与契约

- UI 禁止硬编码文案：键写 `contracts/i18n.json`，译文写 `contracts/messages/<locale>.json`，然后 `npm run gen:i18n`。
- `web/flutter_bootstrap.js` 里的 `{{flutter_js}}` / `{{flutter_build_config}}` 是构建期占位符，已在 `.prettierignore` + `eslint.config.mjs` 中忽略，不要格式化它。
- `web/index.html` 不要改写 `window._flutter`（会让真正的 loader 永不创建，整页白屏）。
