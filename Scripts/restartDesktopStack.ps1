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

function Invoke-AudioStackRestart {
    if ($null -eq (Get-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue)) {
        return
    }

    Stop-Service -Name 'Audiosrv' -Force -ErrorAction SilentlyContinue
    Invoke-TaskKill -ImageName 'audiodg.exe'

    if ($null -ne (Get-Service -Name 'AudioEndpointBuilder' -ErrorAction SilentlyContinue)) {
        Stop-Service -Name 'AudioEndpointBuilder' -Force -ErrorAction SilentlyContinue
        Start-Service -Name 'AudioEndpointBuilder' -ErrorAction SilentlyContinue
    }

    Start-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue
}

$resolvedMouseBeamExe = Resolve-MouseBeamPath -ExplicitPath $MouseBeamExe
$resolvedLogiOptionsPlusExe = Resolve-LogiOptionsPlus
$restartNvdaScript = Join-Path $PSScriptRoot 'restartNvda.ps1'
$magnifierWasRunning = $null -ne (Get-Process -Name 'Magnify' -ErrorAction SilentlyContinue)

if ($ResolveOnly) {
    [pscustomobject]@{
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
    'Start11_64.exe',
    'WidgetBoard.exe',
    'WidgetService.exe',
    'PhoneExperienceHost.exe',
    'CrossDeviceService.exe',
    'DelphiLSP.exe',
    'xMouse.exe',
    'logioptionsplus.exe',
    'logioptionsplus_agent.exe',
    'logioptionsplus_appbroker.exe',
    'logioptionsplus_updater.exe',
    'ArmouryCrate.UserSessionHelper.exe',
    'ArmourySocketServer.exe',
    'Magnify.exe'
)) {
    Invoke-TaskKill -ImageName $imageName
}

Start-Sleep -Seconds 1
Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe')

Invoke-AudioStackRestart
Invoke-ServiceRestartIfPresent -Name 'ArmouryCrateService'
Invoke-ServiceRestartIfPresent -Name 'Start11'
Invoke-ServiceRestartIfPresent -Name 'WSearch'

if ($resolvedLogiOptionsPlusExe) {
    Start-Process -FilePath $resolvedLogiOptionsPlusExe
}

if ($magnifierWasRunning) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\magnify.exe') -ArgumentList '/fullscreen'
}

if (Test-Path -LiteralPath $restartNvdaScript -PathType Leaf) {
    & $restartNvdaScript -MouseBeamExe $resolvedMouseBeamExe
} else {
    Write-Warning "NVDA restart script not found: $restartNvdaScript"
}
