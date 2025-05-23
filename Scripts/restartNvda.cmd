@echo off


:: Restart NVDA
cd /d "C:\Program Files (x86)\NVDA"
start "" "nvda_slave.exe" launchNVDA -r

taskkill /IM DelphiLSP.exe /F
taskkill /IM xMouse.exe /F

:: xMouse.exe
cd /d "D:\Projects\MouseBeam\"
start xMouse.exe

exit
