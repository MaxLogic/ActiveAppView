@echo off
setlocal EnableExtensions

for %%P in (
  PhoneExperienceHost.exe
  CrossDeviceService.exe
) do call :KillProcess %%P

call :StopServiceIfPresent PhoneSvc
call :StopServiceIfPresent CDPSvc
call :StopMatchingServices CDPUserSvc_
call :StopMatchingServices DevicesFlowUserSvc_

endlocal
exit /b 0

:StopMatchingServices
for /f "tokens=2 delims=:" %%S in ('sc query state^= all ^| findstr /r /c:"SERVICE_NAME: %~1"') do (
  for /f "tokens=* delims= " %%T in ("%%S") do call :StopServiceIfPresent %%T
)
exit /b 0

:StopServiceIfPresent
sc query "%~1" >nul 2>&1 || exit /b 0
net stop "%~1" /y >nul 2>&1
exit /b 0

:KillProcess
taskkill /f /im "%~1" >nul 2>&1
exit /b 0
