#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $lRegularScript = Join-Path $PSScriptRoot 'Save-ClipboardImage.ps1'
    $null = & $lRegularScript -ReturnToCaller

    Import-Module -Name (Join-Path $PSScriptRoot 'ClipboardImage.psm1') -Force
    $lPath = [System.Windows.Forms.Clipboard]::GetText()
    $null = ConvertTo-InvertedClipboardPng -Path $lPath
    Set-Clipboard -Value $lPath -ErrorAction Stop

    [Environment]::Exit(0)
}
catch {
    Write-Error -ErrorRecord $_
    [Environment]::Exit(1)
}
