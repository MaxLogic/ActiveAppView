BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\ClipboardImage.psm1'
    Import-Module -Name $modulePath -Force -ErrorAction SilentlyContinue
}

Describe 'Save-ClipboardImage' {
    BeforeEach {
        # The live clipboard is shared mutable state and cannot be isolated reliably in automated tests.
        Mock Get-ClipboardImage -ModuleName ClipboardImage {
            $lImage = [System.Drawing.Bitmap]::new(1, 1)
            $lImage.SetPixel(0, 0, [System.Drawing.Color]::FromArgb(255, 10, 20, 30))
            return $lImage
        }
        # The live clipboard is shared mutable state and cannot be isolated reliably in automated tests.
        Mock Set-Clipboard -ModuleName ClipboardImage {
            param([object]$Value)

            $null = $Value
        }
    }

    It 'saves a clipboard image as PNG and copies the full path' {
        $lPath = Save-ClipboardImage

        try {
            $lPath | Should -Match 'screenshot_\d{8}_\d{6}_\d{3}(?:_\d+)?\.png$'
            [IO.Path]::IsPathFullyQualified($lPath) | Should -BeTrue
            Test-Path -LiteralPath $lPath -PathType Leaf | Should -BeTrue
            Should -Invoke Set-Clipboard -ModuleName ClipboardImage -Times 1 -Exactly -ParameterFilter {
                $Value -eq $lPath
            }
        }
        finally {
            if ($lPath -and (Test-Path -LiteralPath $lPath)) {
                Remove-Item -LiteralPath $lPath -Force
            }
        }
    }

    It 'inverts a saved PNG in place while preserving alpha' {
        $lPath = Save-ClipboardImage

        try {
            ConvertTo-InvertedClipboardPng -Path $lPath

            $lBitmap = [System.Drawing.Bitmap]::FromFile($lPath)
            try {
                $lPixel = $lBitmap.GetPixel(0, 0)
                $lPixel.A | Should -Be 255
                $lPixel.R | Should -Be 245
                $lPixel.G | Should -Be 235
                $lPixel.B | Should -Be 225
            }
            finally {
                $lBitmap.Dispose()
            }
        }
        finally {
            if ($lPath -and (Test-Path -LiteralPath $lPath)) {
                Remove-Item -LiteralPath $lPath -Force
            }
        }
    }

    It 'fails without changing the clipboard when no image is present' {
        # The live clipboard is shared mutable state and cannot be isolated reliably in automated tests.
        Mock Get-ClipboardImage -ModuleName ClipboardImage {
            return $null
        }
        # Live audio playback is device-dependent and disruptive in an automated test.
        Mock Invoke-ClipboardNoImageNotification -ModuleName ClipboardImage {}

        { Save-ClipboardImage } | Should -Throw '*Clipboard does not contain an image.*'
        Should -Invoke Invoke-ClipboardNoImageNotification -ModuleName ClipboardImage -Times 1 -Exactly
        Should -Invoke Set-Clipboard -ModuleName ClipboardImage -Times 0
    }

    It 'terminates both entry points after successful work' {
        foreach ($lScriptName in @('Save-ClipboardImage.ps1', 'Save-InvertedClipboardImage.ps1')) {
            $lScriptPath = Join-Path $PSScriptRoot "..\$lScriptName"
            $lScriptText = Get-Content -LiteralPath $lScriptPath -Raw

            $lScriptText | Should -Match '\[Environment\]::Exit\(0\)'
        }
    }

    It 'has the inverted entry point run the regular entry point first' {
        $lScriptPath = Join-Path $PSScriptRoot '..\Save-InvertedClipboardImage.ps1'
        $lScriptText = Get-Content -LiteralPath $lScriptPath -Raw

        $lScriptText | Should -Match 'Join-Path \$PSScriptRoot ''Save-ClipboardImage\.ps1'''
        $lScriptText | Should -Match '& \$lRegularScript -ReturnToCaller'
        $lScriptText | Should -Match 'GetText\(\)'
        $lScriptText | Should -Match 'ConvertTo-InvertedClipboardPng'
    }

}

Describe 'ConvertTo-InvertedClipboardPng' {
    It 'processes a 512 by 512 PNG without the per-pixel PowerShell delay' {
        $lPath = Join-Path ([IO.Path]::GetTempPath()) ("screenshot_test_{0}.png" -f [guid]::NewGuid().ToString('N'))
        $lBitmap = [System.Drawing.Bitmap]::new(512, 512)
        $lGraphics = [System.Drawing.Graphics]::FromImage($lBitmap)

        try {
            $lGraphics.Clear([System.Drawing.Color]::FromArgb(123, 10, 20, 30))
            $lBitmap.Save($lPath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $lGraphics.Dispose()
            $lBitmap.Dispose()
        }

        try {
            $lStopwatch = [Diagnostics.Stopwatch]::StartNew()
            ConvertTo-InvertedClipboardPng -Path $lPath
            $lStopwatch.Stop()

            $lStopwatch.ElapsedMilliseconds | Should -BeLessThan 2000
        }
        finally {
            if (Test-Path -LiteralPath $lPath) {
                Remove-Item -LiteralPath $lPath -Force
            }
        }
    }

    It 'rejects a path that is not a PNG in the temp directory' {
        $lPath = Join-Path ([IO.Path]::GetTempPath()) ("screenshot_test_{0}.txt" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $lPath -Value 'not an image'

        try {
            { ConvertTo-InvertedClipboardPng -Path $lPath } | Should -Throw '*valid PNG file in the temp directory*'
        }
        finally {
            Remove-Item -LiteralPath $lPath -Force
        }
    }
}

Describe 'Clipboard runtime compatibility' {
    It 'reads the image clipboard without relying on Windows PowerShell-only parameters' {
        InModuleScope ClipboardImage {
            {
                $lImage = Get-ClipboardImage
                if ($lImage -is [System.IDisposable]) {
                    $lImage.Dispose()
                }
            } | Should -Not -Throw
        }
    }
}

Describe 'Clipboard notification audio' {
    It 'ships a valid WAV asset for the hidden no-image path' {
        $lAudioPath = Join-Path $PSScriptRoot '..\clipboard-no-image.wav'

        Test-Path -LiteralPath $lAudioPath -PathType Leaf | Should -BeTrue
        if (Test-Path -LiteralPath $lAudioPath -PathType Leaf) {
            $lBytes = [IO.File]::ReadAllBytes($lAudioPath)
            $lBytes.Length | Should -BeGreaterThan 44
            [Text.Encoding]::ASCII.GetString($lBytes, 0, 4) | Should -Be 'RIFF'
            [Text.Encoding]::ASCII.GetString($lBytes, 8, 4) | Should -Be 'WAVE'
        }
    }
}
