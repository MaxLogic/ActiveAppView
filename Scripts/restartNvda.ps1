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
    Invoke-TaskKill -ImageName 'ctfmon.exe' -IgnoreFailure
    Invoke-TaskKill -ImageName 'TextInputHost.exe' -IgnoreFailure
    Invoke-ExecutableAndWait -FilePath (Join-Path $env:SystemRoot 'System32\ctfmon.exe') -ProcessName 'ctfmon'

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

    Invoke-TaskKill -ImageName 'xMouse.exe' -IgnoreFailure
    Invoke-ExecutableAndWait -FilePath $ResolvedMouseBeamExe -ProcessName 'xMouse'
}

function Wait-NvdaReplacement {
    param(
        [int[]]$PreviousProcessIds,
        [int]$TimeoutSeconds = 45
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $currentProcesses = @(Get-Process -Name 'nvda' -ErrorAction SilentlyContinue)
        if ($currentProcesses.Count -gt 0) {
            if ($PreviousProcessIds.Count -eq 0) {
                return $true
            }

            $oldProcesses = @($currentProcesses | Where-Object { $PreviousProcessIds -contains $_.Id })
            $newProcesses = @($currentProcesses | Where-Object { $PreviousProcessIds -notcontains $_.Id })
            if (($newProcesses.Count -gt 0) -and ($oldProcesses.Count -eq 0)) {
                return $true
            }
        }

        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    return $false
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

$previousNvdaIds = @(Get-Process -Name 'nvda' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Start-Process -FilePath $resolvedNvdaExe
if (-not (Wait-NvdaReplacement -PreviousProcessIds $previousNvdaIds)) {
    throw "NVDA did not replace the previous process within 45 seconds: $resolvedNvdaExe"
}

Invoke-MouseBeamRestart -ResolvedMouseBeamExe $resolvedMouseBeamExe
