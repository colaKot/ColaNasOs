@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================================
echo  ColaNasOs PC CLIENT packaging (Flutter desktop)
echo    output: dist_installer\ColaNasOs-Client-^<ver^>-Setup.exe
echo            dist_installer\ColaNasOs-Client-^<ver^>-windows-x64.zip
echo    NOTE: this is the CLIENT. Server installer: dist.bat
echo ==========================================================
echo.

set "FLUTTER=flutter"
where flutter >nul 2>nul || set "FLUTTER=C:\dev\flutter\bin\flutter.bat"
if not "%FLUTTER%"=="flutter" if not exist "%FLUTTER%" (
  echo [x] flutter not found: edit FLUTTER in this script
  pause
  exit /b 1
)

echo [1/2] build + package client ...
call node tool\build-client-installer.js
if errorlevel 1 (
  echo.
  echo [x] client packaging failed. common causes:
  echo     1. Visual Studio "Desktop development with C++" not installed
  echo     2. Windows SDK missing
  echo     3. reg.exe blocked by security software
  pause
  exit /b 1
)

echo.
echo [2/2] check artifacts ...
call node tool\check\installer.js
echo.
echo [ok] done. installer + portable zip are in dist_installer\
echo      unsigned build: SmartScreen may warn on first run
pause
endlocal
