#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq ('MarkdownClipboardNative' -as [type])) {
    # The C# source is a single-quoted block so PowerShell performs no interpolation.
    $lNativeSource = 'using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MarkdownClipboardNative
{
    public const uint CF_UNICODETEXT = 13;
    public const uint CF_HDROP = 15;
    public const uint GMEM_MOVEABLE = 0x0002;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetClipboardData(uint uFormat);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint RegisterClipboardFormat(string lpszFormat);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalFree(IntPtr hMem);

    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint DragQueryFile(IntPtr hDrop, uint iFile, StringBuilder lpszFile, uint cch);
}'

    Add-Type -TypeDefinition $lNativeSource
}

$script:MarkdownFileExtensions = @('.md', '.markdown')

function Open-ClipboardSession {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [int]$Attempts = 20,
        [int]$DelayMilliseconds = 50
    )

    for ($lAttempt = 0; $lAttempt -lt $Attempts; $lAttempt++) {
        if ([MarkdownClipboardNative]::OpenClipboard([IntPtr]::Zero)) {
            return $true
        }

        Start-Sleep -Milliseconds $DelayMilliseconds
    }

    return $false
}

function Get-MarkdownClipboardRawContent {
    [CmdletBinding()]
    param()

    if (-not (Open-ClipboardSession)) {
        throw 'Could not open the clipboard. Another application may be holding it.'
    }

    $lFileDropPaths = @()
    $lText = $null

    try {
        $lDropHandle = [MarkdownClipboardNative]::GetClipboardData([MarkdownClipboardNative]::CF_HDROP)
        if ($lDropHandle -ne [IntPtr]::Zero) {
            $lDropPointer = [MarkdownClipboardNative]::GlobalLock($lDropHandle)
            if ($lDropPointer -ne [IntPtr]::Zero) {
                try {
                    $lDropCount = [MarkdownClipboardNative]::DragQueryFile($lDropPointer, [uint32]::MaxValue, $null, 0)
                    $lPaths = [System.Collections.Generic.List[string]]::new()

                    for ($lIndex = 0; $lIndex -lt $lDropCount; $lIndex++) {
                        $lLength = [MarkdownClipboardNative]::DragQueryFile($lDropPointer, [uint32]$lIndex, $null, 0)
                        $lBuffer = [Text.StringBuilder]::new([int]$lLength + 1)
                        $null = [MarkdownClipboardNative]::DragQueryFile($lDropPointer, [uint32]$lIndex, $lBuffer, $lLength + 1)
                        $lPaths.Add($lBuffer.ToString())
                    }

                    $lFileDropPaths = $lPaths.ToArray()
                }
                finally {
                    $null = [MarkdownClipboardNative]::GlobalUnlock($lDropHandle)
                }
            }
        }

        $lTextHandle = [MarkdownClipboardNative]::GetClipboardData([MarkdownClipboardNative]::CF_UNICODETEXT)
        if ($lTextHandle -ne [IntPtr]::Zero) {
            $lTextPointer = [MarkdownClipboardNative]::GlobalLock($lTextHandle)
            if ($lTextPointer -ne [IntPtr]::Zero) {
                try {
                    $lText = [Runtime.InteropServices.Marshal]::PtrToStringUni($lTextPointer)
                }
                finally {
                    $null = [MarkdownClipboardNative]::GlobalUnlock($lTextHandle)
                }
            }
        }
    }
    finally {
        $null = [MarkdownClipboardNative]::CloseClipboard()
    }

    return [pscustomobject]@{
        FileDropPaths = $lFileDropPaths
        Text          = $lText
    }
}

function Test-MarkdownFilePath {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $lExtension = [IO.Path]::GetExtension($Path.Trim().Trim('"'))
    return ($script:MarkdownFileExtensions -contains $lExtension.ToLowerInvariant())
}

function ConvertFrom-MarkdownRawContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }

    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }

    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }

    $lStrictUtf8 = [Text.UTF8Encoding]::new($false, $true)

    try {
        return $lStrictUtf8.GetString($Bytes)
    }
    catch [Text.DecoderFallbackException] {
        return [Text.Encoding]::GetEncoding(1250).GetString($Bytes)
    }
}

function Read-MarkdownFileContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $lFullPath = [IO.Path]::GetFullPath($Path)

    try {
        $lBytes = [IO.File]::ReadAllBytes($lFullPath)
    }
    catch {
        throw ("Could not read markdown file '{0}': {1}" -f $lFullPath, $_.Exception.Message)
    }

    return ConvertFrom-MarkdownRawContent -Bytes $lBytes
}

function Resolve-MarkdownClipboardContent {
    [CmdletBinding()]
    param(
        [string[]]$FileDropPaths = @(),
        [string]$Text
    )

    $lMarkdownFiles = [System.Collections.Generic.List[string]]::new()

    foreach ($lDropPath in $FileDropPaths) {
        if (-not (Test-MarkdownFilePath -Path $lDropPath)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $lDropPath -PathType Leaf)) {
            continue
        }

        $lMarkdownFiles.Add([IO.Path]::GetFullPath($lDropPath))
    }

    if ($lMarkdownFiles.Count -gt 0) {
        $lParts = foreach ($lFile in $lMarkdownFiles) {
            Read-MarkdownFileContent -Path $lFile
        }

        if ($lMarkdownFiles.Count -eq 1) {
            $lLabel = [IO.Path]::GetFileName($lMarkdownFiles[0])
        }
        else {
            $lLabel = '{0} markdown files' -f $lMarkdownFiles.Count
        }

        return [pscustomobject]@{
            Markdown    = ($lParts -join "`r`n")
            SourceLabel = $lLabel
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        $lCandidate = $Text.Trim().Trim('"')
        $lIsFileCandidate = $false

        if ($lCandidate -notmatch '[\r\n]') {
            try {
                $lIsFileCandidate = (Test-MarkdownFilePath -Path $lCandidate) -and
                    (Test-Path -LiteralPath $lCandidate -PathType Leaf)
            }
            catch {
                $lIsFileCandidate = $false
            }
        }

        if ($lIsFileCandidate) {
            $lFullPath = [IO.Path]::GetFullPath($lCandidate)

            return [pscustomobject]@{
                Markdown    = Read-MarkdownFileContent -Path $lFullPath
                SourceLabel = [IO.Path]::GetFileName($lFullPath)
            }
        }

        return [pscustomobject]@{
            Markdown    = $Text
            SourceLabel = 'clipboard text'
        }
    }

    return $null
}

function Get-MarkdownClipboardContent {
    [CmdletBinding()]
    param()

    $lRaw = Get-MarkdownClipboardRawContent

    return Resolve-MarkdownClipboardContent -FileDropPaths $lRaw.FileDropPaths -Text $lRaw.Text
}

function Convert-MarkdownToHtmlFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Markdown
    )

    if ($null -ne (Get-Command -Name 'ConvertFrom-Markdown' -ErrorAction SilentlyContinue)) {
        return (ConvertFrom-Markdown -InputObject $Markdown).Html
    }

    return Invoke-Pandoc -ExecutablePath (Resolve-PandocPath) -Arguments @('-f', 'gfm', '-t', 'html') -InputText $Markdown
}

function ConvertTo-HtmlClipboardEnvelope {
    [OutputType([byte[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'The unary comma keeps PowerShell from unrolling the returned byte array.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$HtmlFragment
    )

    $lPrefix = '<html><head><meta charset="utf-8"></head><body><!--StartFragment-->'
    $lSuffix = '<!--EndFragment--></body></html>'
    $lEmptyHeader = "Version:0.9`r`nStartHTML:0000000000`r`nEndHTML:0000000000`r`nStartFragment:0000000000`r`nEndFragment:0000000000`r`nStartSelection:0000000000`r`nEndSelection:0000000000`r`n"
    $lEncoding = [Text.UTF8Encoding]::new($false)

    # CF_HTML offsets are byte offsets, so measure every part after UTF-8 encoding.
    $lStartHtml = $lEncoding.GetByteCount($lEmptyHeader)
    $lStartFragment = $lStartHtml + $lEncoding.GetByteCount($lPrefix)
    $lEndFragment = $lStartFragment + $lEncoding.GetByteCount($HtmlFragment)
    $lEndHtml = $lEndFragment + $lEncoding.GetByteCount($lSuffix)

    $lHeader = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`nStartSelection:{2:D10}`r`nEndSelection:{3:D10}`r`n" -f $lStartHtml, $lEndHtml, $lStartFragment, $lEndFragment

    return , $lEncoding.GetBytes($lHeader + $lPrefix + $HtmlFragment + $lSuffix)
}

function Resolve-PandocPath {
    [CmdletBinding()]
    param()

    $lCommand = Get-Command -Name 'pandoc' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -eq $lCommand) {
        throw 'pandoc was not found on PATH. Install pandoc to use the RTF and plain text conversions.'
    }

    return $lCommand.Source
}

function Invoke-Pandoc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputText
    )

    $lQuotedArguments = foreach ($lArgument in $Arguments) {
        if ($lArgument -match '[\s"]') {
            '"' + ($lArgument -replace '"', '\"') + '"'
        }
        else {
            $lArgument
        }
    }

    $lStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $lStartInfo.FileName = $ExecutablePath
    $lStartInfo.Arguments = $lQuotedArguments -join ' '
    $lStartInfo.UseShellExecute = $false
    $lStartInfo.CreateNoWindow = $true
    $lStartInfo.RedirectStandardInput = $true
    $lStartInfo.RedirectStandardOutput = $true
    $lStartInfo.RedirectStandardError = $true

    $lProcess = [Diagnostics.Process]::new()
    $lProcess.StartInfo = $lStartInfo

    try {
        if (-not $lProcess.Start()) {
            throw ("Could not start '{0}'." -f $ExecutablePath)
        }

        # Feed and read raw UTF-8 bytes so the conversion never depends on console encodings.
        $lInputBytes = [Text.UTF8Encoding]::new($false).GetBytes($InputText)
        $lStandardInput = $lProcess.StandardInput.BaseStream
        $lStandardInput.Write($lInputBytes, 0, $lInputBytes.Length)
        $lStandardInput.Flush()
        $lStandardInput.Close()

        $lErrorTask = $lProcess.StandardError.ReadToEndAsync()
        $lOutputBuffer = [IO.MemoryStream]::new()
        $lOutputBytes = $null

        try {
            $lProcess.StandardOutput.BaseStream.CopyTo($lOutputBuffer)
            $lOutputBytes = $lOutputBuffer.ToArray()
        }
        finally {
            $lOutputBuffer.Dispose()
        }

        $lProcess.WaitForExit()
        $lErrorText = $lErrorTask.GetAwaiter().GetResult()

        if ($lProcess.ExitCode -ne 0) {
            throw ('pandoc failed with exit code {0}: {1}' -f $lProcess.ExitCode, $lErrorText.Trim())
        }

        return [Text.UTF8Encoding]::new($false).GetString($lOutputBytes)
    }
    finally {
        $lProcess.Dispose()
    }
}

function Convert-MarkdownToRtf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Markdown,

        [string]$PandocPath
    )

    if ([string]::IsNullOrWhiteSpace($PandocPath)) {
        $PandocPath = Resolve-PandocPath
    }

    # A standalone document is required; a bare pandoc RTF fragment pastes as literal source.
    return Invoke-Pandoc -ExecutablePath $PandocPath -Arguments @('-s', '-t', 'rtf', '--wrap=none') -InputText $Markdown
}

function Convert-MarkdownToPlainText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Markdown,

        [string]$PandocPath
    )

    if ([string]::IsNullOrWhiteSpace($PandocPath)) {
        $PandocPath = Resolve-PandocPath
    }

    $lText = Invoke-Pandoc -ExecutablePath $PandocPath -Arguments @('-t', 'plain', '--wrap=none') -InputText $Markdown

    return $lText.TrimEnd("`r`n")
}

function ConvertTo-GlobalMemoryHandle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $lHandle = [MarkdownClipboardNative]::GlobalAlloc(
        [MarkdownClipboardNative]::GMEM_MOVEABLE,
        [UIntPtr]::new([uint64]$Bytes.Length))

    if ($lHandle -eq [IntPtr]::Zero) {
        throw 'Could not allocate clipboard memory.'
    }

    $lPointer = [MarkdownClipboardNative]::GlobalLock($lHandle)
    if ($lPointer -eq [IntPtr]::Zero) {
        $null = [MarkdownClipboardNative]::GlobalFree($lHandle)
        throw 'Could not lock clipboard memory.'
    }

    try {
        [Runtime.InteropServices.Marshal]::Copy($Bytes, 0, $lPointer, $Bytes.Length)
    }
    finally {
        $null = [MarkdownClipboardNative]::GlobalUnlock($lHandle)
    }

    return $lHandle
}

function Write-RichClipboardContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [string]$HtmlFragment,

        [string]$Rtf
    )

    $lFormats = [System.Collections.Generic.List[object]]::new()

    if (-not [string]::IsNullOrWhiteSpace($HtmlFragment)) {
        $lHtmlFormatId = [MarkdownClipboardNative]::RegisterClipboardFormat('HTML Format')
        if ($lHtmlFormatId -eq 0) {
            throw 'Could not register the HTML Format clipboard format.'
        }

        [byte[]]$lHtmlBytes = ConvertTo-HtmlClipboardEnvelope -HtmlFragment $HtmlFragment
        $lFormats.Add([pscustomobject]@{ FormatId = $lHtmlFormatId; Bytes = $lHtmlBytes })
    }

    if (-not [string]::IsNullOrWhiteSpace($Rtf)) {
        $lRtfFormatId = [MarkdownClipboardNative]::RegisterClipboardFormat('Rich Text Format')
        if ($lRtfFormatId -eq 0) {
            throw 'Could not register the Rich Text Format clipboard format.'
        }

        [byte[]]$lRtfBytes = [Text.UTF8Encoding]::new($false).GetBytes($Rtf)
        $lFormats.Add([pscustomobject]@{ FormatId = $lRtfFormatId; Bytes = $lRtfBytes })
    }

    if (-not [string]::IsNullOrEmpty($Text)) {
        [byte[]]$lTextBytes = [Text.Encoding]::Unicode.GetBytes($Text)
        $lFormats.Add([pscustomobject]@{ FormatId = [MarkdownClipboardNative]::CF_UNICODETEXT; Bytes = $lTextBytes })
    }

    if ($lFormats.Count -eq 0) {
        throw 'No clipboard content was provided.'
    }

    if (-not (Open-ClipboardSession)) {
        throw 'Could not open the clipboard. Another application may be holding it.'
    }

    try {
        if (-not [MarkdownClipboardNative]::EmptyClipboard()) {
            throw 'Could not empty the clipboard.'
        }

        foreach ($lFormat in $lFormats) {
            # Every format we publish is NUL-terminated; UTF-16 text needs a 16-bit NUL.
            $lPayload = [byte[]]::new($lFormat.Bytes.Length + 2)
            [Array]::Copy($lFormat.Bytes, $lPayload, $lFormat.Bytes.Length)

            $lHandle = ConvertTo-GlobalMemoryHandle -Bytes $lPayload
            $lResult = [MarkdownClipboardNative]::SetClipboardData($lFormat.FormatId, $lHandle)
            if ($lResult -eq [IntPtr]::Zero) {
                $null = [MarkdownClipboardNative]::GlobalFree($lHandle)
                throw ('Could not set clipboard data for format {0}.' -f $lFormat.FormatId)
            }
        }
    }
    finally {
        $null = [MarkdownClipboardNative]::CloseClipboard()
    }
}

function Copy-MarkdownAsRichText {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Markdown,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Html', 'Rtf', 'Plain')]
        [string]$Format
    )

    switch ($Format) {
        'Html' {
            $lHtmlFragment = Convert-MarkdownToHtmlFragment -Markdown $Markdown
            Write-RichClipboardContent -Text $Markdown -HtmlFragment $lHtmlFragment
        }
        'Rtf' {
            $lRtf = Convert-MarkdownToRtf -Markdown $Markdown
            Write-RichClipboardContent -Text $Markdown -Rtf $lRtf
        }
        'Plain' {
            $lPlainText = Convert-MarkdownToPlainText -Markdown $Markdown
            Write-RichClipboardContent -Text $lPlainText
        }
    }

    return $Format
}

function ConvertFrom-MarkdownClipboardMenuKey {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    switch ($Key) {
        'Enter' { return 'Html' }
        'D1' { return 'Html' }
        'NumPad1' { return 'Html' }
        'D2' { return 'Rtf' }
        'NumPad2' { return 'Rtf' }
        'D3' { return 'Plain' }
        'NumPad3' { return 'Plain' }
        'Escape' { return 'Cancel' }
        default { return $null }
    }
}

function Read-MarkdownClipboardFormatChoice {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The console menu is the intended user interface.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceLabel,

        [Parameter(Mandatory = $true)]
        [int]$CharacterCount
    )

    $lCountText = $CharacterCount.ToString('N0', [Globalization.CultureInfo]::InvariantCulture)

    Write-Host ''
    Write-Host ("Clipboard: {0} ({1} characters)" -f $SourceLabel, $lCountText)
    Write-Host '  1  HTML    paste into Jira, OWA, Thunderbird compose, rich editors'
    Write-Host '  2  RTF     paste into Delphi RichEdit fields and WordPad-class apps'
    Write-Host '  3  Plain   readable text without formatting (pandoc -t plain)'
    Write-Host '  Esc        cancel without changing the clipboard'
    Write-Host ''

    while ($true) {
        Write-Host 'Choice [1]: ' -NoNewline
        $lKey = [Console]::ReadKey($true)
        Write-Host ''

        $lChoice = ConvertFrom-MarkdownClipboardMenuKey -Key $lKey.Key.ToString()
        if ($null -eq $lChoice) {
            Write-Host 'Press 1, 2, 3, or Esc.'
            continue
        }

        if ($lChoice -eq 'Cancel') {
            return $null
        }

        return $lChoice
    }
}

function Resolve-MarkdownClipboardFormatChoice {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Format,

        [switch]$ReturnToCaller,

        [Parameter(Mandatory = $true)]
        [string]$SourceLabel,

        [Parameter(Mandatory = $true)]
        [int]$CharacterCount
    )

    if (-not [string]::IsNullOrWhiteSpace($Format)) {
        return $Format
    }

    if ($ReturnToCaller) {
        return 'Html'
    }

    # A cancelled menu returns nothing; the caller decides how to exit.
    return Read-MarkdownClipboardFormatChoice -SourceLabel $SourceLabel -CharacterCount $CharacterCount
}
function Invoke-MarkdownClipboardNoContentNotification {
    [CmdletBinding()]
    param()

    $lAudioPath = Join-Path $PSScriptRoot 'clipboard-no-markdown.wav'
    $lPlayer = $null

    try {
        $lPlayer = [System.Media.SoundPlayer]::new($lAudioPath)
        $lPlayer.PlaySync()
    }
    catch {
        [System.Media.SystemSounds]::Exclamation.Play()
        Write-Warning "Could not play clipboard notification audio: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $lPlayer) {
            $lPlayer.Dispose()
        }
    }
}

Export-ModuleMember -Function @(
    'ConvertFrom-MarkdownClipboardMenuKey'
    'ConvertFrom-MarkdownRawContent'
    'Convert-MarkdownToHtmlFragment'
    'Convert-MarkdownToPlainText'
    'Convert-MarkdownToRtf'
    'ConvertTo-HtmlClipboardEnvelope'
    'Copy-MarkdownAsRichText'
    'Get-MarkdownClipboardContent'
    'Invoke-MarkdownClipboardNoContentNotification'
    'Invoke-Pandoc'
    'Read-MarkdownClipboardFormatChoice'
    'Resolve-MarkdownClipboardFormatChoice'
    'Resolve-MarkdownClipboardContent'
    'Resolve-PandocPath'
    'Test-MarkdownFilePath'
    'Write-RichClipboardContent'
)