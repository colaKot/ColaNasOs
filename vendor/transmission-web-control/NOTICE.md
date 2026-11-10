# Transmission Web Control（中文 Web UI，随包内置）

本目录是 **transmission-web-control** 的静态前端文件，取自 `v1.6.1-update1` 的 `src/`。
唯一改动：`tr-web-control/script/system.js` 的 `defaultLang` 由 `""` 改为 `"zh_CN"`，
让界面默认中文（仍可在「设置 → 语言」里切换）。

| 项 | 值 |
| --- | --- |
| 上游项目 | https://github.com/ronggang/transmission-web-control |
| 版本 | v1.6.1-update1（2020-09-13） |
| 许可证 | MIT（见本目录 `LICENSE`） |
| 语言 | 自带 `zh_CN` / `zh_TW` / `en` 等语言包 |
| RPC | 同源 `../rpc`，由内核代理到内置 transmission daemon |

## 为什么内置

官方 Transmission Web UI 3.00 没有语言机制（整页英文），4.x 官方版也没有内置中文。
这里用 MIT 许可的中文前端替换，保证「下载器 → 完整界面」打开就是中文。

内核职责不变：

1. `/transmission/web/*` 从本目录读文件返回；
2. `/transmission/rpc` 反代到用户配置或内核拉起的 transmission daemon（带会话票据鉴权）。

## 更新方式

从上游 release / 源码取新的 `src/` 覆盖本目录（保留本文件与 `LICENSE`）。
