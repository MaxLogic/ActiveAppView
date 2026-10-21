#Requires -Version 5.1

[CmdletBinding()]
param(
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

    $null = Copy-MarkdownAsRichText -Markdown $lContent.Markdown -Format Html

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
