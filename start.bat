@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================================
echo  ColaNasOs 启动（桌面外壳 + 内核 + Web）
echo    内核 / Web 同源：http://127.0.0.1:7788
echo    浏览器也可以直接打开上面这个地址使用 Web 版
echo ==========================================================
echo.

if not exist "node_modules\electron\dist\electron.exe" (
  echo [x] 缺少依赖：请先执行  npm install
  pause
  exit /b 1
)
if not exist "dist\kernel\index.js" (
  echo [1/2] 编译服务端...
  call npm run build || (echo [x] 编译失败 & pause & exit /b 1)
)
if not exist "apps\colanas_os\build\web\index.html" (
  echo [!] 还没构建 Web 产物，窗口只会显示 API 健康页。
  echo     需要 Web 界面请先执行  build-web.bat
  echo.
)

echo [2/2] 启动桌面外壳（内核端口 7788）...
call npm start

endlocal