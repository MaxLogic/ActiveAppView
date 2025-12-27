@echo off
taskkill /f /im ctfmon.exe >nul 2>&1
start "" "%SystemRoot%\System32\ctfmon.exe"

sc query TabletInputService | find /i "RUNNING" >nul && (
  net stop TabletInputService /y >nul 2>&1
)
net start TabletInputService >nul 2>&1
