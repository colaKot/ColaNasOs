# Transmission Web UI（随包内置）

本目录是 **Transmission 官方 Web 界面**的静态文件，直接取自 Debian 官方包，未做任何修改。

| 项 | 值 |
| --- | --- |
| 上游项目 | https://github.com/transmission/transmission |
| 版本 | 3.00 |
| 包来源 | `transmission-common_3.00-2.1+deb12u1_all.deb`（Debian 12） |
| 包内路径 | `/usr/share/transmission/web/` |
| 许可证 | GPL-3.0（与 ColaNasOs 相同，见项目根 `LICENSE`） |
| 取用方式 | 解包 `data.tar.xz`，把 `usr/share/transmission/web/*` 原样拷出 |

## 为什么内置

「下载器」栏目自身只做只读列表；批量加种、限速、改目录这些操作直接用官方前端，
不重复实现。内核负责两件事（见 `src/modules/pt/webui.ts`）：

1. **同源托管**：`/transmission/web/*` 由内核从本目录读文件返回；
2. **RPC 反代**：官方前端只会请求同源的 `/transmission/rpc`，内核代理到用户在
   「发现 → 设置」里配置的 transmission 地址（补 Basic 认证、透传 session-id）。

鉴权：浏览器里的静态页拿不到 JWT，所以用「一次性票据换 Cookie」——
客户端打开 `/transmission/web/?t=<ticket>`，内核校验后下发 HttpOnly Cookie 并 302 掉 query。

## 更新方式

去 https://deb.debian.org/debian/pool/main/t/transmission/ 取新的 `transmission-common_*_all.deb`，
解包后覆盖本目录（保留本文件与 `LICENSE`）。
