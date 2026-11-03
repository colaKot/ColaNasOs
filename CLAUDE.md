# ColaNasOs — 给 AI 助手的日常节奏

> 唯一真源是 `AGENTS.md`（尤其 §4）。本文件只同步最短的工作流，细则一律以 `AGENTS.md` 为准。

| 场景 | 用什么 | 耗时 |
| --- | --- | --- |
| 写代码 / 看页面 | `dev.bat`（一次启动，之后热重载） | 保存后 <1 s（Flutter）/ 1~2 s（内核重启） |
| 单个功能改完 | `npm run verify:fast` | ~23 s（只跑改动域） |
| 提交前 | `npm run verify` | ~63 s（全量） |
| 发布打包 | `git tag v1.x.x; git push origin v1.x.x` | CI 约 3~4 分钟（缓存后） |

硬规则：

- 不要手敲 `npm run dev` / `npm start` / `flutter build web`：用 `dev.bat` / `start.bat` / `build-web.bat`。
- 日常不要跑全量 `npm run verify`（除非提交前或跨域改动），更不要等 CI。
- **CI 只在打 `v*` tag 或手动 `workflow_dispatch` 时跑**，日常 `git push` 不触发。
- release 构建必须带 `--no-wasm-dry-run`（`build-web.bat` 已内置）。
- 门禁选择器规则在 `tool/verify.js` 的 `MODULE_RULES`；未识别路径会自动退回全量。

<details>
<summary>为什么这样</summary>

- CI 每次要装 852 MB `node_modules`（Electron 本体 320 MB）并按 Electron ABI 现场编译 `better-sqlite3`，再在 4 核 runner 上跑全量，合计 6~9 分钟；这部分和“改一行代码”无关，所以解绑到发布。
- 本地 `npm run build` 是增量编译（实测 1.7 s），不是 1 分钟；Flutter 首次冷启动 30~60 s，之后热重载 <1 s。
- 门禁的耗时大头是每步启动内核（~3.5 s/步），因此有了并发池 + 迁移模板 + 按改动选档。

</details>