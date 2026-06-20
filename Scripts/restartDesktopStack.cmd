@echo off
setlocal EnableExtensions

set "RESTART_SCRIPT=%~dp0restartDesktopStack.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -WindowStyle Hidden -FilePath powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%RESTART_SCRIPT%"" %*'"
exit /b 0
