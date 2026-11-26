@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo ==========================================================
echo  ColaPhoto HARMONYOS packaging (arm64)
echo    output: dist_installer\ColaNasOs-Photo-^<ver^>-harmony-arm64.hap
echo    bundleName: cola.nas.os.photo   (app name: ColaPhoto)
echo    toolchain : flutter_ohos 3.47.7-canary + DevEco SDK 26
echo    NOTE: signed with DevEco auto-signing (default_ohos_photo_*).
echo ==========================================================
echo.

set "APP=apps\colanas_os"
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "FLUTTER_OHOS=G:\work\_toolchain\flutter-ohos-3.47.7\bin\flutter.bat"
set "PUB_CACHE=G:\work\_pubcache"
set "JAVA_HOME=%DEVECO%\jbr"
set "DEVECO_SDK_HOME=%DEVECO%\sdk"
set "PATH=%JAVA_HOME%\bin;%DEVECO%\tools\ohpm\bin;%DEVECO%\tools\hvigor\bin;%PATH%"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

if not exist "%FLUTTER_OHOS%" (
  echo [x] flutter_ohos not found: %FLUTTER_OHOS%
  pause
  exit /b 1
)
if not exist "%APP%\ohos_photo" (
  echo [x] missing %APP%\ohos_photo
  pause
  exit /b 1
)
if exist "%APP%\ohos_main" (
  echo [x] %APP%\ohos_main exists - a previous build did not restore. Check manually.
  pause
  exit /b 1
)

echo [1/4] patch cnativeapi build hook (idempotent) ...
node tool\patch-cnativeapi.js
if errorlevel 1 (
  echo [x] patch-cnativeapi failed
  pause
  exit /b 1
)

echo.
echo [2/4] switch dirs: ohos -^> ohos_main, ohos_photo -^> ohos ...
ren "%APP%\ohos" ohos_main
ren "%APP%\ohos_photo" ohos

echo.
echo [3/4] flutter build hap --release --target lib/main_photo.dart ...
pushd "%APP%"
call "%FLUTTER_OHOS%" build hap --release --target lib/main_photo.dart
set "RC=!ERRORLEVEL!"
popd

rem restore dirs no matter success or fail
if exist "%APP%\ohos" ren "%APP%\ohos" ohos_photo
if exist "%APP%\ohos_main" ren "%APP%\ohos_main" ohos

if not "!RC!"=="0" (
  echo.
  echo [x] harmony build failed ^(exit !RC!^). Dirs restored to ohos_photo / ohos.
  pause
  exit /b !RC!
)

echo.
echo [4/4] copy to dist_installer\ ...
for /f "delims=" %%v in ('node -p "require('./package.json').version"') do set "VER=%%v"
if "%VER%"=="" set "VER=0.0.0"

set "SRC=%APP%\ohos_photo\entry\build\default\outputs\default\entry-default-signed.hap"
if not exist "%SRC%" set "SRC=%APP%\ohos_photo\entry\build\default\outputs\default\entry-default-unsigned.hap"
set "DST=dist_installer\ColaNasOs-Photo-%VER%-harmony-arm64.hap"
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
echo      bundleName: cola.nas.os.photo
echo      signed hap: install with hdc app install -r ^<file^>
pause
endlocal
