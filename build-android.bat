@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================================
echo  ColaNasOs ANDROID CLIENT packaging (arm64)
echo    output: dist_installer\ColaNasOs-Client-^<ver^>-android-arm64.apk
echo    NOTE: the APK is a CLIENT. It connects to the server.
echo ==========================================================
echo.

set "FLUTTER=flutter"
where flutter >nul 2>nul || set "FLUTTER=C:\dev\flutter\bin\flutter.bat"
if not "%FLUTTER%"=="flutter" if not exist "%FLUTTER%" (
  echo [x] flutter not found: edit FLUTTER in this script
  pause
  exit /b 1
)

pushd apps\colanas_os
echo [1/2] flutter build apk --release --target-platform android-arm64 ...
call %FLUTTER% build apk --release --target-platform android-arm64
if errorlevel 1 (
  echo.
  echo [x] android build failed
  popd
  pause
  exit /b 1
)
popd

echo.
echo [2/2] copy to dist_installer\ with CLIENT naming ...
for /f "delims=" %%v in ('node -p "require('./package.json').version"') do set "VER=%%v"
if "%VER%"=="" set "VER=0.0.0"

set "SRC=apps\colanas_os\build\app\outputs\flutter-apk\app-release.apk"
set "DST=dist_installer\ColaNasOs-Client-%VER%-android-arm64.apk"
if not exist "%SRC%" (
  echo [x] missing %SRC%
  pause
  exit /b 1
)
if not exist dist_installer mkdir dist_installer
copy /y "%SRC%" "%DST%" >nul
if errorlevel 1 (
  echo [x] copy failed ^(file in use?^)
  pause
  exit /b 1
)

echo.
echo [ok] %DST%
echo      SHA256:
certutil -hashfile "%DST%" SHA256 | findstr /v ":"
echo.
echo      Same applicationId (com.colanas.os) installs as an upgrade.
echo      If Android says "app not installed", uninstall the old one first.
pause
endlocal
