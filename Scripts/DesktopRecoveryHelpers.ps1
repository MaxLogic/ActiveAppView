#Requires -Version 5.1
Set-StrictMode -Version Latest

function Test-ExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not (Test-Path -LiteralPath $expandedPath -PathType Leaf)) {
        return $false
    }

    return [string]::Equals((Split-Path -Leaf $expandedPath), $FileName, [System.StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-ExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$CommandLine,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }

    $value = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    $candidates = @()

    if ($value -match '^\s*"([^"]+)"') {
        $candidates += $Matches[1]
    }

    if ($value -match '^\s*([^\s]+)') {
        $candidates += $Matches[1]
    }

    $candidates += $value

    foreach ($candidate in $candidates) {
        if (Test-ExecutablePath -Path $candidate -FileName $FileName) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-ProcessExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { Test-ExecutablePath -Path $_.Path -FileName $FileName } |
        Select-Object -ExpandProperty Path -First 1
}

function Get-AppPathExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $appPathKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\$FileName",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\$FileName",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$FileName"
    )

    foreach ($key in $appPathKeys) {
        $item = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            continue
        }

        $value = $item.GetValue('')
        $path = ConvertTo-ExecutablePath -CommandLine ([string]$value) -FileName $FileName
        if ($path) {
            return $path
        }
    }

    return $null
}

function Get-RunKeyExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $runKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )

    foreach ($key in $runKeys) {
        $item = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            continue
        }

        foreach ($valueName in $item.GetValueNames()) {
            $value = [string]$item.GetValue($valueName)
            if ($value -notmatch [regex]::Escape($FileName)) {
                continue
            }

            $path = ConvertTo-ExecutablePath -CommandLine $value -FileName $FileName
            if ($path) {
                return $path
            }
        }
    }

    return $null
}

function Get-StartupShortcutExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $startupDirs = @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell

        foreach ($startupDir in $startupDirs) {
            if ([string]::IsNullOrWhiteSpace($startupDir) -or -not (Test-Path -LiteralPath $startupDir -PathType Container)) {
                continue
            }

            $targetBaseName = [IO.Path]::GetFileNameWithoutExtension($FileName)
            $shortcuts = Get-ChildItem -LiteralPath $startupDir -Filter '*.lnk' -File -ErrorAction SilentlyContinue |
                Where-Object {
                    ($_.BaseName -like "*$targetBaseName*") -or ($_.BaseName -like "*$FileName*")
                }
            foreach ($shortcutFile in $shortcuts) {
                $shortcut = $shell.CreateShortcut($shortcutFile.FullName)
                $path = ConvertTo-ExecutablePath -CommandLine $shortcut.TargetPath -FileName $FileName
                if ($path) {
                    return $path
                }
            }
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }

    return $null
}

function Resolve-ExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [string]$ExplicitPath,
        [string]$EnvironmentVariableName,
        [string[]]$FallbackPaths = @()
    )

    $paths = @()

    if ($ExplicitPath) {
        $paths += $ExplicitPath
    }

    if ($EnvironmentVariableName) {
        $paths += [Environment]::GetEnvironmentVariable($EnvironmentVariableName, 'Process')
        $paths += [Environment]::GetEnvironmentVariable($EnvironmentVariableName, 'User')
        $paths += [Environment]::GetEnvironmentVariable($EnvironmentVariableName, 'Machine')
    }

    foreach ($path in $paths) {
        if (Test-ExecutablePath -Path $path -FileName $FileName) {
            return (Resolve-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($path.Trim()))).Path
        }
    }

    $path = Get-ProcessExecutablePath -ProcessName $ProcessName -FileName $FileName
    if ($path) {
        return $path
    }

    $path = Get-AppPathExecutable -FileName $FileName
    if ($path) {
        return $path
    }

    $path = Get-RunKeyExecutable -FileName $FileName
    if ($path) {
        return $path
    }

    $path = Get-StartupShortcutExecutable -FileName $FileName
    if ($path) {
        return $path
    }

    $command = Get-Command $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (($null -ne $command) -and (Test-ExecutablePath -Path $command.Source -FileName $FileName)) {
        return $command.Source
    }

    foreach ($path in $FallbackPaths) {
        if (Test-ExecutablePath -Path $path -FileName $FileName) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Invoke-TaskKill {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageName,

        [int]$TimeoutSeconds = 10,

        [switch]$IgnoreFailure
    )

    $processName = Get-ProcessNameFromImageName -ImageName $ImageName
    if ($null -eq (Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return
    }

    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = (Join-Path $env:SystemRoot 'System32\taskkill.exe')
    $processInfo.Arguments = "/f /im `"$ImageName`""
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardError = $true
    $processInfo.RedirectStandardOutput = $true

    $process = [Diagnostics.Process]::Start($processInfo)
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        if ($IgnoreFailure) {
            Write-Warning "Could not stop cleanup process $ImageName; continuing."
            return
        }

        throw "taskkill failed for $ImageName with exit code $($process.ExitCode)"
    }

    $effectiveTimeoutSeconds = $TimeoutSeconds
    if ($IgnoreFailure) {
        $effectiveTimeoutSeconds = [Math]::Min($TimeoutSeconds, 1)
    }

    if (-not (Wait-ProcessState -ProcessName $processName -ShouldBeRunning $false -TimeoutSeconds $effectiveTimeoutSeconds)) {
        if ($IgnoreFailure) {
            Write-Warning "Process is still running after restart cleanup attempt: $ImageName"
            return
        }

        throw "Process did not stop within $TimeoutSeconds seconds: $ImageName"
    }
}

function Invoke-ServiceRestartIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return
    }

    if ($service.Status -eq 'Running') {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }

    Start-Service -Name $Name -ErrorAction SilentlyContinue
}

function Resolve-MouseBeamPath {
    param(
        [string]$ExplicitPath
    )

    Resolve-ExecutablePath `
        -FileName 'xMouse.exe' `
        -ProcessName 'xMouse' `
        -ExplicitPath $ExplicitPath `
        -EnvironmentVariableName 'MOUSEBEAM_EXE' `
        -FallbackPaths @('D:\Projects\MouseBeam\xMouse.exe', 'D:\Projects\MouseBeam\src\xMouse.exe')
}

function Get-ProcessNameFromImageName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageName
    )

    [IO.Path]::GetFileNameWithoutExtension($ImageName)
}

function Wait-ProcessState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [Parameter(Mandatory = $true)]
        [bool]$ShouldBeRunning,

        [int]$TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $isRunning = $null -ne (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($isRunning -eq $ShouldBeRunning) {
            return $true
        }

        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    return $false
}

function Invoke-ExecutableAndWait {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [string[]]$ArgumentList = @(),

        [int]$TimeoutSeconds = 15
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Executable not found: $FilePath"
    }

    if ($ArgumentList.Count -gt 0) {
        Start-Process -FilePath $FilePath -ArgumentList $ArgumentList
    } else {
        Start-Process -FilePath $FilePath
    }

    if (-not (Wait-ProcessState -ProcessName $ProcessName -ShouldBeRunning $true -TimeoutSeconds $TimeoutSeconds)) {
        throw "Process did not start within $TimeoutSeconds seconds: $ProcessName ($FilePath)"
    }
}
