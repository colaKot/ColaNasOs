# 行为用例覆盖矩阵（X-03）

> 由 `npm run behavior:matrix` 从 `tool/behavior/*.cases.ts`（编译产物）统计生成，**不要手改**；
> `npm run behavior:matrix.check`（已进 `verify`）在文件过期时失败。
>
> 角色归属：用例显式写 `roles` 就用它，否则按 id 关键词推断 ——
> `anonymous` → 匿名；`reader` → 只读；`cross-user|cross_user|other-user|isolated|per-user` → 跨用户；
> 都匹配不到算「写者」（写权限用户的正常业务路径）。命名不规范时请在 case 上显式标注 `roles`。
>
> 「跨用户」只对**按用户隔离的资源**有意义。账号、挂载、RSS 订阅、备份、分享链接、同步任务、
> 监控、Webhook 等是全局资源（域上标 `shared: true`），跨用户列显示「不适用」，不计入缺口。

| 域 | 用例 | 资源 | 匿名 | 只读 | 写者 | 跨用户 | 缺口 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| auth | 7 | 全局 | 1 | 1 | 5 | 不适用 | — |
| book | 11 | 按用户 | 2 | 2 | 3 | 4 | — |
| mediaTool | 4 | 全局 | 1 | 1 | 2 | 不适用 | — |
| message | 6 | 按用户 | 1 | 1 | 3 | 1 | — |
| mount | 6 | 全局 | 1 | 1 | 4 | 不适用 | — |
| music | 6 | 按用户 | 1 | 1 | 3 | 1 | — |
| notes | 6 | 按用户 | 1 | 1 | 3 | 1 | — |
| photo | 7 | 按用户 | 1 | 1 | 4 | 1 | — |
| rss | 6 | 全局 | 1 | 1 | 4 | 不适用 | — |
| safety | 6 | 全局 | 1 | 1 | 4 | 不适用 | — |
| share | 7 | 全局 | 1 | 1 | 5 | 不适用 | — |
| sync | 5 | 全局 | 1 | 1 | 3 | 不适用 | — |
| system | 5 | 全局 | 1 | 3 | 1 | 不适用 | — |
| video | 14 | 按用户 | 3 | 3 | 7 | 1 | — |
| webhook | 5 | 全局 | 1 | 1 | 3 | 不适用 | — |
| **合计** | **101** | 6 按用户 / 9 全局 | 18 | 20 | 54 | 9 | 无缺口 |

## 角色推断来源

| 域 | 显式标注 | 按命名推断 |
| --- | --- | --- |
| auth | 0 | 7 |
| book | 0 | 11 |
| mediaTool | 0 | 4 |
| message | 0 | 6 |
| mount | 0 | 6 |
| music | 0 | 6 |
| notes | 0 | 6 |
| photo | 0 | 7 |
| rss | 0 | 6 |
| safety | 0 | 6 |
| share | 0 | 7 |
| sync | 0 | 5 |
| system | 0 | 5 |
| video | 0 | 14 |
| webhook | 0 | 5 |

## 缺口（未覆盖的角色）

- 无：每个域都已覆盖适用的角色。

## 全局资源域（跨用户不适用）

`auth`、`mediaTool`、`mount`、`rss`、`safety`、`share`、`sync`、`system`、`webhook` 的资源是系统级共享数据（账号表、挂载配置、订阅、备份、分享链接、同步任务、进程与监控、Webhook），
不存在「他人资源」，因此不要求跨用户用例；这些域的越权语义由「只读 403」表达。

## 怎么补一个缺口

1. 在对应 `tool/behavior/<domain>.cases.ts` 里加一条自包含 case；
2. id 按 `场景.角色-预期` 命名（如 `library.cross-user-404`），或直接在 case 上写 `roles: ['crossUser']`；
3. `npm run build && npm run behavior:matrix` 重生成矩阵，`npm run behavior` 确认全绿。
