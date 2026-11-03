# CL3-01 客户端性能基准

> 由 `node tool/bench/client.js` 生成（2026-10-28 11:29:02）；环境：Flutter 3.47.8 • channel stable • https://github.com/flutter/flutter.git · win32-x64；窗口 1400×900（expanded 双栏）。
> 数据链：真实内核 → 真实 HTTP 抓响应 → Flutter 侧按路径回放 → 页面真实渲染。

## 口径（先读这段再看数字）

- **首屏渲染**：`pumpWidget` → `NasLoading` 消失（数据帧 / 空态帧）的那一刻，含反序列化与首屏布局，**不含网络往返**（RTT 见下一节）。
- **滚动步进**：一次「拖动 160 px + pump 一帧」的平均耗时，反映 build/layout 的 CPU 成本。
- widget test **没有真实窗口**：没有 GPU 光栅化与 vsync 等待。滚动步进不能当作 fps，只作为「一帧 CPU 预算占比」参考（55 fps ≈ 18.2 ms/帧）。
- 为什么不在测试里直连内核：`testWidgets` 跑在 FakeAsync 里，`IoTransport` 的 30 s timeout 会变成 FakeTimer，真实 socket 回调永远等不到（实测挂死）。

## 首屏与滚动

| 页面 | 首屏渲染 | 滚动步进均值 | 滚动 20 步总计 | 首屏判据（≤1.5 s） |
| --- | --- | --- | --- | --- |
| photo | 545.4 ms | 2.87 ms | 57 ms | ✅ |
| video | 130.4 ms | 7.34 ms | 147 ms | ✅ |
| music | 194.1 ms | 11.50 ms | 230 ms | ✅ |
| book | 116.3 ms | 6.70 ms | 134 ms | ✅ |
| files | 42.0 ms | 4.00 ms | 80 ms | ✅ |
| notes | 51.6 ms | 1.87 ms | 37 ms | ✅ |

## 首屏接口 RTT（真实 HTTP，本地内核）

| 页面 | 接口 | RTT |
| --- | --- | --- |
| photo | `/api/v1/photo/timeline` | 21.74 ms |
| photo | `/api/v1/photo/albums` | 1.94 ms |
| photo | `/api/v1/photo/stats` | 2.26 ms |
| photo | `/api/v1/photo/libraries` | 3.93 ms |
| video | `/api/v1/video/list` | 10.57 ms |
| video | `/api/v1/video/series` | 4.03 ms |
| video | `/api/v1/video/progress/list` | 1.55 ms |
| video | `/api/v1/video/stats` | 0.97 ms |
| video | `/api/v1/video/libraries` | 2.52 ms |
| music | `/api/v1/music/list` | 8.07 ms |
| music | `/api/v1/music/stats` | 0.78 ms |
| music | `/api/v1/music/libraries` | 1.02 ms |
| music | `/api/v1/music/playlists` | 0.52 ms |
| book | `/api/v1/book/list` | 5.98 ms |
| book | `/api/v1/book/stats` | 0.84 ms |
| book | `/api/v1/book/libraries` | 2.09 ms |
| files | `/api/v1/files/list` | 2.93 ms |
| notes | `/api/v1/notes` | 0.94 ms |

## 结论

- 最慢首屏渲染 **545.4 ms**（判据 1500 ms，余量 955 ms）；
- 最慢滚动步进 **11.50 ms**，占 55 fps 单帧预算（18.2 ms）的 **63%**；
- 最慢接口 RTT **21.74 ms**（本地内核，未含公网 / TLS）；
- 6 个页面都进入了数据态，首屏数字可比较；
- 「滚动 ≥ 55 fps」仍需真机窗口复核（`flutter run --profile -d windows`），本表只能证明 CPU 侧没把帧预算吃掉。

## 复现

```text
npm run bench:client            # 起内核 + 抓响应 + flutter test，重写本文件
npm run bench:client -- --keep  # 保留临时数据目录（含 perf-data.json）便于排查
npm run bench:client -- --debug # 打印 flutter test 全量输出
```

## 已知限制

- 每页只跑一次，未取中位数；首屏值在 ±15% 内波动（首帧 JIT 预热已排除，因为数据帧不是首帧）。
- 只覆盖桌面 expanded 布局；compact（手机）另有一套排版，未纳入本表。
- 封面 / 缩略图不加载真实图片（`NasCoverImage` 在测试环境拿到 404），因此不含图片解码成本。
- 回放响应来自同一进程的内核，query 参数不参与匹配（同路径只回放第一次抓到的响应）。
