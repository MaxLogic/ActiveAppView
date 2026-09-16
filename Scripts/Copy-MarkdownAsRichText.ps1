#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Html', 'Rtf', 'Plain')]
    [string]$Format,

    [switch]$ReturnToCaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module -Name (Join-Path $PSScriptRoot 'MarkdownClipboard.psm1') -Force

    $lContent = Get-MarkdownClipboardContent
    if ($null -eq $lContent) {
        Invoke-MarkdownClipboardNoContentNotification
        throw 'Clipboard does not contain markdown.'
    }

    $lFormat = Resolve-MarkdownClipboardFormatChoice -Format $Format -ReturnToCaller:$ReturnToCaller -SourceLabel $lContent.SourceLabel -CharacterCount $lContent.Markdown.Length
    if ($null -eq $lFormat) {
        [Environment]::Exit(0)
    }

    $null = Copy-MarkdownAsRichText -Markdown $lContent.Markdown -Format $lFormat

    if ($ReturnToCaller) {
        return
    }

    [Environment]::Exit(0)
}
catch {
    if ($ReturnToCaller) {
        throw
    }

    Write-Error -ErrorRecord $_
    [Environment]::Exit(1)
}