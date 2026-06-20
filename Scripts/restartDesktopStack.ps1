#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$MouseBeamExe,
    [switch]$ResolveOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DesktopRecoveryHelpers.ps1')

function Resolve-LogiOptionsPlus {
    $fileName = 'logioptionsplus.exe'

    $path = Get-AppPathExecutable -FileName $fileName
    if ($path) {
        return $path
    }

    $command = Get-Command $fileName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (($null -ne $command) -and (Test-ExecutablePath -Path $command.Source -FileName $fileName)) {
        return $command.Source
    }

    $fallbackPaths = @(
        'C:\Program Files\LogiOptionsPlus\logioptionsplus.exe',
        'C:\Program Files (x86)\LogiOptionsPlus\logioptionsplus.exe'
    )

    foreach ($path in $fallbackPaths) {
        if (Test-ExecutablePath -Path $path -FileName $fileName) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Resolve-Everything {
    Resolve-ExecutablePath `
        -FileName 'Everything.exe' `
        -ProcessName 'Everything' `
        -FallbackPaths @('C:\Program Files\Everything\Everything.exe', 'C:\Program Files (x86)\Everything\Everything.exe')
}

function Invoke-AudioStackRestart {
    if ($null -eq (Get-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue)) {
        return
    }

    Stop-Service -Name 'Audiosrv' -Force -ErrorAction SilentlyContinue
    Invoke-TaskKill -ImageName 'audiodg.exe' -IgnoreFailure

    if ($null -ne (Get-Service -Name 'AudioEndpointBuilder' -ErrorAction SilentlyContinue)) {
        Stop-Service -Name 'AudioEndpointBuilder' -Force -ErrorAction SilentlyContinue
        Start-Service -Name 'AudioEndpointBuilder' -ErrorAction SilentlyContinue
    }

    Start-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue
}

function Invoke-EverythingRestart {
    param(
        [string]$ResolvedEverythingExe,
        [bool]$WasRunning
    )

    if (-not $WasRunning) {
        return
    }

    if (-not $ResolvedEverythingExe) {
        Write-Warning 'Everything was running, but the user executable could not be resolved.'
        return
    }

    $everythingProcesses = @(Get-Process -Name 'Everything' -ErrorAction SilentlyContinue |
        Where-Object { [string]::Equals($_.Path, $ResolvedEverythingExe, [System.StringComparison]::OrdinalIgnoreCase) })

    foreach ($process in $everythingProcesses) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }

    Start-Process -FilePath $ResolvedEverythingExe

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $started = $null -ne (Get-Process -Name 'Everything' -ErrorAction SilentlyContinue |
            Where-Object { [string]::Equals($_.Path, $ResolvedEverythingExe, [System.StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1)
        if ($started) {
            return
        }

        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Everything did not start within 15 seconds: $ResolvedEverythingExe"
}

function Invoke-WindowsKeyEscape {
    if (-not ('ActiveAppView.NativeKeyboard' -as [type])) {
        Add-Type -TypeDefinition @'
namespace ActiveAppView {
    using System;
    using System.Runtime.InteropServices;

    public static class NativeKeyboard {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    }
}
'@
    }

    $keyUp = 0x2
    $leftWindowsKey = 0x5B
    $escapeKey = 0x1B

    [ActiveAppView.NativeKeyboard]::keybd_event($leftWindowsKey, 0, 0, [UIntPtr]::Zero)
    [ActiveAppView.NativeKeyboard]::keybd_event($escapeKey, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [ActiveAppView.NativeKeyboard]::keybd_event($escapeKey, 0, $keyUp, [UIntPtr]::Zero)
    [ActiveAppView.NativeKeyboard]::keybd_event($leftWindowsKey, 0, $keyUp, [UIntPtr]::Zero)
}

function Invoke-MagnifierRestart {
    param(
        [bool]$WasRunning
    )

    if (-not $WasRunning) {
        return
    }

    Invoke-WindowsKeyEscape
    [void](Wait-ProcessState -ProcessName 'Magnify' -ShouldBeRunning $false -TimeoutSeconds 5)
    Invoke-ExecutableAndWait `
        -FilePath (Join-Path $env:SystemRoot 'System32\magnify.exe') `
        -ProcessName 'Magnify' `
        -ArgumentList @('/fullscreen')
}

$resolvedMouseBeamExe = Resolve-MouseBeamPath -ExplicitPath $MouseBeamExe
$resolvedEverythingExe = Resolve-Everything
$resolvedLogiOptionsPlusExe = Resolve-LogiOptionsPlus
$restartNvdaScript = Join-Path $PSScriptRoot 'restartNvda.ps1'
$magnifierWasRunning = $null -ne (Get-Process -Name 'Magnify' -ErrorAction SilentlyContinue)
$everythingWasRunning = $null -ne (Get-Process -Name 'Everything' -ErrorAction SilentlyContinue |
    Where-Object { [string]::Equals($_.Path, $resolvedEverythingExe, [System.StringComparison]::OrdinalIgnoreCase) } |
    Select-Object -First 1)

if ($ResolveOnly) {
    [pscustomobject]@{
        EverythingExe = $resolvedEverythingExe
        MouseBeamExe = $resolvedMouseBeamExe
        LogiOptionsPlusExe = $resolvedLogiOptionsPlusExe
        RestartNvdaScript = $restartNvdaScript
    }
    return
}

# We do not kill dwm.exe or sihost.exe here; both are session-critical.
foreach ($imageName in @(
    'explorer.exe',
    'ShellExperienceHost.exe',
    'StartMenuExperienceHost.exe',
    'SearchHost.exe',
    'SearchIndexer.exe',
    'SearchProtocolHost.exe',
    'SearchFilterHost.exe',
    'TextInputHost.exe',
    'ApplicationFrameHost.exe',
    'SystemSettings.exe',
    'Taskmgr.exe',
    'Start11_64.exe',
    'S11Search64.exe',
    'WidgetBoard.exe',
    'WidgetService.exe',
    'PhoneExperienceHost.exe',
    'YourPhoneAppProxy.exe',
    'CrossDeviceResume.exe',
    'CrossDeviceService.exe',
    'DelphiLSP.exe',
    'xMouse.exe',
    'logioptionsplus.exe',
    'logioptionsplus_agent.exe',
    'logioptionsplus_appbroker.exe',
    'logioptionsplus_updater.exe',
    'ArmouryCrate.exe',
    'ArmouryCrate.UserSessionHelper.exe',
    'ArmourySocketServer.exe',
    'ArmourySwAgent.exe',
    'ASUS DriverHub.exe',
    'asus_framework.exe',
    'ADU.exe',
    'AcPowerNotification.exe'
)) {
    Invoke-TaskKill -ImageName $imageName -IgnoreFailure
}

Start-Sleep -Seconds 1
Invoke-ExecutableAndWait -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ProcessName 'explorer' -TimeoutSeconds 30

Invoke-AudioStackRestart
Invoke-ServiceRestartIfPresent -Name 'ArmouryCrateService'
Invoke-ServiceRestartIfPresent -Name 'Start11'
Invoke-ServiceRestartIfPresent -Name 'WSearch'

if ($resolvedLogiOptionsPlusExe) {
    Invoke-ExecutableAndWait -FilePath $resolvedLogiOptionsPlusExe -ProcessName 'logioptionsplus'
}

Invoke-EverythingRestart -ResolvedEverythingExe $resolvedEverythingExe -WasRunning $everythingWasRunning
Invoke-MagnifierRestart -WasRunning $magnifierWasRunning

if (Test-Path -LiteralPath $restartNvdaScript -PathType Leaf) {
    & $restartNvdaScript -MouseBeamExe $resolvedMouseBeamExe
} else {
    Write-Warning "NVDA restart script not found: $restartNvdaScript"
}
