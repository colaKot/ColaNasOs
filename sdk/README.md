# ColaNasOs SDK

> 由 `npm run sdk` 从 `contracts/openapi.json` 生成，**不要手改**；`npm run sdk.check`（已进 `verify`）会拦截过期文件。

## TypeScript

```ts
import { ColanasClient } from './client';

const client = new ColanasClient({ baseUrl: 'http://127.0.0.1:7788', token });
const books = await client.bookList({ limit: 20 });
```

- 依赖 `fetch`（Node 18+ / 浏览器 / Deno / Bun 均可用），不引第三方 HTTP 库；
- 每个 `operationId` 一个方法，参数统一 `params` 对象：路径参数自动替换，其余按方法分给 query 或 body；
- 类型在 `types.ts`，由 OpenAPI schema 直接映射。

## Python

```python
from colanas.client import ColanasClient

c = ColanasClient("http://127.0.0.1:7788", token)
print(c.book_list(limit=20))
```

- 只用标准库 `urllib`；
- 方法名为 `operationId` 的 snake_case 形式；
- 返回值直接是解析后的 dict。

## 说明

- 只覆盖契约里的 HTTP 路由；MCP（stdio）与 sidecar 协议不在 SDK 范围；
- 公开路由（分享下载、HLS 分片）同样生成方法，但 token 为空即可调用。
