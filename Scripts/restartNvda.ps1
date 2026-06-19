#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$NvdaExe,
    [string]$MouseBeamExe,
    [switch]$ResolveOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DesktopRecoveryHelpers.ps1')

function Invoke-TextInputRestart {
    Invoke-TaskKill -ImageName 'ctfmon.exe'
    Invoke-TaskKill -ImageName 'TextInputHost.exe'
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ctfmon.exe')

    Invoke-ServiceRestartIfPresent -Name 'TextInputManagementService'
    Invoke-ServiceRestartIfPresent -Name 'TabletInputService'
}

function Invoke-MouseBeamRestart {
    param(
        [string]$ResolvedMouseBeamExe
    )

    if (-not $ResolvedMouseBeamExe) {
        Write-Verbose 'MouseBeam executable was not found; skipping restart.'
        return
    }

    Invoke-TaskKill -ImageName 'xMouse.exe'
    Start-Process -FilePath $ResolvedMouseBeamExe
}

$resolvedNvdaExe = Resolve-ExecutablePath `
    -FileName 'nvda.exe' `
    -ProcessName 'nvda' `
    -ExplicitPath $NvdaExe `
    -FallbackPaths @('C:\Program Files\NVDA\nvda.exe', 'C:\Program Files (x86)\NVDA\nvda.exe')

$resolvedMouseBeamExe = Resolve-MouseBeamPath -ExplicitPath $MouseBeamExe

if ($ResolveOnly) {
    [pscustomobject]@{
        NvdaExe = $resolvedNvdaExe
        MouseBeamExe = $resolvedMouseBeamExe
    }
    return
}

if (-not $resolvedNvdaExe) {
    Write-Error 'NVDA executable was not found.'
    exit 1
}

Invoke-TextInputRestart

# A hard NVDA restart is more reliable when the old instance is frozen.
foreach ($imageName in @(
    'nvda.exe',
    'nvda_slave.exe',
    'nvda_synthDriverHost.exe',
    'nvdaHelperRemoteLoader.exe'
)) {
    Invoke-TaskKill -ImageName $imageName
}

Start-Sleep -Seconds 1
Start-Process -FilePath $resolvedNvdaExe

Invoke-MouseBeamRestart -ResolvedMouseBeamExe $resolvedMouseBeamExe
