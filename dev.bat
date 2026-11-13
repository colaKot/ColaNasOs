@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================================
echo  ColaNasOs 开发模式
echo    窗口1  内核（TS 改动自动编译 + 重启） http://127.0.0.1:7888
echo    窗口2  Flutter Web（热重载 + 控制口）   http://127.0.0.1:5173
echo          控制口 http://127.0.0.1:5174/status
echo  页面会自动打开；API 由 dart-define 固定指到内核 7888。
echo  注意：开发内核用 7888，正式服务端是 7788 —— 两套可以同时开，
echo        改代码/重启/清端口都不会碰到你正在用的那个服务端。
echo  ----------------------------------------------
echo  Flutter 那半边现在由脚本托管 stdin：
echo   - 改 packages\** 会自动热重启（不用再手敲 R）
echo   - 手动触发：curl -X POST "http://127.0.0.1:5174/hot-restart?token=colanas-dev-ctl"
echo ==========================================================
echo.

if not exist "node_modules\electron\dist\electron.exe" (
  echo [x] 缺少依赖：请先执行  npm install
  pause
  exit /b 1
)

set "FLUTTER=flutter"
where flutter >nul 2>nul || set "FLUTTER=C:\dev\flutter\bin\flutter.bat"
if not "%FLUTTER%"=="flutter" if not exist "%FLUTTER%" (
  echo [x] 找不到 flutter：请把 dev.bat 里的 FLUTTER 改成你的 flutter 路径
  pause
  exit /b 1
)

REM 端口分离：正式服务端固定 7788（start.bat / 安装版），开发内核固定 7888。
REM 不分开的话两件事会互相踩：① 同时启动必然 EADDRINUSE；② watch-kernel 的
REM 「端口自愈」会把占着 7788 的 electron 当残留内核 kill 掉 —— 也就是把你正在用的
REM 服务端杀掉。分开以后开发这套怎么折腾都碰不到正式那套。
set "PORT=7888"

REM 开发模式显式开启 dev-token + CORS（生产/start.bat 默认关闭）
set "COLANAS_DEV_TOKEN=1"
REM 固定 JWT 密钥：不设的话内核每次重启都会随机生成一把，改一行代码触发
REM watch 重启后，浏览器里的 token 就全废了（所有请求 401、列表变空，很容易
REM 被误判成"功能坏了"）。仅用于开发，生产部署**不要**设这个变量。
set "COLANAS_JWT_SECRET=colanas-dev-only-secret-change-me"
REM Flutter 控制口令牌：这口能热重启/退出开发进程，只绑 127.0.0.1 + 校验 token
set "COLANAS_CTL_TOKEN=colanas-dev-ctl"
REM 开发实例标记：内核启动时据此探活正式版（7788）。一旦发现另一个实例在跑，
REM 内核只保留界面与接口，跳过后台任务（扫描 / 刮削 / AI / 定时任务 / sidecar）。
REM 正式版（start.bat / 安装版）不设这个变量，行为完全不变。
set "COLANAS_DEV_INSTANCE=1"

REM 数据目录：默认**和正式服务端共用**同一个（%APPDATA%\colanas_os_server），
REM 所以开发时看到的相册 / 人物 / 场景识别结果 / 影片库 / AI 数据都是真实的，
REM 不用重新扫一遍几十万张照片。代价：两个内核同时开着写库时，后台任务（扫描、
REM 补 MD5、AI 识别）会各跑一遍，SQLite 偶尔要等锁。
REM 想完全隔离（比如要跑会改数据的迁移）就带参数启动：  dev.bat isolated
if /i "%~1"=="isolated" (
  set "COLANAS_DATA_DIR=%~dp0.devdata\db"
  REM 隔离目录下不存在「和正式版抢同一份数据」的问题：关掉重叠探活，
  REM 让这套隔离实例照常跑后台任务（试迁移 / 试扫描时行为完整）。
  set "COLANAS_DEV_PEER_CHECK=0"
  echo [i] 使用隔离数据目录 .devdata\db（看不到正式数据，适合试破坏性改动）
) else (
  echo [i] 数据目录与正式服务端共用（相册 AI / 影片库都是真实数据）
)

echo [1/2] 启动内核窗口（编译 + 监听 src/kernel/electron 变更）...
start "ColaNasOs Kernel (watch)" /D "%~dp0" cmd /k node tool\dev\watch-kernel.js

echo [2/2] 等待内核就绪...
timeout /t 8 >nul

echo 启动 Flutter Web 开发服务器（首次编译约 30-60 秒）...
cd /d "%~dp0apps\colanas_os"
REM 用守护脚本包一层，把 flutter 的 stdin 接管过来 —— 这样「R」可以由程序发，
REM 不用人到窗口里敲（改 packages\** 时脚本自己会发）。
REM 注意 `run` 子命令不能省：包装器是原样透传给 flutter 的，
REM 少了它 flutter 会报 `Could not find an option named "--web-port"` 直接退出（code 64），
REM 窗口一闪而过、浏览器也不会开。
node "%~dp0tool\dev\flutter-dev.js" run -d chrome --web-port 5173 --dart-define=COLANAS_API_BASE=http://127.0.0.1:7888
if errorlevel 1 (
  echo.
  echo [x] Flutter 启动失败。完整日志：.devdata\flutter-dev.log
  echo     窗口保持打开，方便看上面的报错。
  pause
)

endlocal