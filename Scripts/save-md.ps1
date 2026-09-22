#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module -Name (Join-Path $PSScriptRoot 'SaveMarkdown.psm1') -Force
    Save-ClipboardMarkdown
    [Environment]::Exit(0)
}
catch {
    Write-Error -ErrorRecord $_
    [Environment]::Exit(1)
}
