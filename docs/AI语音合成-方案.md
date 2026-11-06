# AI 语音合成方案：Qwen3-TTS GGUF + llama.cpp (Vulkan)

> 2026-11-06 定稿。替换原来的 Kokoro v1.1-zh（ONNX + Python sidecar）与 Edge 在线兜底。
> 本文是**唯一真源**：目录布局、模型分发、接口变更、性能与回滚都以这里为准。

## 1. 一句话结论

本地合成走 `llama-tts`（llama.cpp 的 TTS 工具，Vulkan 加速）+ Qwen3-TTS-1.7B 的 Q4_K_M 量化模型。
**合成速度 1.2~1.46 倍实时**，纯离线、无需 Python，安装包因此瘦了近 300MB。

| 维度 | 旧方案（Kokoro ONNX） | 新方案（Qwen3-TTS GGUF） |
| --- | --- | --- |
| 推理后端 | onnxruntime（CPU） | llama.cpp + Vulkan（核显） |
| 速度 | 200 字 ≈ 88 秒（约 0.4× 实时） | **1.2~1.46× 实时** |
| 依赖 | Python 运行时 + kokoro-onnx + misaki-fork[zh] | **一个 exe + 两个 gguf，无运行时依赖** |
| 打包体积 | 模型 471MB + Python 运行时 304MB | 二进制 40MB + 音色 1.4MB（权重不进包） |
| 音色 | 6 个固定 speaker id | **任意参考音频（可克隆自己的声音）** |
| 隐私 | 本地（Edge 引擎会把稿件发到微软） | **纯本地，稿件不出机器** |
| 中文质量 | 好，但韵律靠 continuous 拼接 | 更好，整块生成，韵律连贯 |

## 2. 架构

```
┌──────────────── Flutter (apps/colanas_os) ────────────────┐
│  AI 新闻页：选音色（可试听/可上传） → 倍速 → 生成 → 播放  │
└───────────────┬───────────────────────────────────────────┘
                │ HTTP /api/v1/blog/*
┌───────────────▼──── 内核 kernel（TypeScript） ────────────┐
│ src/modules/blog/*        业务：抓新闻 → 写稿 → 合成 → 落库│
│ kernel/tts/engine.ts      切块 → spawn llama-tts → 拼接    │
│ kernel/tts/voices.ts      参考音色库（内置 + 用户上传）    │
│ kernel/tts/paths.ts       二进制 / 模型 / 音色路径解析     │
└───────┬──────────────────────────────┬────────────────────┘
        │ spawn（每块一次）              │ spawn
┌───────▼──────────┐          ┌────────▼─────────┐
│ vendor/llama/... │          │ ffmpeg           │
│ llama-tts.exe    │          │ 静音拼接 / 倍速  │
│ + ggml-vulkan.dll│          │ / mp3 编码       │
└───────┬──────────┘          └──────────────────┘
        │ 加载
┌───────▼────────────────────┐
│ models/qwen3-tts/          │
│  Qwen3-TTS-...Q4_K_M.gguf  │  ← talker（1.0GB）
│  mmproj-...Q8_0.gguf       │  ← 声码器/声学（0.4GB）
└────────────────────────────┘
```

**为什么不常驻一个服务**：`llama-tts` 是 llama.cpp 的一次性 CLI（`tools/tts`），没有 server 模式。
每块一次进程，模型加载约 3~6 秒，所以**块不能切太小**：默认 300 字一块，把加载开销摊到 15% 以内。

**为什么去掉 Python**：Kokoro 必须用 Python（中文 G2P 只有 misaki 能做）。GGUF 方案是纯二进制调用，
Node `spawn` 就够。`tool/bundle-python.js`、`vendor/python-runtime`（304MB）、
`sidecars/ai-tts/` 全部删除。

## 3. 目录与分发（开源项目的关键）

三层分离，各管各的：

| 层 | 放什么 | 大小 | 谁提供 |
| --- | --- | --- | --- |
| 仓库 | `kernel/tts/**`、`tool/tts-model.js`、`vendor/voices/*.wav` | < 2MB | 项目 |
| 安装包 | `vendor/llama/<平台>/`（推理程序） | ~40MB | 项目（随包） |
| 用户下载 | `*.gguf`（1.4GB 权重；源码态 `vendor/models/qwen3-tts/`，装机态 `<dataDir>/tts/models/qwen3-tts/`） | 1.4GB | **用户自己下（页面一键下载）** |

```
vendor/                               （源码态）
  llama/win32-x64/          llama-tts.exe + ggml-*.dll（.gitignore，随包提供二进制）
  models/qwen3-tts/         Talker + mmproj（.gitignore，不进包；源码用户跑脚本下载）
  voices/                   default.wav / warm.wav / deep.wav（进 git，进包）
resources/                            （装机态）
  llama/win32-x64/          推理程序（随包）
  voices/                   内置音色（随包）
  tool/tts-model.js         一键下载脚本（随包，files 里排除了 tool/** 所以单列）
<dataDir>/tts/                        （一键下载的落点，用户可写、升级不丢）
  llama/win32-x64/          需要补的推理程序（包里已带时跳过）
  models/qwen3-tts/         1.4GB 权重
  voices/                   用户上传的参考音
  preview/                  试听缓存
```

**权重不进安装包的理由**：1.4GB 会让 NSIS 包翻倍，而大部分用户不开播客。
安装包只带程序和 3 段音色——**开箱即有可用音色**，第一次生成前由页面的「一键下载」按钮补模型（见 3.2）。

### 3.1 下载（`npm run tts:model`）

```bash
npm run tts:check          # 体检：缺什么列什么
npm run tts:model          # 一键补齐（二进制 + 两个 gguf，自动校验 sha256）
npm run tts:model -- --bin-only      # 只补二进制
npm run tts:model -- --models-only   # 只补权重
```

脚本内置镜像策略（国内直连 GitHub / HuggingFace 都不通，实测）：

| 内容 | 首选 | 兜底 | 实测速度 |
| --- | --- | --- | --- |
| llama.cpp release | `gh-proxy.com` | `ghproxy.net` | 40MB/s |
| Qwen3-TTS 权重 | **ModelScope** | `hf-mirror.com` | 24MB/s（HF 镜像仅 0.5MB/s） |

手动下载也给得到（文档/Issue 里直接贴这两种链接）：

- 权重：<https://modelscope.cn/models/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF>
  或 <https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF>
  需要的两个文件：`Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf`、`mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf`
  → 放到 `vendor/models/qwen3-tts/`（装机版是 `resources/models/qwen3-tts/`）
- 推理程序：<https://github.com/ggml-org/llama.cpp/releases> 的 `llama-b12138-bin-win-vulkan-x64.zip`
  → 解压到 `vendor/llama/win32-x64/`

版本锁定：二进制默认 `b12138`（`COLANAS_TTS_BIN_TAG` 可改）。
**不要随便升级**：`llama-tts` 的 mmproj 生成器在快速迭代，跨版本可能读不了旧 gguf。

许可证：llama.cpp MIT；Qwen3-TTS `apache-2.0`；随包的 3 段参考音来自本项目自录素材。

### 3.2 首启一键下载（页面，Windows NAS）

脚本只是给源码用户 / 排障用的；**装机版用户不用开命令行**。AI 新闻页顶部常驻一张「语音模型」卡片：

| 状态 | 页面表现 |
| --- | --- |
| 未下载 | 说明「首次需下载约 1.4GB」+「一键下载」按钮 |
| 下载中 | 百分比 + 进度条 + 当前阶段（推理程序 / 主模型 / 声码器）+「取消下载」 |
| 已完成 | 绿色勾 +「已下载 · 可以离线合成」+ 模型目录 |
| 失败 | 错误原因 +「继续下载」（已下部分自动续传） |

- **只支持 Windows NAS**：`tool/tts-model.js` 的 `binAsset()` 只映射 `win32-x64` / `win32-arm64`，
  其它平台直接报「一键下载目前只支持 Windows NAS」。macOS / Linux 暂不适配。
- **「已下载」不写标记文件**：`kernel/tts/download.ts` 每次 `status()` 都实时探测磁盘
  （`llama-tts` + 两个 gguf 全在才算齐）。模型还在 → 以后每次进页面都是「已下载」；
  用户把文件删了 → 立刻变回未下载，不会出现「界面说有、实际跑不了」的假状态。
- **落盘位置**：`<dataDir>/tts/`（用户数据目录，升级不丢）。装机版 `resources/` 多半只读，
  不能往那里写；`setTtsHome()` 把这个目录插进 `paths.ts` 搜索根的最前面。
- **进度事件**：下载器 `--json` 模式 stdout 只输出 NDJSON，人类日志走 stderr；
  三个文件按体积加权（推理程序 3% / 主模型 67% / 声码器 30%），内核解析后前端每秒轮询一次。
- **下载完立刻可用**：`getTts()` 是进程级单例，首次进页面时模型还没下会把空路径固化。
  所以每次取用都调 `TtsEngine.refreshPaths()` 重新解析，不需要重启服务。
- **断点续传**：HTTP `Range` + sha256 校验；取消后已下载的字节保留，下次从断点接着下。
- **脚本随包**：`electron-builder.js` 把 `tool/tts-model.js` 单独放进 `resources/tool/`
  （`files` 里排除了 `tool/**`），内核用 `process.execPath` + `ELECTRON_RUN_AS_NODE=1`
  以 Node 模式拉起它。`tool/check/installer.js` 有对应门禁。

## 4. 音色

Qwen3-TTS-Base 是**声音克隆**模型：音色 = 一段参考音频，不是固定 speaker id。

| 音色 id | 来源 | 说明 |
| --- | --- | --- |
| `default` | 项目自录 | 主用音色，10 秒，24kHz 单声道 |
| `warm` | `default` 降 1 个半音 | 更沉稳，同一人的变体 |
| `deep` | `default` 降 3 个半音 | 低沉男声向，同一人的变体 |

> ⚠️ `warm` / `deep` 是**同一段录音的变调**，不是三个不同的人。
> 想要真正不同的人声：把 wav 丢进 `vendor/voices/`，或用页面上传。

上传：`POST /api/v1/blog/voices/upload`，body `{name, data: base64}`，上限 12MB，
服务端统一转 24kHz 单声道、最多截 30 秒（参考音越长 prompt 处理越慢）。
参考音太短（<2 秒）会被拒绝——模型学不到音色。

## 5. 实测数据（本机：Ryzen 7 7840HS / Radeon 780M / 24GB）

| 配置 | 生成耗时 | 音频时长 | 实时倍率 |
| --- | --- | --- | --- |
| Vulkan `-ngl 99`（预热后） | 6.87 / 6.92 s | 10.08 s | **1.46×** |
| 纯 CPU `-t 8` | 9.87 / 9.90 s | 10.83 s | 1.10× |
| Vulkan **首次**运行 | 8.98 s | 9.07 s | 1.01× |

- Vulkan 比 CPU 快约 **1.4 倍**。增幅有限的原因：780M 是核显（`uma: 1`，和 CPU 共用内存带宽），
  1.7B 的 Q4 模型本身是带宽受限任务。
- **首次运行慢是正常的**：Vulkan 要编译着色器（约 6 秒），之后走缓存。
  `warmup()` 就是把这个开销挪到进页面时，做完写 `.warm` 标记，不重复付钱。
- 端到端：569 字 / 3 块 → 1 分 40 秒音频，墙钟 1 分 22 秒（1.20×）；**1 万字 ≈ 24 分钟**。
- 每块一次模型加载约 5.7 秒 → 块从 200 字放到 400 字可再省约 10%（`COLANAS_TTS_CHUNK`）。

## 6. 接口变更（对前端/第三方 SDK 的影响）

| 变更 | 旧 | 新 |
| --- | --- | --- |
| 引擎选择 | `ttsEngine: 'local' \| 'edge'` | **删除字段**（只剩本地） |
| 音色清单 | 6 个固定 id（`zf_001`…） | 磁盘扫描：`{id, gender, builtin, label}` |
| 设置响应 | `ttsAvailable` | `ttsAvailable` + **`ttsReason`**（缺什么、跑哪条命令） |
| 新增 | — | `POST /blog/voices/upload`、`POST /blog/voices/remove` |
| 新增（一键下载） | — | `GET /blog/tts/model`、`POST /blog/tts/model/download`、`POST /blog/tts/model/cancel` |
| 试听 | `?voice=&engine=` | `?voice=`（engine 参数忽略） |

`BlogTtsModelResponse`：`{installed, downloading, percent, phase, task, error, binReady, modelReady, modelDir}`。
`task` 是 `bin / model1 / model2 / done / error / idle`，前端据此选本地化文案；
`phase` 是服务端的中文排障描述，**不要直接摆到 UI 上**。

设置里的旧音色 id（`zf_*` / `zm_*`）不会报错：解析不到时自动退回 `default`，并在日志里 warn 一次。

## 7. 环境变量（排查用）

| 变量 | 作用 |
| --- | --- |
| `COLANAS_TTS_DISABLED=1` | 关掉语音合成（settings 里 `ttsAvailable=false`） |
| `COLANAS_TTS_BIN` | 直指 `llama-tts.exe`（跨平台调试最省事） |
| `COLANAS_TTS_MODEL_DIR` | 直指 gguf 目录 |
| `COLANAS_TTS_VOICES_DIR` | 直指内置音色目录 |
| `COLANAS_TTS_NGL` | GPU 卸载层数，`0` = 纯 CPU |
| `COLANAS_TTS_THREADS` | CPU 线程数（默认 8） |
| `COLANAS_TTS_CHUNK` | 每块字数（默认 300，范围 80~1200） |
| `COLANAS_TTS_BIN_TAG` | 下载脚本用的 llama.cpp 版本 |
| `COLANAS_TTS_MODEL_SCRIPT` | 直指下载脚本（排障 / 用假脚本验证状态机） |
| `COLANAS_TTS_HOME` | 下载根目录（装机版由 `ttsModel.configure(dataDir)` 自动设置，一般不用手填） |

## 8. 代码清单

**新增**

- `kernel/tts/paths.ts` / `engine.ts` / `voices.ts` / `download.ts`（一键下载状态机）
- `tool/tts-model.js`（`npm run tts:model` / `tts:check`，`--json` NDJSON 进度、`--dest=` 自定义落点）
- `vendor/voices/{default,warm,deep}.wav`

**修改**

- `src/modules/blog/{generate,index,settings,schemas,schedule}.ts`
- `apps/colanas_os/lib/features/blog/ai_news_page.dart`
- `contracts/{openapi.json,i18n.json,messages/*.json}`（`npm run gen` 系列重新生成）
- `electron-builder.js`（去掉 python-runtime，加 llama/voices/tool/tts-model.js，排除 qwen3-tts）
- `tool/check/installer.js`（断言「有 llama/voices/下载脚本、无 qwen3-tts、无 python」）
- `package.json`（删 `python:bundle`，加 `tts:model` / `tts:check`）

**删除**（共释放约 775MB）

- `sidecars/ai-tts/`（560 行 Python sidecar）
- `kernel/sidecar/tts-bridge.ts`
- `tool/ai-blog/`（3 个 Kokoro 音色调研脚本）
- `tool/bundle-python.js`
- `docs/AI博客-音色库.md`
- `vendor/models/kokoro/`（471MB）、`vendor/python-runtime/`（304MB）

## 9. 回滚

旧实现**从未提交进 git**，所以删除前已打包备份：

```
G:\work\_backup\colanas-tts-kokoro-2026-11-06.zip   （含源码 + 回滚说明）
```

回滚步骤见压缩包内 `README-回滚说明.txt`：恢复 5 个路径 → 重新下载 Kokoro onnx 到
`vendor/models/kokoro/` → `npm run python:bundle` → 把 blog 模块与契约改回 `ttsEngine`。

## 10. 已知限制与后续

1. **单任务串行**：同一时间只允许一期生成（核显是独占资源）。并发会互相抢，反而更慢。
2. **没有 0.6B 的官方 GGUF**：`ggml-org` 只发布 1.7B。社区版（`Serveurperso/Qwen3-TTS-GGUF`）
   有 0.6B，但与当前 `llama-tts` 的 mmproj 兼容性未验证，暂不接入。
3. **参考音变体不是真多人**：`warm`/`deep` 是变调；要多人音色需录制或上传。
4. **跨平台**：一键下载**只支持 Windows NAS**（用户明确 macOS / Linux 不用管）。
   `paths.ts` 仍按 `win32-x64 / darwin-arm64 / linux-x64` 分目录，其它平台需手工放模型；
   下载器的 `binAsset()` 遇到非 win32 会直接报错，不会瞎下 Linux 包。
5. **进度不是单文件百分比**：三个文件按体积加权，所以「主模型」阶段进度走得最慢属正常。
6. **语速**：模型没有 speed 参数，倍速是 ffmpeg `atempo` 后处理（保音高，0.5~2.0）。
   模型原生语速偏快（实测标称 1.0 约 348 汉字/分钟），所以引擎里加了基准校准
   `TEMPO_CALIBRATION = 0.8`：UI 的 1.0 仍是「正常」，实际落到 `atempo=0.8`，
   约 278 汉字/分钟；相对倍速关系不变，已存配置无需迁移。见 `kernel/tts/engine.ts`。

## 11. 排查速查

| 现象 | 原因 / 处理 |
| --- | --- |
| 音色卡片报「缺少 …gguf」 | 点页面「一键下载」，或源码用户跑 `npm run tts:model` |
| 装机版点「一键下载」报找不到脚本 | `resources/tool/tts-model.js` 没打进包；查 `electron-builder.js` 的 `tool` extraResources |
| 进度卡在 99.9% 很久 | 正在做 sha256 校验（1.4GB 读盘），不是死机 |
| 下载中断 / 取消后重下 | 断点续传，已下字节保留；若报「校验失败」会自动删损坏文件，再点一次即可 |
| 下完了仍提示「语音合成不可用」 | 刷新一次页面；`getTts()` 每次取用会 `refreshPaths()`，若仍不行看设置的 `ttsReason` |
| 第一次合成特别慢 | Vulkan 着色器编译，属正常；后续走缓存 |
| `Flash Attention … assigned to CPU` 警告 | Vulkan 后端不支持 K/V 行的 FA，自动降级，不影响正确性 |
| 合成出来是杂音/念错 | 参考音不是 24kHz 单声道；用页面上传（服务端会自动归一化） |
| `退出码 0xC0000135` | 缺 DLL：`vendor/llama/<平台>/` 要整个目录一起放，不能只拷 exe |
| 装机版提示找不到模型 | 装机版模型路径是 `resources/models/qwen3-tts/`，不是 `vendor/` |
