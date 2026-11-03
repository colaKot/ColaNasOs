# ADR-0008 解析器零依赖优先（EXIF / ZIP / WebDAV）

- 状态：已采纳（2026-10-28 ~ 2026-11-01，逐步落地）
- 相关：[09-任务清单 SP3-02 / SP3-05 / SP3-07](../09-任务清单.md)

## 背景

相册要读拍摄时间、书房要读 epub / cbz 元数据、挂载要连 WebDAV。对应的现成库
`exifr` / `yauzl` / `webdav` 都不大，但本项目已有 `better-sqlite3`、`onnxruntime-node`、
`node-pty` 三个必须按 Electron ABI 重建的原生模块，依赖面每扩大一分，跨端打包风险就多一分。

## 决策

对**格式封闭、需求窄**的场景自己写最小解析器：

| 能力 | 落地 | 只支持的真实子集 |
| --- | --- | --- |
| EXIF | `src/modules/photo/exif.ts` | JPEG `DateTimeOriginal`、PNG IHDR 宽高；缺失回落文件名日期再回落 mtime |
| ZIP | `src/modules/book/zip.ts` | EOCD → 中央目录 → 本地头；store / deflate；条目 ≤5000、单条目 ≤32 MB、总解压 ≤64 MB（防压缩炸弹） |
| epub / cbz / pdf 元数据 | `src/modules/book/metadata.ts` | epub `container.xml` → OPF（title / creator / language / publisher / cover）；cbz `ComicInfo.xml`；pdf `/Title` 与 `/Type /Page` 近似页数 |
| WebDAV 客户端 | `src/modules/mount/webdav.ts` | PROPFIND depth 1、GET（Range / ETag）、PUT、MKCOL、DELETE；Basic 认证 |

## 后果

**正面**：零新增依赖，不引入 ABI 风险；解析逻辑可测试（每个 smoke 都覆盖真实文件）；
进出都有大小上限，天然抗压缩炸弹与畸形输入。

**负面**：特性覆盖有限——ZIP 不支持 zip64 / 加密条目 / 分卷；EXIF 不读 GPS 与镜头信息；
WebDAV 不支持 Digest / bearer 与 locking。遇到真实需求时需按 ADR 追加子集，而不是「换个库」。

## 替代方案

- **引入成熟库**：功能全，但依赖面与原生 ABI 风险上升，且多数特性本项目用不到，否决。
- **调外部二进制**（unzip / exiftool）：需随包分发多平台二进制，反而更重，否决。