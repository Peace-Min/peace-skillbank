@echo off
REM peace-skillbank - complete uninstall. Double-click me.
REM Shows a plan first and asks before deleting anything. No admin needed.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-peace-skillbank.ps1" %*
echo.
echo Press any key to close...
pause >nul
