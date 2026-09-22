Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MarkdownTempPath {
    [CmdletBinding()]
    param()

    $lTimestamp = [DateTime]::Now.ToString(
        'yyyyMMdd_HHmmss_fff',
        [Globalization.CultureInfo]::InvariantCulture)
    $lPath = Join-Path ([IO.Path]::GetTempPath()) ("markdown_{0}.md" -f $lTimestamp)
    $lSuffix = 1

    while (Test-Path -LiteralPath $lPath) {
        $lPath = Join-Path ([IO.Path]::GetTempPath()) ("markdown_{0}_{1}.md" -f $lTimestamp, $lSuffix)
        $lSuffix++
    }

    return [IO.Path]::GetFullPath($lPath)
}

function Save-ClipboardMarkdown {
    [CmdletBinding()]
    param()

    [string]$lText = Get-Clipboard -Raw
    if ([string]::IsNullOrEmpty($lText)) {
        throw 'Clipboard does not contain text.'
    }

    $lPath = Get-MarkdownTempPath

    try {
        [IO.File]::WriteAllText($lPath, $lText, [Text.UTF8Encoding]::new($false))
        Set-Clipboard -Value $lPath -ErrorAction Stop
    }
    catch {
        if (Test-Path -LiteralPath $lPath) {
            Remove-Item -LiteralPath $lPath -Force
        }

        throw
    }

    return $lPath
}

Export-ModuleMember -Function Save-ClipboardMarkdown
