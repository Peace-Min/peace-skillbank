@echo off
REM dmp-triage offline installer - double-click me.
REM No admin rights needed: everything lands in your user profile.
setlocal
set "HERE=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%setup.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo Done.) else (echo Finished with code %RC%.)
echo Press any key to close...
pause >nul
exit /b %RC%
