@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0\apps\colanas_os"

set "FLUTTER=flutter"
where flutter >nul 2>nul || set "FLUTTER=C:\dev\flutter\bin\flutter.bat"
if not "%FLUTTER%"=="flutter" if not exist "%FLUTTER%" (
  echo [x] 找不到 flutter：请把脚本里的 FLUTTER 改成你的 flutter 路径
  pause
  exit /b 1
)

echo 构建 Flutter Web 产物 → apps\colanas_os\build\web
REM --no-wasm-dry-run：Flutter 3.47 默认会在 dart2js 之后额外跑一遍 dart2wasm「演练编译」
REM （本仓库不发 wasm），实测让热缓存构建从 ~12s 变成 ~37s。省掉这一遍。
call %FLUTTER% build web --release --no-wasm-dry-run
if errorlevel 1 (
  echo [x] Web 构建失败
  pause
  exit /b 1
)
echo.
echo [ok] 产物已更新：内核重启后即可在 http://127.0.0.1:7788 访问
endlocal