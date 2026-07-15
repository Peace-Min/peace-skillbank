@echo off
setlocal
chcp 65001 >nul
set "PROJECT=%~dp0SparrowRunner.Gui\SparrowRunner.Gui.csproj"
if not exist "%PROJECT%" (
  echo [FATAL] Cannot find "%PROJECT%".
  pause
  exit /b 1
)
dotnet run --project "%PROJECT%" -c Release
exit /b %ERRORLEVEL%
