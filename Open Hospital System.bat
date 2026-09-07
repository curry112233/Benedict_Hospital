@echo off
setlocal
cd /d "%~dp0hospital-app"

where npm >nul 2>nul
if errorlevel 1 (
  echo Node.js and npm are required. Install Node.js from https://nodejs.org/ and run this file again.
  pause
  exit /b 1
)

if not exist "node_modules\vite\bin\vite.js" (
  echo Installing hospital system dependencies...
  call npm install
  if errorlevel 1 (
    echo Dependency installation failed.
    pause
    exit /b 1
  )
)

start "Benedict Hospital System" cmd /k "cd /d "%~dp0hospital-app" && npm run dev:full"
timeout /t 3 /nobreak >nul
start "" "http://127.0.0.1:5173/"
endlocal
