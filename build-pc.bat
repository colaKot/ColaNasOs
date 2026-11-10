@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0\apps\colanas_os"

set "FLUTTER=flutter"
where flutter >nul 2>nul || set "FLUTTER=C:\dev\flutter\bin\flutter.bat"
if not "%FLUTTER%"=="flutter" if not exist "%FLUTTER%" (
  echo [x] flutter not found: edit FLUTTER in this script
  pause
  exit /b 1
)

echo ==== Flutter Windows desktop client ====
echo output: apps\colanas_os\build\windows\x64\runner\Release
echo.

call %FLUTTER% pub get
if errorlevel 1 (
  echo [x] pub get failed
  pause
  exit /b 1
)

call %FLUTTER% build windows --release
if errorlevel 1 (
  echo.
  echo [x] build failed. common causes:
  echo     1. Visual Studio "Desktop development with C++" not installed
  echo     2. Windows SDK missing
  echo     3. reg.exe blocked by security software ^(Flutter needs it to locate the SDK^)
  pause
  exit /b 1
)

echo.
echo [ok] done: %~dp0apps\colanas_os\build\windows\x64\runner\Release
echo      copy the WHOLE Release folder when distributing
pause
endlocal
