@echo off
setlocal EnableExtensions

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restartDesktopStack.ps1" %*
exit /b %ERRORLEVEL%
