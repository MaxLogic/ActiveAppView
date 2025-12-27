@echo off


:: Reload NVDA (To clear its internal event queue)
:: We use -r to tell NVDA to restart itself gracefully if running
start "" "C:\Program Files (x86)\NVDA\nvda.exe" -r

taskkill /IM DelphiLSP.exe /F
taskkill /IM xMouse.exe /F

:: xMouse.exe
cd /d "D:\Projects\MouseBeam\"
start xMouse.exe

:: --- 4) Input stack resets ---
:: 4a) CTF / Text Services Framework
taskkill /f /im ctfmon.exe >nul 2>&1
start "" %SystemRoot%\System32\ctfmon.exe

:: 4b) Windows Search front-end (auto-respawns)
for %%Q in (SearchHost.exe SearchUI.exe) do taskkill /f /im %%Q >nul 2>&1

:: 4c) Start menu host (optional)
taskkill /f /im StartMenuExperienceHost.exe >nul 2>&1

:: 4d) Touch Keyboard & Handwriting Panel Service (optional)
sc query TabletInputService | find /i "RUNNING" >nul && (net stop TabletInputService /y >nul)

:: ---------- 5. Restart Windows-Audio (fixes crackling) ----------------------------
net stop  audiosrv  /y   >nul
net start audiosrv       >nul


exit
