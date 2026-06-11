@echo off
setlocal EnableExtensions

set "NVDA_EXE=C:\Program Files\NVDA\nvda.exe"
set "MOUSEBEAM_EXE=D:\Projects\MouseBeam\xMouse.exe"

if not exist "%NVDA_EXE%" (
  echo NVDA not found: "%NVDA_EXE%"
  exit /b 1
)

call :RestartTextInput

:: A hard NVDA restart is more reliable when the old instance is frozen.
for %%P in (
  nvda.exe
  nvda_slave.exe
  nvda_synthDriverHost.exe
  nvdaHelperRemoteLoader.exe
) do call :KillProcess %%P

timeout /t 1 /nobreak >nul
start "" "%NVDA_EXE%"

call :RestartMouseBeam

endlocal
exit /b 0

:RestartTextInput
call :KillProcess ctfmon.exe
call :KillProcess TextInputHost.exe
start "" "%SystemRoot%\System32\ctfmon.exe"

call :RestartServiceIfPresent TextInputManagementService
call :RestartServiceIfPresent TabletInputService
exit /b 0

:RestartMouseBeam
if exist "%MOUSEBEAM_EXE%" (
  call :KillProcess xMouse.exe
  start "" "%MOUSEBEAM_EXE%"
)
exit /b 0

:RestartServiceIfPresent
sc query "%~1" >nul 2>&1 || exit /b 0
sc query "%~1" | find /i "RUNNING" >nul 2>&1 && net stop "%~1" /y >nul 2>&1
net start "%~1" >nul 2>&1
exit /b 0

:KillProcess
taskkill /f /im "%~1" >nul 2>&1
exit /b 0
