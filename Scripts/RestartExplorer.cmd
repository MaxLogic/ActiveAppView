@echo off
:: -------- shell ----------
taskkill /f /im explorer.exe >nul
timeout /t 1 >nul
runas /trustlevel:0x20000 "%SystemRoot%\explorer.exe"  >nul 2>&1

:: -------- tools ----------
for %%P in (DelphiLSP.exe xMouse.exe nvda.exe nvda_slave.exe) do taskkill /f /im %%P >nul
timeout /t 1 >nul
start "" "D:\Projects\MouseBeam\xMouse.exe"
start "" "C:\Program Files (x86)\NVDA\nvda_slave.exe" launchNVDA -r

:: -------- capslock off ----------
powershell -NoProfile -Command "$w=new-object -ComObject WScript.Shell; while([console]::CapsLock){$w.SendKeys('{CAPSLOCK}'); Start-Sleep -m 100}"
exit /b

rem ---------- 5. Restart Windows-Audio (fixes crackling) ----------------------------
net stop  audiosrv  /y   >nul
net start audiosrv       >nul
