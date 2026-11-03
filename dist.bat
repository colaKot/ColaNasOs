@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================================
echo  ColaNasOs 交付打包（平台安装器）
echo    Windows → dist_installer\ColaNasOs-Setup-<版本>.exe（NSIS）
echo    macOS   → .dmg（需在 macOS 上执行）
echo    Linux   → .AppImage / .deb（需在 Linux 上执行）
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
echo [ok] 安装器已生成到 dist_installer\
echo      注意：未配置代码签名证书时 electron-builder 会跳过签名（日志 signing is skipped）
echo      干净机器安装验收请另行执行（当前门禁不含真实安装/卸载）
endlocal