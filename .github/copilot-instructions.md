# ColaNasOs 开发与门禁约定

唯一真源：`AGENTS.md`（尤其 §4）。本文件只同步最短工作流。

## 日常节奏（16 核 / 24 GB 实测）

| 场景 | 命令 | 耗时 |
| --- | --- | --- |
| 写代码 / 看页面 | `dev.bat`（一次启动，之后热重载） | 保存后 <1 s（Flutter）/ 1~2 s（内核重启） |
| 单个功能改完 | `npm run verify:fast` | ~23 s（只跑改动域） |
| 提交前 | `npm run verify` | ~63 s（全量） |
| 发布打包 | `git tag v1.x.x; git push origin v1.x.x` | CI 约 3~4 分钟（缓存后） |

## 硬规则

- 不要手敲 `npm run dev` / `npm start` / `flutter build web`：用 `dev.bat` / `start.bat` / `build-web.bat`。
- 日常不要跑全量 `npm run verify`（除非提交前或跨域改动），更不要等 CI。
- CI 只在打 `v*` tag 或手动 `workflow_dispatch` 时跑，日常 `git push` 不触发。
- release 构建必须带 `--no-wasm-dry-run`（`build-web.bat` 已内置）。
- UI 文案禁止硬编码：键写 `contracts/i18n.json`，译文写 `contracts/messages/<locale>.json`，然后 `npm run gen:i18n`。
- 端口：内核 7788（`GET /health`），开发页面 5173。