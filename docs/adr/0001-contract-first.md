# ADR-0001 契约优先：TypeBox 单一真源

- 状态：已采纳（2026-10-28）
- 相关：[03-契约与接口](../03-契约与接口.md)、[08-施工手册](../08-施工手册.md)

## 背景

客户端与服务端分离（Flutter + Fastify），接口数量已达 120 个路径。手写 OpenAPI、手写
Dart 模型、手写请求方法，三者必然会漂移；历史上最贵的 bug 类型之一就是「契约与实现不一致」。

## 决策

1. 每个模块用 **TypeBox** 声明请求 / 响应 schema，声明即校验（运行时 `compiled` 校验）；
2. `npm run gen` 从运行中的内核导出 `contracts/openapi.json`，**禁止手写**；
3. `npm run gen:client` 从同一份 OpenAPI 生成 `packages/nas_core` 的 client 与 models；
4. 门禁 `gen.check` / `gen:client.check` / `smoke:dart` / `verify:contract` 分别校验
   「代码 ↔ OpenAPI」「OpenAPI ↔ Dart」「破坏性变更」。

## 后果

**正面**：契约漂移在 CI 内被拦住；客户端零手写 HTTP；改动 schema 即三端同步。

**负面**：生成物只能通过改源码 + 重新生成来变更，手工编辑会被门禁打回；schema 写法受限
（例如 `Type.Union([...])({...})` 不可调用，需在 Union 内配 options）。

## 替代方案

- **tRPC / gRPC**：跨语言客户端生成器不成熟，Flutter 侧需自建，收益不如 OpenAPI。
- **手写 DTO + 手写 client**：正是本 ADR 要消除的漂移源头。