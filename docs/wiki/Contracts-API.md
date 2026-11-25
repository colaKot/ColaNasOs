# 契约与 API

> 契约是 ColaNasOs 的**唯一真源**：路由、字段、错误码、语言、应用清单都从这里生成，
> 改一处 → 全链路同步。细节见仓库 `docs/03-契约与接口.md`。

## 单一真源与生成链

```
TypeBox schema（内核 + 各域模块的 route）
        │
        ▼
  ContractRegistry ──► OpenAPI 3.0.3（/openapi.json）
        │
        ├─► ① Dart ApiClient + DTO ──► packages/nas_core/lib/api/
        ├─► ② i18n 键骨架（多语言）
        ├─► ③ AppRegistry（多端入口注册表，含相册独立端）
        ├─► ④ TypeScript / Python SDK ──► sdk/
        └─► ⑤ API 文档 ──► docs/api/api-reference.md
```

**生成链顺序不可颠倒**：

```
build → gen → gen:client → api:doc → sdk → gen:i18n → migrate:verify
```

| 命令 | 作用 |
| --- | --- |
| `npm run build` | tsc 增量编译 |
| `npm run gen` | 从**运行中的内核实例**导出 `contracts/openapi.json` |
| `npm run gen:client` | OpenAPI → Dart `ApiClient` + DTO |
| `npm run api:doc` | 生成 API 参考文档 |
| `npm run sdk` | 生成 TS / Python SDK |
| `npm run gen:i18n` | 生成多语言文案产物 |
| `npm run migrate:verify` | 迁移清单核对 |
| `npm run gen.check` | 校验磁盘与生成物一致（0 diff） |

**规则**：任何路由 / 字段 / i18n 键的新增**只改 TypeBox schema**，生成物一律由工具导出，**禁止手写**。生成物带 `AUTO-GENERATED` 头，`gen.check` 卡 CI。

⚠️ 改 `contracts/*.json` 里的**值**也会流进 `contracts/openapi.json`，必须重跑 `npm run gen`，否则 `verify:fast` 的 `gen.check` 会报「已过期」。

## API 规模

当前 **18 个域、442 个操作**：

| 域 | 操作数 | 域 | 操作数 |
| --- | --- | --- | --- |
| `photo` 相册 | 141 | `pt` | 26 |
| `video` 影视 | 74 | `files` | 18 |
| `music` 音乐 | 35 | `sync` | 17 |
| `accounts` 子账号与权限 | 25 | `rss` | 15 |
| `blog` | 23 | `transfer` | 8 |
| `discover` | 23 | `integration` 开放集成 | 6 |
| `system` 系统监控 | 20 | `tasks` | 5 |
| `auth` 认证 | 1 | `events` | 1 |
| `player` | 2 | `other` | 2 |

完整接口清单见仓库 `docs/api/api-reference.md`（按域分组，含参数与示例）。

## 统一错误契约

```ts
interface ApiError {
  code: string;        // 'FILE_NOT_FOUND' | 'PERMISSION_DENIED' | ...
  message: string;     // 面向用户，已本地化
  details?: unknown;   // 结构化上下文（不含敏感信息）
  traceId: string;     // 关联日志
}
```

- 错误码表集中在 `contracts/errors.json`（16 个错误码，含默认 HTTP 状态与中文默认文案），生成客户端常量。
- **禁止返回裸字符串错误**；错误码 → i18n key 的映射统一维护。

## 文件传输协议

| 环节 | 规范 |
| --- | --- |
| 上传 · 预检 | `POST /api/v1/files/check` → `{path,exists,uploadId,uploaded[],chunkSize}`，判定秒传与已收分片 |
| 上传 · 分片 | `POST /api/v1/files/chunk?path&index&total`，`application/octet-stream`，单请求 ≤ 64 MB；先写 `.tmp` 再 `rename`（不留半片） |
| 上传 · 合并 | `POST /api/v1/files/merge`，**幂等**；缺片 `409`，尺寸/hash 不符 `422`（不落盘） |
| 断点续传 | 服务端按 `uploadId` 保留已收分片，客户端凭 `check` 续传 |
| 下载 | `GET /api/v1/files/download?path=`：强 ETag（尺寸+mtime）、`If-None-Match` → `304`、`If-Range` 失配回 200、`Range` → `206`、越界 → `416` |
| 大文件 | 推荐流式转发，**禁止整文件进内存** |

## REST 设计规范

- 路径以 `/api/v1/<domain>` 组织，资源名用复数名词。
- 列表接口**必须分页**：日志类真分页（倒读 + cursor），图片类滚到底再加载；**不许一次全量加载**。
- ⚠️ querystring schema **不要写 `default:`** —— ajv 会把默认值填进 `q.xxx`，导致兼容别名失效；默认值在 handler 里兜底。
- 直接返回数组的路由要注意：契约生成器只会生成 `Future<Map>`，客户端 `_asMap()` 会把 List 吞成 `{}` ⇒ **必须包 `{items:[...]}`**（`schema:{hide:true}` 的隐藏路由例外）。
- 给响应 schema 加**必填**字段时，所有复用该 schema 的 handler 都要一起补，否则 `fast-json-stringify` 会 500。

## 开放集成

- **Webhook**：`integration` 域，投递带 `x-colanas-signature: sha256=<hex>` 签名头，接收方必须验签。
- **SDK**：由契约生成的 TypeScript / Python 客户端，位于 `sdk/`。
- **MCP**：`sidecars/mcp` 提供接入。

## 版本化与弃用

- API 版本前缀 `/api/v1`。
- 弃用流程在 `docs/03-契约与接口.md` §21：新增字段向后兼容，删改走新版本前缀，被弃用版本保留一个发布周期。

## 相关页面

- [架构总览](Architecture)
- [开发指南](Development) —— 生成链与门禁怎么跑
- [功能模块](Modules)
