#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $lExecutable = 'F:\projects\MaxLogic\MouseBeam\xMouse.exe'
    if (-not (Test-Path -LiteralPath $lExecutable -PathType Leaf)) {
        throw "MouseBeam executable not found: $lExecutable"
    }

    $lProcesses = @(Get-Process | Where-Object { $_.Path -ieq $lExecutable })
    if ($lProcesses.Count -eq 0) {
        $lStarted = Start-Process -FilePath $lExecutable -WindowStyle Hidden -PassThru
        Write-Output "Started MouseBeam (PID $($lStarted.Id))."
    }
    else {
        foreach ($lProcess in $lProcesses) {
            if ($lProcess.CloseMainWindow() -and $lProcess.WaitForExit(2000)) {
                Write-Output "Stopped MouseBeam gracefully (PID $($lProcess.Id))."
            }
            else {
                Stop-Process -Id $lProcess.Id -Force -ErrorAction Stop
                Write-Output "Stopped MouseBeam by force (PID $($lProcess.Id))."
            }
        }
    }
    exit 0
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
