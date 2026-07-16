@echo off
setlocal
chcp 65001 >nul
set "RUNNER=%~dp0tools\Run-SparrowRunnerGui.cmd"
if not exist "%RUNNER%" (
  echo [FATAL] Cannot find "%RUNNER%".
  pause
  exit /b 1
)
call "%RUNNER%"
exit /b %ERRORLEVEL%
