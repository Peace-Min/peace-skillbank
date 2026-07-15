@echo off
setlocal
set "SCRIPT=%~dp0Run-SparrowCommentFix.ps1"
if not exist "%SCRIPT%" (
  echo [FATAL] Cannot find "%SCRIPT%".
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%SCRIPT%"
exit /b %ERRORLEVEL%
