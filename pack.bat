@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================================
echo  ColaNasOs 打包（免安装目录，供冒烟/交付前自检）
echo    产物：dist_installer\win-unpacked\
echo    正式安装器请用 dist.bat
echo ==========================================================
echo.

if not exist "node_modules\electron\dist\electron.exe" (
  echo [x] 缺少依赖：请先执行  npm install
  pause
  exit /b 1
)
if not exist "dist\kernel\index.js" (
  echo [1/3] 编译服务端...
  call npm run build || (echo [x] 编译失败 & pause & exit /b 1)
) else (
  echo [1/3] 服务端产物已存在（改过 TS 请先 npm run build）
)
if not exist "apps\colanas_os\build\web\index.html" (
  echo [!] 缺少 Web 产物：安装包内将没有界面。
  echo     请先执行 build-web.bat，或继续只验证内核外壳。
  pause
)
if not exist "vendor\models" (
  echo [!] 缺少 vendor\models：安装包不含本地 AI 模型（人脸/场景会不可用）。
  echo     需要时先执行  npm run ffmpeg:fetch  与模型下载流程。
)
echo [2/3] 打包免安装目录...
call npm run pack || (echo [x] 打包失败 & pause & exit /b 1)
echo [3/3] 校验产物结构...
call node tool\check\installer.js || (echo [x] 产物校验失败 & pause & exit /b 1)
echo.
echo [ok] 产物已生成：dist_installer\win-unpacked
echo      冒烟：npm run smoke:packaged
endlocal