@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================================
echo  ColaNasOs PHOTO (album) app packaging (arm64)
echo    output: dist_installer\ColaNasOs-Photo-^<ver^>-android-arm64.apk
echo    NOTE: standalone album client. Same version as the main app.
echo    It is built from apps\colanas_os with -PnasApp=photo,
echo    so it keeps the whole native set (backup service, update
echo    installer, FileProvider) and only changes applicationId.
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
echo [1/2] flutter build apk --release --target lib/main_photo.dart -PnasApp=photo ...
call %FLUTTER% build apk --release --target-platform android-arm64 --target lib/main_photo.dart --android-project-arg=nasApp=photo
if errorlevel 1 (
  echo.
  echo [x] android build failed
  popd
  pause
  exit /b 1
)
popd

echo.
echo [2/2] copy to dist_installer\ with PHOTO naming ...
for /f "delims=" %%v in ('node -p "require('./package.json').version"') do set "VER=%%v"
if "%VER%"=="" set "VER=0.0.0"

set "SRC=apps\colanas_os\build\app\outputs\flutter-apk\app-release.apk"
set "DST=dist_installer\ColaNasOs-Photo-%VER%-android-arm64.apk"
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
echo      applicationId: com.colanas.photo (installs side by side with the main client).
echo      Update check uses component=client_android^&build=photo, so it only
echo      ever receives ColaNasOs-Photo-*.apk.
pause
endlocal
