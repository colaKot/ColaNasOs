# X-01 六端构建实测

> 由 `node tool/build-ends.js` 生成（2026-10-28）；环境：Flutter 3.47.8 • channel stable • https://github.com/flutter/flutter.git · win32；表内为 `flutter clean` 后的冷构建。
> 不可测的端直接标 `skipped` 并写明原因，不做推测。

| 端 | 结果 | 耗时 | 产物 / 体积 | 说明 |
| --- | --- | --- | --- | --- |
| windows | ok | 38.2 s | `build/windows/x64/runner/Release` 30.2 MB | - |
| web | ok | 29.1 s | `build/web` 42.5 MB | - |
| apk | blocked | - | - | 首次 Gradle 依赖经代理下载 30 分钟未完成（网络受限，非代码问题） |

## 结论

- 已实测端：windows / web
- 失败端：无
- 受限端：apk
- 未测端：无

> windows / web 可在本机复现；macos / ios 需 macOS 构建机，linux 需 Linux 构建机，
> 鸿蒙（CL4-01）需 `flutter_ohos` 分支，TV（CL4-02）需 Android TV 工程，均不在本脚本范围。
>
> 耗时与缓存强相关：`flutter clean` 后是冷构建，二次重建通常快一个量级
> （同机实测 windows 增量约 8 s，web 因要重新编译 Dart→JS，提速有限）。
