# 行为用例编写指南（X-03）

> 行为用例用来验证**「谁能做什么、越权会怎样、业务链路是否连通」**，与 `tool/check/*-smoke.js` 分工不同：
> smoke 盯实现细节（协议、边界、性能），行为用例盯可读的业务语义。
> 执行器：`tool/check/behavior.ts`（编译后 `dist/tool/check/behavior.js`）；
> 覆盖矩阵：`tool/check/behavior-matrix.ts`（编译后 `dist/tool/check/behavior-matrix.js`）。

## 1. 运行

```bash
npm run build && npm run behavior            # 全部域
npm run behavior -- --domain=share           # 只跑一个域
npm run behavior -- --id=password            # 按 case id 子串过滤
npm run behavior -- --json=behavior.json     # 附 JSON 报告

npm run build && npm run behavior:matrix     # 重新生成 docs/behavior-覆盖矩阵.md
npm run behavior:matrix.check                # 只校验矩阵是否过期
```

`verify` 已包含 `behavior` 与 `behavior:matrix.check`（都排在 `build` 之后，直接消费 `dist/`）。
矩阵脚本 `require` 的是**编译产物**，改了 `tool/behavior/*.cases.ts` 后必须先 `build` 再生成。

## 2. 文件与导出

用例放在 `tool/behavior/<domain>.cases.ts`，默认导出 `BehaviorDomain`：

```ts
import type { BehaviorDomain } from '../check/behavior-types';

const domain: BehaviorDomain = {
  domain: 'share',                       // 必填：域标识（报告里的前缀）
  shared: false,                         // 可填：资源是否全局共享（见 §4）
  async prepare(tmpDir) {                // 可选：内核启动前准备（建目录 / 写文件）
    return {};                           // 返回额外 env（会注入 process.env）
  },
  async setup(ctx) {},                   // 可选：内核启动后、用例前
  async teardown(ctx) {},                // 可选：用例后
  cases: [
    {
      id: 'create.anonymous-401',        // 必填：稳定 id，用于 --id 过滤与角色推断
      name: '匿名用户不能创建分享链接',    // 必填：报告里展示的行为描述
      roles: ['anonymous'],              // 可选：显式标注角色，缺省按 id 推断
      async run(ctx) { /* 断言 */ },
    },
  ],
};

export default domain;
```

**每个 case 必须自包含**（自己创建所需数据），不要依赖前一个 case 的副作用 ——
否则 `--id=` 单独跑会失败。

## 3. CaseContext 能力

| 成员 | 用途 |
| --- | --- |
| `ctx.request(method, url, { token, headers, payload })` | 走 `app.inject`，不占端口 |
| `ctx.token(scopes, sub?)` | 签发开发令牌（结果按 `sub+scopes` 缓存） |
| `ctx.expect(cond, message)` | 断言，失败抛错并记 FAIL |
| `ctx.assertStatus(res, code, label?)` | 断言状态码，失败信息带响应体片段 |
| `ctx.tmpDir` / `ctx.dataDir` / `ctx.filesRoot` | 本域临时目录（每个域独立，跑完删除） |
| `ctx.app` / `ctx.k` | 需要直接操作内核时用（如改库模拟过期） |

执行器为每个域独立启动一次内核（独立 `dataDir` 与 `filesRoot`），域之间互不影响。

## 4. 角色约定（四角色）

项目没有角色表，只有 scope。行为用例用 scope 组合模拟四角色：

| 角色 | 矩阵值 | scope | 预期 |
| --- | --- | --- | --- |
| 匿名 | `anonymous` | 无 token | 401 |
| 只读 | `reader` | `domain:read` | 读 200，写操作 403 |
| 写者 / 普通用户 | `writer` | `domain:read` + `domain:write` | 自己的资源 200 |
| 跨用户 | `crossUser` | 同上，但 `ctx.token(scopes, 'u3')` 换 `sub` | 他人资源 404 |

**跨用户只对按用户隔离的资源有意义。** 账号、挂载、RSS 订阅、备份与加密空间、分享链接、
同步任务、进程监控、Webhook 是系统级共享数据（对应表没有 owner 列，或本身就是「给所有人」的公开资源），
这些域声明 `shared: true`，矩阵里跨用户列显示「不适用」，不计缺口；它们的越权语义由「只读 403」表达。

角色归属优先看 case 上的 `roles`；没写就按 id 关键词推断：
`anonymous` → 匿名；`reader` → 只读；`cross-user|cross_user|other-user|isolated|per-user` → 跨用户；
其余算「写者」。**命名不规范时请显式写 `roles`**，否则矩阵统计会失真。

## 5. 现有用例（14 个域，96 例）

| 文件 | 覆盖 |
| --- | --- |
| `auth.cases.ts` | 错误口令、匿名列账号、只读建账号、管理员建账号并登录、停用后拒绝登录、2FA 初始化返回 otpauth |
| `photo.cases.ts` | 时间轴鉴权、建库权限、越界、扫描、排序、关键词搜索、相册跨用户隔离 |
| `video.cases.ts` | 库鉴权 / 越权、越界、扫描、搜索与排序、播放直链、未知 id、剧集识别与聚合、观看进度跨用户隔离、外挂字幕匿名 / 只读 / 未知名字 |
| `music.cases.ts` | 库鉴权 / 越权、扫描、搜索、歌单跨用户隔离、播放直链 |
| `book.cases.ts` | 库鉴权 / 越权、扫描、收藏与进度隔离、阅读直链、无封面 404、合集 / 归档 / 自定义列表四角色 |
| `notes.cases.ts` | 创建权限、版本历史与恢复、跨用户 404、软删除 |
| `mount.cases.ts` | 匿名 / 只读拒绝、非法 kind、列表脱敏、rclone 501 或成功、删除 |
| `share.cases.ts` | 匿名 / 只读、公开下载、密码三态、越界、撤销后失效 |
| `sync.cases.ts` | 匿名差异、越界、overwrite 覆盖、skip 冲突与裁决、只读不能触发 |
| `safety.cases.ts` | 备份权限、备份→恢复、未知备份 404、加密空间往返、错误密码 403 |
| `system.cases.ts` | 匿名拒绝、监控指标（含 `uptimeSec`）、进程列表、只读不能 kill、受保护 pid 400 |
| `rss.cases.ts` | 订阅权限、内联 XML 添加即落条目、刷新幂等、无数据源 400、取消订阅级联 |
| `message.cases.ts` | 发送权限、未读数流转、标记已读、删除、定向发送跨用户隔离 |
| `webhook.cases.ts` | 创建权限、secret 仅创建时返回、列表脱敏、events 必填、删除 |

全量统计与缺口见 [`behavior-覆盖矩阵.md`](behavior-覆盖矩阵.md)（脚本生成，不要手改）。
新增域按同一模板补：一个 `<domain>.cases.ts`，先覆盖匿名 / 只读，再按资源语义决定是否要跨用户用例。

## 6. 与验收条目的关系

任务清单里「域级验收 = 附录 B 条目 + 页面可达 + `cases/<domain>` 全绿 + 四角色用例通过」中的
**四角色用例**即指本目录下的行为用例。一个域补齐行为用例后，才能把该域的 `[~]` 改成 `[x]`；
矩阵是这条验收的可核查证据：`npm run behavior:matrix` 后该域「缺口」列应为 `—`。