@echo off
setlocal EnableExtensions

set "LOGI_OPTIONS_PLUS_EXE=C:\Program Files\LogiOptionsPlus\logioptionsplus.exe"
set "RESTART_NVDA_CMD=%~dp0restartNvda.cmd"
set "MAGNIFIER_MODE=/fullscreen"
set "MAGNIFIER_WAS_RUNNING="

tasklist /fi "imagename eq Magnify.exe" /nh | find /i "Magnify.exe" >nul 2>&1 && set "MAGNIFIER_WAS_RUNNING=1"

:: We do not kill dwm.exe or sihost.exe here; both are session-critical.
for %%P in (
  explorer.exe
  ShellExperienceHost.exe
  StartMenuExperienceHost.exe
  SearchHost.exe
  SearchIndexer.exe
  SearchProtocolHost.exe
  SearchFilterHost.exe
  TextInputHost.exe
  ApplicationFrameHost.exe
  Start11_64.exe
  WidgetBoard.exe
  WidgetService.exe
  PhoneExperienceHost.exe
  CrossDeviceService.exe
  DelphiLSP.exe
  xMouse.exe
  logioptionsplus.exe
  logioptionsplus_agent.exe
  logioptionsplus_appbroker.exe
  logioptionsplus_updater.exe
  ArmouryCrate.UserSessionHelper.exe
  ArmourySocketServer.exe
  Magnify.exe
) do call :KillProcess %%P

timeout /t 1 /nobreak >nul
start "" "%SystemRoot%\explorer.exe"

call :RestartAudioStack
call :RestartServiceIfPresent ArmouryCrateService
call :RestartServiceIfPresent Start11
call :RestartServiceIfPresent WSearch

if exist "%LOGI_OPTIONS_PLUS_EXE%" start "" "%LOGI_OPTIONS_PLUS_EXE%"

if defined MAGNIFIER_WAS_RUNNING (
  start "" "%SystemRoot%\System32\magnify.exe" %MAGNIFIER_MODE%
)

if exist "%RESTART_NVDA_CMD%" (
  call "%RESTART_NVDA_CMD%"
) else (
  if exist "C:\Program Files\NVDA\nvda.exe" start "" "C:\Program Files\NVDA\nvda.exe"
)

endlocal
exit /b 0

:RestartServiceIfPresent
sc query "%~1" >nul 2>&1 || exit /b 0
sc query "%~1" | find /i "RUNNING" >nul 2>&1 && net stop "%~1" /y >nul 2>&1
net start "%~1" >nul 2>&1
exit /b 0

:RestartAudioStack
sc query Audiosrv >nul 2>&1 || exit /b 0
net stop Audiosrv /y >nul 2>&1
if exist "%SystemRoot%\System32\audiodg.exe" call :KillProcess audiodg.exe
sc query AudioEndpointBuilder >nul 2>&1 && (
  net stop AudioEndpointBuilder /y >nul 2>&1
  net start AudioEndpointBuilder >nul 2>&1
)
net start Audiosrv >nul 2>&1
exit /b 0

:KillProcess
taskkill /f /im "%~1" >nul 2>&1
exit /b 0
