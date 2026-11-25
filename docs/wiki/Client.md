# 客户端

> 一份 Flutter 代码，编译出桌面 / 手机 / Web / Android TV / Apple TV / 鸿蒙 / 相册独立端各端。
> 细节见仓库 `docs/04-客户端.md`。

## 一套代码，多端入口

| 端 | 入口 | 说明 |
| --- | --- | --- |
| Windows / macOS / Linux 桌面 | `apps/colanas_os/lib/main.dart` | 同一份 Flutter 桌面端 |
| Android / iOS | 同上 | 手机 / 平板，同一套页面 |
| Web | 同上（dart2js） | 浏览器打开服务端内置的 Web 界面 |
| Android TV | `apps/colanas_os/lib/main_tv.dart` | 独立入口，遥控器焦点导航；打包加 `--dart-define=COLANAS_TV=1` |
| Apple TV | 原生壳 + Flutter 界面 | 官方无 Flutter 支持，保留 Swift 壳 + 桥接 |
| 鸿蒙 | `apps/colanas_os/ohos/` | `flutter_ohos` fork，必须与 Flutter 3.47 配套 |
| 相册独立端 | `apps/colanas_os/lib/main_photo.dart` | 同一工程换入口，登录后直进相册时间轴；`build-photo.bat` 用 `-PnasApp=photo` 出包，applicationId `com.colanas.photo`，与主客户端**并存安装** |

> TV 版 / 相册版与普通版**共用全部业务代码**，只换入口与外壳：播放器、影视、音乐、我的四个板块完全同源，改一处全端生效。相册版隐藏「回工作台」的房子入口，登录后直接落在相册时间轴。

## 仓库里的客户端代码

```
apps/
├─ colanas_os/              # 主端：所有功能
│  ├─ lib/
│  │  ├─ main.dart          # 普通入口
│  │  ├─ main_tv.dart       # TV 入口（runColanasApp(tvEntry: true)）
│  │  ├─ main_photo.dart    # 相册独立端入口（runColanasApp(mode: photo)）
│  │  ├─ core/              # API 会话、设置、日志、播放内核与工具
│  │  ├─ shell/             # 导航外壳、登录、首页
│  │  └─ features/          # photo video music files discover blog ai
│  │                        # monitor sync transfer transmission
│  │                        # accounts terminal settings tv home login
│  ├─ test/                 # 单测
│  └─ ohos/ windows/ android/ ios/ linux/ web/
├─ music_client/            # 独立音乐端（历史工程）
├─ photo_client/            # 历史脚手架；相册正式包改从 colanas_os 用 build-photo.bat 出
└─ sync_client/             # 独立同步端

packages/
├─ nas_core/                # API 客户端、模型、i18n、日志
├─ nas_ui/                  # 主题、组件、选择态基座
└─ nas_media/               # 媒体播放相关
```

**独立端**（`music_client` / `photo_client` / `sync_client`）从「path 依赖整份 app」改成了依赖 `nas_core` / `nas_ui`，改完必须跑各自的自检脚本（`_check_standalone_*.py`）。其中 `photo_client/` **只保留为历史脚手架**：相册的正式包现在从 `apps/colanas_os` 用根目录 `build-photo.bat` 构建（换入口 + 换 applicationId，保留完整的备份服务 / 更新安装器 / FileProvider），产物 `ColaNasOs-Photo-<ver>-android-arm64.apk`。

## 导航

- 二级侧栏**唯一实现**在 `lib/shell/app_nav_shell.dart`。
- 菜单来自契约 `contracts/apps.json#nav`，由 `tool/check/app-nav-check.js` 与代码**双向对账**（豁免写法 `// nav-orphan: a, b`）。
- 图标必须落在白名单 `AppVisuals.icons` 里，由 `test/icon_whitelist_test.dart` 把关。
- 新增应用：`node tool/new-app.js`。

## 布局自适应

- 窄屏：底部导航（5 个主入口 + 「更多」）。
- 宽屏：左侧导航栏。
- 同一套逻辑，两套布局；影视页转屏时**不会**把导航打回首页。

## 播放器（四个端共用一份）

播放器是这套代码里最容易出问题的地方，也是踩坑最多的地方。几条关键设计：

| 点 | 做法 |
| --- | --- |
| 渲染 | Windows 客户端用 **libmpv（mpv 0.36）**，`media_kit_video` 走 render API 出纹理 |
| TV 硬解（Media3） | Android TV 播放器开**隧道模式**，音视频同步与合成交给 SoC 硬件通道，4K / HDR 不在应用层多一次拷贝；开**解码器回退**，DV / HEVC 10bit 硬解实例初始化失败时继续尝试其它硬件解码器而非黑屏；24p 片源优先匹配电视刷新率（`ONLY_IF_SEAMLESS`） |
| TV 音轨与平台视图 | `onTracksChanged` 检测音轨：选中 TrueHD / DTS-HD MA 这类无平台解码器的音轨时主动报错，让 Dart 侧切服务端转码（视频直通 + 音频转 AAC），避免「有画面没声音」；平台视图走 **Hybrid Composition 真实 Surface**（`initExpensiveAndroidView` + `AndroidViewSurface`），保住 HDR / 杜比动态元数据 |
| 直连 vs 转码 | 用户选「原画」时优先直连；转码只发生在结构性解不了、用户显式选了分辨率档、直连实测跟不上或颜色无法保证时 |
| 原画直通 | `preset=original` 会话只换容器不重编码，DV / HDR 元数据原样保留；播放列表读 ffmpeg 真实分片，音轨可安全封装时一并 copy |
| DV / HDR | 电视按 `Display.HdrCapabilities` 决定，支持 DV / HDR10+ 就交给电视；桌面 libmpv 因缺少 libplacebo / RPU 仍不做 DV 直连。**DV 电视必须关隧道**并钉住 DV 视频轨 + AAC 音轨：MTK 电视开隧道只拿到 HEVC 解码器、输出会退化成 HDR10 基础层；`.m3u8` 按 HLS 声明，DV 硬解失败兜底加 `illegalstateexception`，解码诊断落日志 |
| 长按加速拖进度 | TV 遥控器左右键按住 **420 ms** 后升级为加速拖动，速度 4×→180× 指数增长，**松开才真正 seek**；短按仍是普通跳时间 |
| 跟手切集 | 上下滑切集在原生层用 `PlayerView.setOffset` 同步平移，相邻条目抽帧卡补屏，无缝 `pushReplacement` 无转场，修复换集黑屏 / 所有权竞争（`_active` / `claim()` / `isActiveInstance`） |
| 混合库播放 | 影视 / 图片混合库播放页改成「列表 + 删除当前影片」，去掉快退 / 快进；短剧换集预热相邻抽帧、抽帧占位到首帧 |
| 响度归一 | 库级开关随 `compat.audioNormalize` 下发；直连时播放器套 `dynaudnorm`，转码流由服务端处理 |
| 首片 | 2 秒分片 + `force_key_frames 2s` + 缩短 probesize ⇒ 同机首片约 1.1 s（不含色调映射） |
| 冷启动慢 | 8 s 那截是**硬件编码器探测**（逐个试编），探测结果落盘复用，第二次只要 0.3 s |
| seek | 目标还没转出来时**先等转码追上**（预算按差距给，3~10 s），等不到按「点了时间条」重建会话 |
| 停滞看门狗 | **页面级常驻**：画面 8 s 不动 → 续转 + 重新定位；再 8 s → 重建会话（5 分钟内最多 5 次） |
| 连按 | 260 ms 内的连按只落一次 seek（否则会把 mpv 的 seek 队列打乱，一次都不落地） |
| 基准 | 新建跳转会话时播放器还停在旧流上，**不能**把「旧流位置 + 新会话起点」相加（会翻倍） |
| HLS 列表 | 常规转码档用静态 VOD + ENDLIST 一次列全；原画直通读 ffmpeg 实际分片（关键帧不定长）；fMP4 只声明一次 `#EXT-X-MAP`（否则跨段拉不到 init 会 fatal） |

> 有一条反直觉但必须记住：**不能拿「播放器已缓冲到哪里」当跳转边界**。缓冲只有十几秒，用它当界限等于每次都重建会话，而 AV1 首片要 7.8~10.4 s，用户感知就是「AV1 拖不动」。

## 设计系统

`packages/nas_ui` 提供主题、组件与**选择态基座**：工具栏勾选进入、卡片勾选角标、内联操作条（全选 / 业务动作 / 关闭）。相册、影视、音乐的选中态统一走它，不各页各写一套。

## 无障碍与多端输入

- TV 外框：↑/↓ 按内容行移动，到页面最顶才回 tab；← → 横向移动焦点；OK 进入内容 / 确认。返回从内容区先回当前栏目的 tab，站在 tab 上第一次给退出提示、3 秒内再按一次才退出，其它任意键清零。
- TV 播放器：无操作栏时 OK = 暂停/继续、← → = 跳时间（**长按左右键加速拖动进度，松开才 seek**）；↓ 唤出操作栏（先落进度行），再按 ↓ 进入按钮行选字幕 / 音轨 / 画质；OK 在进度行收起操作栏、在按钮行执行；上下滑跟手切集；返回直接退出播放页。
- 键盘：空格播放/暂停、← 快退 10 s、→ 快进 30 s、↑↓ 切上一条/下一条（仅在有播放队列时接管）、F 全屏、M 静音。
- TV 与 PC 的跳转**走同一条 `_seekTo`**，只是键位布局按遥控器重新分配。

## i18n

- 语言清单在 `contracts/locales.json`：**13 种语言已登记**，目前启用 `zh-CN` 与 `en-US`。
- 客户端文案走 `tr(key, params)`，兜底顺序是「当前语言 → zh-CN → 键本身」。
- ⚠️ **缺键不会让 analyze 或 test 变红**，界面会直接显示 `music.play` 这种键名。所以新文案必须三处齐：`contracts/i18n.json` + 两个 messages 文件 + `npm run gen:i18n`。

## 相关页面

- [架构总览](Architecture)
- [功能模块](Modules)
- [开发指南](Development)
