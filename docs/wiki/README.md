# Wiki 源文件

这里是 **GitHub Wiki 的源文件**。Wiki 仓库（`colaKot/ColaNasOs.wiki.git`）是独立仓库，
没有 PR 评审，所以内容留在主仓库里版本化，改完再推。

## 页面清单

| 文件 | Wiki 页面 |
| --- | --- |
| `Home.md` | 首页（入口与导航） |
| `Getting-Started.md` | 快速开始 |
| `Architecture.md` | 架构总览 |
| `Server-Kernel.md` | 服务端内核 |
| `Client.md` | 客户端 |
| `Contracts-API.md` | 契约与 API |
| `Modules.md` | 功能模块 |
| `Local-AI.md` | 本地 AI 与模型 |
| `Development.md` | 开发指南 |
| `Release.md` | 发版与交付 |
| `Operations.md` | 运维手册 |
| `FAQ.md` | 常见问题 |
| `Roadmap.md` | 路线图与状态 |
| `Contributing.md` | 贡献与许可 |
| `_Sidebar.md` / `_Footer.md` | GitHub 特殊页（侧栏 / 页脚） |

本文件（`README.md`）**不会**发布成 wiki 页面。

## 同步

```bash
node tool/sync-wiki.js              # 同步并推送
node tool/sync-wiki.js --dry-run    # 只看会推什么
```

脚本会克隆 wiki 仓库到临时目录 → 覆盖同名页面 → 删掉源目录里已不存在的页面 → 提交推送。
认证走系统 git credential（Windows 上是 Git Credential Manager），不落盘明文。

> ⚠️ wiki 仓库必须先被 GitHub 建出来：到仓库的 **Wiki** 标签页点「Create the first page」
> 提交一次即可。之后本脚本就能正常克隆。

## 写作约定

- **以代码为准**：文档里写的目录、模块名、命令、端口都要跟仓库实际一致；
  设计蓝图（`docs/01-架构总览.md`）里有些是早期规划，别照抄。
- **版本号写具体值**（公开版如 `1.5.0`、主干如 `1.5.7`），不要写「最新版」。
- **中文正文 + 英文文件名**：文件名即 wiki 页面名（URL 用英文更稳），正文全中文。
- 跨页链接用相对链接：`[快速开始](Getting-Started)`。
- 改动大版本号时，首页、下载相关页面的版本号要一起改。
