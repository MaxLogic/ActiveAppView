#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$ReturnToCaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module -Name (Join-Path $PSScriptRoot 'ClipboardImage.psm1') -Force
    Save-ClipboardImage

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
