# 发版与交付

> 一轮发版的完整动作。细节见仓库 `docs/05-工程与交付.md` §33。

## 版本号

语义化 `MAJOR.MINOR.PATCH`，**每轮打包/发版把补丁位 +1**（例如 1.5.6 → 1.5.7）。当前公开版 **v1.5.0**，主干 **1.5.7**（Android buildCode 78）。

```bash
node tool/version.js --set=1.5.7   # 等价 npm run version:sync -- --set=1.5.7
npm run sbom                        # ⚠️ 改完版本号必须跑，否则 sbom.check 会红
npm run version:check
```

它会一次同步：`package.json` / 四个 pubspec 的 `X.Y.Z+B`（build 号同时 +1）/ 鸿蒙 `versionCode` / `lib/core/app_version.dart`（客户端「关于」页显示的 `kAppVersion` / `kAppVersionCode`）。**单一真源是 `package.json.version`**，`app_version.dart` 由 `tool/version.js` 同步，勿手改。

产物目录 `D<NNN>` 单调递增；更新器按版本号选目录，回滚 = 指针切回上一目录。

## 打包

| 产物 | 命令 |
| --- | --- |
| Web（服务端内置界面） | `build-web.bat`（底层 `flutter build web --release --no-wasm-dry-run`） |
| 服务端安装器 | `npm run dist`（electron-builder → NSIS） |
| PC 客户端 | `node tool/build-client-installer.js`（→ 安装版 + 便携 zip） |
| 安卓（手机 / 平板） | `flutter build apk --release --target-platform android-arm64` |
| Android TV | `flutter build apk --release --target-platform android-arm64 --target lib/main_tv.dart --dart-define=COLANAS_TV=1` |
| 相册独立端 | `build-photo.bat`（底层 `flutter build apk --release --target lib/main_photo.dart --android-project-arg=nasApp=photo`，applicationId `com.colanas.photo`，与主客户端并存） |

产物统一落在 `dist_installer/`：

```
ColaNasOs-Server-<ver>-Setup.exe           服务端安装器（含 FFmpeg / llama / transmission / 模型）
ColaNasOs-Client-<ver>-Setup.exe           桌面客户端安装版
ColaNasOs-Client-<ver>-windows-x64.zip     桌面客户端便携包
ColaNasOs-Client-<ver>-android-arm64.apk   手机 / 平板
ColaNasOs-Client-<ver>-android-arm64-tv.apk 电视 / 盒子
ColaNasOs-Photo-<ver>-android-arm64.apk    相册独立端（待正式发版）
```

⚠️ 三份安卓包 `apk` / `apk_tv` / `apk_photo` 身份不同、**绝不互通**：客户端检查更新分别带 `build=phone|tv|photo`，服务端只回对应身份的包（本地调试可用 `COLANAS_LOCAL_PHOTO_APK_DIR` 指向相册包）。它们**体积可能一样**但 AOT 快照/applicationId 不同 —— 校验要用 `libapp.so` 的哈希与 manifest，不是看大小。

## 验收

### 结构校验

```bash
node tool/check/installer.js    # 产物结构：asar / web / contracts / 文件名
```

### 内容级验收（不能只看大小/哈希）

| 产物 | 看哪里 | 指纹 |
| --- | --- | --- |
| 服务端 | asar 内 `dist/electron/main.js`、`dist/kernel/index.js` | `app.getVersion()` 版本、`trayTip` |
| PC 客户端 | `data/app.so`（exe 只有 ~196 KB 启动壳，Dart AOT 在这） | `github.com/colaKot/ColaNasOs`、`player.stall/` |
| APK | `lib/arm64-v8a/libapp.so` | 版本串（如 `1.5.7`）、页面地址；相册包再核对 applicationId `com.colanas.photo` |
| Web | `build/web/main.dart.js` | ASCII 指纹 |

⚠️ **中文串在 dart2js / AOT 产物里会被转义**，用中文 grep 验证恒为 0 —— 必须用 ASCII 指纹。

### 门禁

```bash
npm run verify:fast      # 发版前
npm run verify:full      # 发版全量
```

### SHA256

```bash
cd dist_installer && sha256sum *<ver>*
```

校验值要写进 release 说明与官网。

## GitHub Release

```bash
git tag -a v1.5.7 -m "ColaNasOs 1.5.7"
git push origin main v1.5.7
```

release 说明按主题分组（新增 / 播放器 / 影视相册音乐 / 运维 / 升级说明 / 校验），资产一次性挂当前产物（相册端正式发版后为 6 个）。更新发布：`client_android.assets` 含 `apk` / `apk_tv` / `apk_photo` 三份包（`tool/release/release.js` 已加映射），`release/update.json` 当前尚未挂 `apk_photo`，发相册包时要补上。

> 上传大文件（服务端 550 MB）建议后台执行，别在前台等超时。

## 官网

官网源码在 `site/`，部署到 `cola.gexuan.net`（Nginx `root /srv/cola/www`）。

发版时要同步的内容：

1. 版本号（页面里所有 `1.5.x`）；
2. 下载表的**文件名、体积、链接**（新增产物就加一行）；
3. SHA256 清单；
4. 「已知限制 / 需要自行构建」这类描述（例如 Android TV 从「需自行构建」改成「已发布」）。

部署后用公网地址回读校验：文件 sha 必须与本地一致。

## 发布检查单

- [ ] `smoke:abi` 4/4
- [ ] 契约 diff 绿（`gen.check`）
- [ ] i18n 缺键 0
- [ ] 各端构建通过
- [ ] `installer.check` 全绿
- [ ] 内容级验收（ASCII 指纹）通过
- [ ] SHA256 已记录
- [ ] release 说明写好
- [ ] 官网同步并公网回读校验

## 相关页面

- [开发指南](Development)
- [运维手册](Operations) —— 更新与回滚
- [贡献与许可](Contributing)
