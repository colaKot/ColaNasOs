@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================================
echo  ColaNasOs packaging - SERVER only (this script)
echo    server : dist_installer\ColaNasOs-Server-^<ver^>-Setup.exe (tray + kernel + web)
echo    client : build-pc.bat      -^> dist_installer\ColaNasOs-Client-^<ver^>-Setup.exe
echo    android: build-android.bat -^> dist_installer\ColaNasOs-Client-^<ver^>-android-arm64.apk
echo    macOS  : .dmg (run on macOS)
echo    Linux  : .AppImage / .deb (run on Linux)
echo ==========================================================
echo.

if not exist "node_modules\electron\dist\electron.exe" (
  echo [x] 缺少依赖：请先执行  npm install
  pause
  exit /b 1
)
if not exist "apps\colanas_os\build\web\index.html" (
  echo [x] 缺少 Web 产物：安装包内会没有界面。
  echo     请先执行  build-web.bat
  pause
  exit /b 1
)
if not exist "dist\kernel\index.js" (
  echo [1/3] 编译服务端...
  call npm run build || (echo [x] 编译失败 & pause & exit /b 1)
) else (
  echo [1/3] 服务端产物已存在（改过 TS 请先 npm run build）
)
if not exist "vendor\models" (
  echo [!] 缺少 vendor\models：安装包不含本地 AI 模型（人脸/场景会不可用）。
)
echo [2/3] 生成安装器...
call npm run dist || (echo [x] 打包失败 & pause & exit /b 1)
echo [3/3] 校验安装器产物...
call node tool\check\installer.js || (echo [x] 产物校验失败 & pause & exit /b 1)
echo.
echo [ok] server installer: dist_installer\ColaNasOs-Server-^<ver^>-Setup.exe
echo      client: build-pc.bat   android: build-android.bat
echo      unsigned build: electron-builder skips signing (see "signing is skipped")
endlocal