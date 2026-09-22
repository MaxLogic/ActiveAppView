BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\SaveMarkdown.psm1'
    Import-Module -Name $modulePath -Force
}

Describe 'Save-ClipboardMarkdown' {
    BeforeEach {
        # The live clipboard is shared mutable state and cannot be isolated reliably in automated tests.
        Mock Get-Clipboard -ModuleName SaveMarkdown {
            "# Heading`r`n`r`nMarkdown body"
        }
        # The live clipboard is shared mutable state and cannot be isolated reliably in automated tests.
        Mock Set-Clipboard -ModuleName SaveMarkdown {
            param([object]$Value)

            $null = $Value
        }
    }

    It 'saves clipboard text as a UTF-8 Markdown file and copies its full path' {
        $lPath = Save-ClipboardMarkdown

        try {
            $lPath | Should -Match 'markdown_\d{8}_\d{6}_\d{3}(?:_\d+)?\.md$'
            [IO.Path]::IsPathFullyQualified($lPath) | Should -BeTrue
            [IO.Path]::GetDirectoryName($lPath) | Should -Be ([IO.Path]::GetTempPath().TrimEnd('\'))
            [IO.File]::ReadAllText($lPath, [Text.Encoding]::UTF8) |
                Should -Be "# Heading`r`n`r`nMarkdown body"
            Should -Invoke Set-Clipboard -ModuleName SaveMarkdown -Times 1 -Exactly -ParameterFilter {
                $Value -eq $lPath
            }
        }
        finally {
            if ($lPath -and (Test-Path -LiteralPath $lPath)) {
                Remove-Item -LiteralPath $lPath -Force
            }
        }
    }

    It 'rejects a clipboard without text and does not overwrite the clipboard' {
        # The live clipboard is shared mutable state and cannot be isolated reliably in automated tests.
        Mock Get-Clipboard -ModuleName SaveMarkdown { $null }

        { Save-ClipboardMarkdown } | Should -Throw '*Clipboard does not contain text.*'
        Should -Invoke Set-Clipboard -ModuleName SaveMarkdown -Times 0
    }

    It 'terminates the visible entry point after successful work' {
        $lScriptPath = Join-Path $PSScriptRoot '..\save-md.ps1'
        $lScriptText = Get-Content -LiteralPath $lScriptPath -Raw

        $lScriptText | Should -Match 'Save-ClipboardMarkdown'
        $lScriptText | Should -Match '\[Environment\]::Exit\(0\)'
    }
}
