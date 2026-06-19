@echo off
setlocal EnableExtensions

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restartNvda.ps1" %*
exit /b %ERRORLEVEL%
