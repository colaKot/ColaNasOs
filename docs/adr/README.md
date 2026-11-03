# ADR 目录

记录已经**落地并有后果**的架构决策，一条决策一个文件，编号只增不改。
格式：状态 / 背景 / 决策 / 后果 / 替代方案。撤回的决策标「已废弃」并保留原文，不删除。

| 编号 | 决策 | 状态 |
| --- | --- | --- |
| [0001](0001-contract-first.md) | 契约优先：TypeBox 单一真源，OpenAPI / Dart 客户端全部生成 | 已采纳 |
| [0002](0002-cursor-pagination.md) | 列表分页统一用排序键游标，禁止 offset 深翻 | 已采纳 |
| [0003](0003-jellyfin-ffmpeg.md) | ffmpeg 固定 jellyfin-ffmpeg，二进制落 `vendor/` 不入库 | 已采纳 |
| [0004](0004-mount-server-proxy.md) | 不做 FUSE 真挂载，改为服务端代理读写 | 已采纳 |
| [0005](0005-drop-service-docker-p2p.md) | 取消 service / docker / P2P / remote（含 DDNS、中继） | 已采纳 |
| [0006](0006-version-dir-updater.md) | 版本目录式更新器 + ed25519 签名 + 默认禁降级 | 已采纳 |
| [0007](0007-sync-merge-semantics.md) | 同步是 merge 语义，永不删除目标端文件 | 已采纳 |
| [0008](0008-zero-dep-parsers.md) | 解析器零依赖优先（EXIF / ZIP / WebDAV） | 已采纳 |
| [0009](0009-thumb-via-media-sidecar.md) | 缩略图走 media sidecar（按需拉起），内核不直调 ffmpeg | 已采纳 |

新增 ADR 时同步更新本表；`docs/00-索引.md` 已链接本目录。