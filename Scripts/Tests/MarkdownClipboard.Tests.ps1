BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\MarkdownClipboard.psm1'
    Import-Module -Name $modulePath -Force -ErrorAction Stop

    function New-TestMarkdownFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test fixture creates a single temporary file.')]
        param(
            [string]$Content,
            [string]$Extension = '.md'
        )

        $lPath = Join-Path ([IO.Path]::GetTempPath()) ("markdown_test_{0}{1}" -f [guid]::NewGuid().ToString('N'), $Extension)
        [IO.File]::WriteAllText($lPath, $Content, [Text.UTF8Encoding]::new($false))
        return $lPath
    }

    function Get-PolishSampleText {
        # Zazolc with diacritics, built from code points so the test source stays ASCII.
        return [string]::Concat([char]0x5A, [char]0x61, [char]0x17C, [char]0xF3, [char]0x142, [char]0x107)
    }
}

Describe 'Resolve-MarkdownClipboardContent' {
    It 'uses dropped markdown files in list order' {
        $lFirst = New-TestMarkdownFile -Content 'AAA'
        $lSecond = New-TestMarkdownFile -Content 'BBB'

        try {
            $lContent = Resolve-MarkdownClipboardContent -FileDropPaths @($lFirst, $lSecond) -Text $null

            $lContent.Markdown | Should -Be "AAA`r`nBBB"
            $lContent.SourceLabel | Should -Be '2 markdown files'
        }
        finally {
            [IO.File]::Delete($lFirst)
            [IO.File]::Delete($lSecond)
        }
    }

    It 'labels a single dropped markdown file with its name' {
        $lPath = New-TestMarkdownFile -Content '# One'

        try {
            $lContent = Resolve-MarkdownClipboardContent -FileDropPaths @($lPath) -Text $null

            $lContent.Markdown | Should -Be '# One'
            $lContent.SourceLabel | Should -Be ([IO.Path]::GetFileName($lPath))
        }
        finally {
            [IO.File]::Delete($lPath)
        }
    }

    It 'prefers dropped markdown files over pasted text' {
        $lPath = New-TestMarkdownFile -Content 'from file'

        try {
            $lContent = Resolve-MarkdownClipboardContent -FileDropPaths @($lPath) -Text 'from text'

            $lContent.Markdown | Should -Be 'from file'
        }
        finally {
            [IO.File]::Delete($lPath)
        }
    }

    It 'ignores dropped files that are not markdown' {
        $lPath = New-TestMarkdownFile -Content 'plain notes' -Extension '.txt'

        try {
            Resolve-MarkdownClipboardContent -FileDropPaths @($lPath) -Text '' | Should -BeNullOrEmpty
        }
        finally {
            [IO.File]::Delete($lPath)
        }
    }

    It 'treats pasted text that names an existing markdown file as that file' {
        $lPath = New-TestMarkdownFile -Content '# From disk'

        try {
            $lContent = Resolve-MarkdownClipboardContent -FileDropPaths @() -Text $lPath

            $lContent.Markdown | Should -Be '# From disk'
            $lContent.SourceLabel | Should -Be ([IO.Path]::GetFileName($lPath))
        }
        finally {
            [IO.File]::Delete($lPath)
        }
    }

    It 'accepts a quoted markdown file path' {
        $lPath = New-TestMarkdownFile -Content '# Quoted'

        try {
            $lContent = Resolve-MarkdownClipboardContent -FileDropPaths @() -Text ('"{0}"' -f $lPath)

            $lContent.Markdown | Should -Be '# Quoted'
        }
        finally {
            [IO.File]::Delete($lPath)
        }
    }

    It 'reads a markdown file with a markdown extension other than md' {
        $lPath = New-TestMarkdownFile -Content '# Long form' -Extension '.markdown'

        try {
            $lContent = Resolve-MarkdownClipboardContent -FileDropPaths @($lPath) -Text $null

            $lContent.Markdown | Should -Be '# Long form'
        }
        finally {
            [IO.File]::Delete($lPath)
        }
    }

    It 'uses pasted text as markdown when it is not a file path' {
        $lContent = Resolve-MarkdownClipboardContent -FileDropPaths @() -Text '# Pasted heading'

        $lContent.Markdown | Should -Be '# Pasted heading'
        $lContent.SourceLabel | Should -Be 'clipboard text'
    }

    It 'keeps single line text containing path-illegal characters as markdown' {
        $lContent = Resolve-MarkdownClipboardContent -FileDropPaths @() -Text 'TODO: fix a|b'

        $lContent.Markdown | Should -Be 'TODO: fix a|b'
        $lContent.SourceLabel | Should -Be 'clipboard text'
    }

    It 'returns nothing for blank clipboard input' {
        Resolve-MarkdownClipboardContent -FileDropPaths @() -Text '   ' | Should -BeNullOrEmpty
        Resolve-MarkdownClipboardContent -FileDropPaths @() -Text $null | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-MarkdownRawContent' {
    It 'strips a UTF-8 byte order mark' {
        $lExpected = Get-PolishSampleText
        $lBytes = [byte[]]@(0xEF, 0xBB, 0xBF, 0x5A, 0x61, 0xC5, 0xBC, 0xC3, 0xB3, 0xC5, 0x82, 0xC4, 0x87)

        $lText = ConvertFrom-MarkdownRawContent -Bytes $lBytes

        $lText | Should -Be $lExpected
        $lText[0] | Should -Be ([char]0x5A)
    }

    It 'decodes strict UTF-8 text without a mark' {
        $lBytes = [byte[]]@(0x5A, 0x61, 0xC5, 0xBC, 0xC3, 0xB3, 0xC5, 0x82, 0xC4, 0x87)

        ConvertFrom-MarkdownRawContent -Bytes $lBytes | Should -Be (Get-PolishSampleText)
    }

    It 'falls back to Windows-1250 when UTF-8 decoding fails' {
        $lBytes = [byte[]]@(0x5A, 0x61, 0xBF, 0xF3, 0xB3, 0xE6)

        ConvertFrom-MarkdownRawContent -Bytes $lBytes | Should -Be (Get-PolishSampleText)
    }

    It 'decodes UTF-16 little-endian text with a byte order mark' {
        $lExpected = Get-PolishSampleText
        $lBytes = @([byte]0xFF, [byte]0xFE) + [Text.Encoding]::Unicode.GetBytes($lExpected)

        ConvertFrom-MarkdownRawContent -Bytes ([byte[]]$lBytes) | Should -Be $lExpected
    }

    It 'returns empty text for empty input' {
        ConvertFrom-MarkdownRawContent -Bytes ([byte[]]@()) | Should -Be ''
    }
}

Describe 'ConvertTo-HtmlClipboardEnvelope' {
    It 'writes byte offsets that match multibyte fragment content' {
        $lFragment = '<p>' + (Get-PolishSampleText) + ' - euro sign: ' + [char]0x20AC + '</p>'

        [byte[]]$lEnvelope = ConvertTo-HtmlClipboardEnvelope -HtmlFragment $lFragment
        $lDocument = [Text.Encoding]::UTF8.GetString($lEnvelope)
        $lStartHtml = [int]([regex]::Match($lDocument, 'StartHTML:(\d+)').Groups[1].Value)
        $lEndHtml = [int]([regex]::Match($lDocument, 'EndHTML:(\d+)').Groups[1].Value)
        $lStartFragment = [int]([regex]::Match($lDocument, 'StartFragment:(\d+)').Groups[1].Value)
        $lEndFragment = [int]([regex]::Match($lDocument, 'EndFragment:(\d+)').Groups[1].Value)
        $lStartSelection = [int]([regex]::Match($lDocument, 'StartSelection:(\d+)').Groups[1].Value)
        $lEndSelection = [int]([regex]::Match($lDocument, 'EndSelection:(\d+)').Groups[1].Value)

        $lFragmentBytes = [byte[]]::new($lEndFragment - $lStartFragment)
        [Array]::Copy($lEnvelope, $lStartFragment, $lFragmentBytes, 0, $lFragmentBytes.Length)
        [Text.Encoding]::UTF8.GetString($lFragmentBytes) | Should -Be $lFragment
        ($lEndFragment - $lStartFragment) | Should -Be ([Text.Encoding]::UTF8.GetByteCount($lFragment))
        $lEndHtml | Should -Be $lEnvelope.Length
        $lStartSelection | Should -Be $lStartFragment
        $lEndSelection | Should -Be $lEndFragment
        $lStartHtml | Should -BeLessThan $lStartFragment
        $lDocument.Substring(0, $lStartHtml) | Should -Match '^Version:0\.9'
    }

    It 'places the fragment markers inside the declared fragment range' {
        [byte[]]$lEnvelope = ConvertTo-HtmlClipboardEnvelope -HtmlFragment '<p>x</p>'
        $lDocument = [Text.Encoding]::UTF8.GetString($lEnvelope)
        $lStartFragment = [int]([regex]::Match($lDocument, 'StartFragment:(\d+)').Groups[1].Value)
        $lEndFragment = [int]([regex]::Match($lDocument, 'EndFragment:(\d+)').Groups[1].Value)

        $lDocument.Substring($lStartFragment - 20, 20) | Should -Match '<!--StartFragment-->$'
        $lDocument.Substring($lEndFragment, 18) | Should -Be '<!--EndFragment-->'
    }
}

Describe 'Copy-MarkdownAsRichText' {
    BeforeEach {
        # The live clipboard is shared mutable state and cannot be isolated reliably in automated tests.
        Mock Write-RichClipboardContent -ModuleName MarkdownClipboard {}
    }

    It 'sends HTML with the lossless markdown companion' {
        $null = Copy-MarkdownAsRichText -Markdown '# Heading' -Format Html

        Should -Invoke Write-RichClipboardContent -ModuleName MarkdownClipboard -Times 1 -Exactly -ParameterFilter {
            ($HtmlFragment -match '<h1') -and ($Text -eq '# Heading') -and ($null -eq $Rtf)
        }
    }

    It 'sends RTF with the lossless markdown companion' {
        $null = Copy-MarkdownAsRichText -Markdown '# Heading' -Format Rtf

        Should -Invoke Write-RichClipboardContent -ModuleName MarkdownClipboard -Times 1 -Exactly -ParameterFilter {
            ($Rtf -match '^\{\\rtf1') -and ($Text -eq '# Heading') -and ($null -eq $HtmlFragment)
        }
    }

    It 'sends de-formatted plain text without rich formats' {
        $null = Copy-MarkdownAsRichText -Markdown '# Heading' -Format Plain

        Should -Invoke Write-RichClipboardContent -ModuleName MarkdownClipboard -Times 1 -Exactly -ParameterFilter {
            ($Text -match 'Heading') -and ($Text -notmatch '#') -and ($null -eq $HtmlFragment) -and ($null -eq $Rtf)
        }
    }

    It 'rejects an unknown format name' {
        { Copy-MarkdownAsRichText -Markdown 'x' -Format 'Docx' } | Should -Throw
    }
}

Describe 'Write-RichClipboardContent' {
    It 'rejects an empty payload before touching the clipboard' {
        { Write-RichClipboardContent -Text '' } | Should -Throw -ExpectedMessage 'No clipboard content*'
    }
}

Describe 'Invoke-Pandoc' {
    It 'fails with a clear error when the executable is missing' {
        $lMissing = Join-Path ([IO.Path]::GetTempPath()) 'markdown-test-missing-pandoc.exe'

        { Invoke-Pandoc -ExecutablePath $lMissing -Arguments @('-t', 'plain') -InputText 'x' } | Should -Throw
    }

    It 'reports a nonzero exit code instead of returning partial output' {
        { Invoke-Pandoc -ExecutablePath (Resolve-PandocPath) -Arguments @('--definitely-not-an-option') -InputText 'x' } |
            Should -Throw -ExpectedMessage '*exit code*'
    }
}

Describe 'Pandoc conversions' {
    It 'resolves the pandoc executable from PATH' {
        $lPath = Resolve-PandocPath

        [IO.File]::Exists($lPath) | Should -BeTrue
        [IO.Path]::GetFileNameWithoutExtension($lPath) | Should -Be 'pandoc'
    }

    It 'produces a standalone RTF document from markdown' {
        $lRtf = Convert-MarkdownToRtf -Markdown "# Title`n`nSome **bold** text."

        $lRtf | Should -Match '^\{\\rtf1'
        $lRtf | Should -Match '\\b '
        $lRtf.Length | Should -BeGreaterThan 200
    }

    It 'produces de-formatted plain text without markdown syntax' {
        $lPlain = Convert-MarkdownToPlainText -Markdown "# Title`n`nSome **bold** text."

        $lPlain | Should -Match 'Title'
        $lPlain | Should -Match 'bold'
        $lPlain | Should -Not -Match '\*\*'
        $lPlain | Should -Not -Match '(?m)^#'
    }

    It 'keeps long paragraphs on a single line' {
        $lParagraph = (@('word') * 40) -join ' '

        $lPlain = Convert-MarkdownToPlainText -Markdown $lParagraph

        $lPlain | Should -Match ([regex]::Escape($lParagraph))
    }

    It 'produces an HTML fragment from markdown' {
        $lHtml = Convert-MarkdownToHtmlFragment -Markdown '# Title'

        $lHtml | Should -Match '<h1'
        $lHtml | Should -Match 'Title'
        $lHtml | Should -Not -Match '<html'
    }
}

Describe 'ConvertFrom-MarkdownClipboardMenuKey' {
    It 'maps enter and the number keys to formats' {
        ConvertFrom-MarkdownClipboardMenuKey -Key 'Enter' | Should -Be 'Html'
        ConvertFrom-MarkdownClipboardMenuKey -Key 'D1' | Should -Be 'Html'
        ConvertFrom-MarkdownClipboardMenuKey -Key 'NumPad1' | Should -Be 'Html'
        ConvertFrom-MarkdownClipboardMenuKey -Key 'D2' | Should -Be 'Rtf'
        ConvertFrom-MarkdownClipboardMenuKey -Key 'NumPad2' | Should -Be 'Rtf'
        ConvertFrom-MarkdownClipboardMenuKey -Key 'D3' | Should -Be 'Plain'
        ConvertFrom-MarkdownClipboardMenuKey -Key 'NumPad3' | Should -Be 'Plain'
    }

    It 'maps escape to cancel and ignores other keys' {
        ConvertFrom-MarkdownClipboardMenuKey -Key 'Escape' | Should -Be 'Cancel'
        ConvertFrom-MarkdownClipboardMenuKey -Key 'D9' | Should -BeNullOrEmpty
        ConvertFrom-MarkdownClipboardMenuKey -Key 'A' | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-MarkdownClipboardFormatChoice' {
    It 'keeps an explicit format without asking the menu' {
        Resolve-MarkdownClipboardFormatChoice -Format 'Rtf' -SourceLabel 'clipboard text' -CharacterCount 10 | Should -Be 'Rtf'
    }

    It 'defaults to HTML for caller returns' {
        Resolve-MarkdownClipboardFormatChoice -Format '' -ReturnToCaller -SourceLabel 'clipboard text' -CharacterCount 10 | Should -Be 'Html'
    }

    It 'returns the menu choice' {
        Mock -ModuleName MarkdownClipboard Read-MarkdownClipboardFormatChoice { 'Plain' }

        Resolve-MarkdownClipboardFormatChoice -Format '' -SourceLabel 'clipboard text' -CharacterCount 10 | Should -Be 'Plain'
    }

    It 'reports a cancelled menu instead of failing format validation' {
        Mock -ModuleName MarkdownClipboard Read-MarkdownClipboardFormatChoice { $null }

        { Resolve-MarkdownClipboardFormatChoice -Format '' -SourceLabel 'clipboard text' -CharacterCount 10 } | Should -Not -Throw
        Resolve-MarkdownClipboardFormatChoice -Format '' -SourceLabel 'clipboard text' -CharacterCount 10 | Should -BeNullOrEmpty
    }
}

Describe 'Markdown clipboard entry point' {
    BeforeAll {
        $script:entryScriptPath = Join-Path $PSScriptRoot '..\Copy-MarkdownAsRichText.ps1'
        $script:entryScriptText = Get-Content -LiteralPath $script:entryScriptPath -Raw
    }

    It 'terminates the -NoExit host after success and failure' {
        $script:entryScriptText | Should -Match '\[Environment\]::Exit\(0\)'
        $script:entryScriptText | Should -Match '\[Environment\]::Exit\(1\)'
    }

    It 'imports the markdown clipboard module from the script root' {
        $script:entryScriptText | Should -Match 'Join-Path \$PSScriptRoot ''MarkdownClipboard\.psm1'''
        $script:entryScriptText | Should -Match 'Import-Module'
    }

    It 'offers HTML, RTF, and plain text formats' {
        $script:entryScriptText | Should -Match "ValidateSet\('Html', 'Rtf', 'Plain'\)"
        $script:entryScriptText | Should -Match 'Resolve-MarkdownClipboardFormatChoice'
    }

    It 'plays the no content notification and supports caller returns' {
        $script:entryScriptText | Should -Match 'Invoke-MarkdownClipboardNoContentNotification'
        $script:entryScriptText | Should -Match 'ReturnToCaller'
        $script:entryScriptText | Should -Match 'Copy-MarkdownAsRichText'
    }

    It 'cancels cleanly when the menu is cancelled' {
        $script:entryScriptText | Should -Match 'Resolve-MarkdownClipboardFormatChoice'
        $script:entryScriptText | Should -Match 'if \(\$null -eq \$lFormat\)\s*\{\s*\[Environment\]::Exit\(0\)'
    }
}

Describe 'Clipboard notification audio' {
    It 'ships a valid WAV asset for the hidden no markdown path' {
        $lAudioPath = Join-Path $PSScriptRoot '..\clipboard-no-markdown.wav'

        Test-Path -LiteralPath $lAudioPath -PathType Leaf | Should -BeTrue
        if (Test-Path -LiteralPath $lAudioPath -PathType Leaf) {
            $lBytes = [IO.File]::ReadAllBytes($lAudioPath)
            $lBytes.Length | Should -BeGreaterThan 44
            [Text.Encoding]::ASCII.GetString($lBytes, 0, 4) | Should -Be 'RIFF'
            [Text.Encoding]::ASCII.GetString($lBytes, 8, 4) | Should -Be 'WAVE'
        }
    }
}