BeforeAll {
    $script:togglePath = Join-Path $PSScriptRoot '..\x-mouse.ps1'
    $script:mouseBeamPath = 'F:\projects\MaxLogic\MouseBeam\xMouse.exe'
}

Describe 'MouseBeam toggle' {
    BeforeEach {
        Mock Test-Path { $true }
        Mock Get-Process { @() }
        Mock Start-Process { [pscustomobject]@{ Id = 456 } }
        Mock Stop-Process {}
        Mock Write-Error {}
        $mouseProcess = [pscustomobject]@{
            Id = 123
            Path = $script:mouseBeamPath.ToUpperInvariant()
            CloseRequested = $false
            WaitMilliseconds = 0
            CanClose = $true
            Exits = $true
        }
        $mouseProcess | Add-Member ScriptMethod CloseMainWindow {
            $this.CloseRequested = $true
            return $this.CanClose
        }
        $mouseProcess | Add-Member ScriptMethod WaitForExit {
            param($milliseconds)
            $this.WaitMilliseconds = $milliseconds
            return $this.Exits
        }
    }

    It 'closes the matching image gracefully, ignoring path case' {
        Mock Get-Process { $mouseProcess }
        $output = & $script:togglePath
        $LASTEXITCODE | Should -Be 0
        $mouseProcess.CloseRequested | Should -BeTrue
        $mouseProcess.WaitMilliseconds | Should -Be 2000
        $output | Should -Match 'gracefully.*123'
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'forces termination when graceful shutdown times out' {
        $mouseProcess.Exits = $false
        Mock Get-Process { $mouseProcess }
        $output = & $script:togglePath
        $LASTEXITCODE | Should -Be 0
        $mouseProcess.CloseRequested | Should -BeTrue
        $mouseProcess.WaitMilliseconds | Should -Be 2000
        $output | Should -Match 'force.*123'
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 123 -and $Force }
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'forces termination when no main window can close' {
        $mouseProcess.CanClose = $false
        Mock Get-Process { $mouseProcess }
        $output = & $script:togglePath
        $LASTEXITCODE | Should -Be 0
        $mouseProcess.WaitMilliseconds | Should -Be 0
        $output | Should -Match 'force.*123'
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 123 -and $Force }
    }

    It 'starts the executable when it is not running' {
        $output = & $script:togglePath
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Started.*456'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $script:mouseBeamPath -and $PassThru -and $WindowStyle -eq 'Hidden'
        }
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'ignores an xMouse instance at another image path' {
        $mouseProcess.Path = 'C:\Other\xMouse.exe'
        Mock Get-Process { $mouseProcess }
        & $script:togglePath
        $LASTEXITCODE | Should -Be 0
        $mouseProcess.CloseRequested | Should -BeFalse
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq $script:mouseBeamPath }
    }

    It 'reports a missing executable and exits with code 1' {
        Mock Test-Path { $false }
        & $script:togglePath
        $LASTEXITCODE | Should -Be 1
        Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter { $Message -like '*MouseBeam executable not found*' }
        Should -Invoke Get-Process -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
}
