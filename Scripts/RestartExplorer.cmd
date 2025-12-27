@echo off
setlocal ENABLEDELAYEDEXPANSION

:: --- Fast quiet kill helper
for %%P in (
  xMouse.exe
  nvda_slave.exe nvda.exe
  LogiOverlay.exe LogiOptionsMgr.exe LogiOptions.exe
  magnify.exe
  SearchHost.exe SearchUI.exe
  StartMenuExperienceHost.exe
  DelphiLSP.exe
  msedgewebview2.exe WidgetBoard.exe WidgetService.exe
) do (
  taskkill /f /im %%P >nul 2>&1
)

:: --- Restart shell quickly 
taskkill /f /im explorer.exe >nul 2>&1
timeout /t 1 /nobreak >nul
start "" "%SystemRoot%\explorer.exe"

:: --- Reset Text Services (CTF)
taskkill /f /im ctfmon.exe >nul 2>&1
start "" "%SystemRoot%\System32\ctfmon.exe"

:: --- Optional: Touch Keyboard & Handwriting Panel
sc query TabletInputService | find /i "RUNNING" >nul && (net stop TabletInputService /y >nul)
net start TabletInputService >nul

:: --- Restart Magnifier in a known mode (pick one)
:: /fullscreen  OR  /lens  OR  /docked
start "" "%SystemRoot%\System32\magnify.exe" /fullscreen

:: --- Restart Logitech Options (classic) if installed
if exist "C:\Program Files\Logitech\LogiOptions\LogiOptions.exe" (
  REM start "" "C:\Program Files\Logitech\LogiOptions\LogiOptions.exe"
)
:: --- Logitech Options+ (not classic) ---
for %%P in (logioptionsplus_appbroker.exe logioptionsplus_agent.exe logioptionsplus_updater.exe LogiOverlay.exe logioptionsplus.exe) do (
  taskkill /f /im %%P >nul 2>&1
)
:: Relaunch Options+ GUI (agent spawns the rest)
start "" "C:\Program Files\LogiOptionsPlus\logioptionsplus.exe"

:: --- ASUS Armoury Crate user-session bits (leave the service unless needed) ---
for %%P in (ArmouryCrate.UserSessionHelper.exe ArmourySocketServer.exe) do (
  taskkill /f /im %%P >nul 2>&1
)
:: optional: if issues persist, bounce the service (names vary by build)
net stop ArmouryCrateService   >nul 2>&1
net start ArmouryCrateService  >nul 2>&1

:: --- Nahimic (audio enhancement) ---
net stop  NahimicService  >nul 2>&1
taskkill /f /im NahimicService.exe
taskkill /f /im NahimicSvc.exe
REM net start NahimicService  >nul 2>&1

:: --- Tools
start "" "D:\Projects\MouseBeam\xMouse.exe"

:: --- Restart NVDA last (single clean re-launch)
start "" "C:\Program Files (x86)\NVDA\nvda.exe" -r

:: --- Optional: Audio service refresh 
net stop audiosrv /y >nul
net start audiosrv     >nul

endlocal
