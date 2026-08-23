#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

function Get-ClipboardImagePath {
    [CmdletBinding()]
    param()

    $lTimestamp = [DateTime]::Now.ToString(
        'yyyyMMdd_HHmmss_fff',
        [Globalization.CultureInfo]::InvariantCulture)
    $lPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("screenshot_{0}.png" -f $lTimestamp)
    $lSuffix = 1

    while (Test-Path -LiteralPath $lPath) {
        $lPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("screenshot_{0}_{1}.png" -f $lTimestamp, $lSuffix)
        $lSuffix++
    }

    return [IO.Path]::GetFullPath($lPath)
}

function Test-ClipboardPngPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $lFullPath = [IO.Path]::GetFullPath($Path)
        $lDirectory = [IO.Path]::GetDirectoryName($lFullPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $lTempDirectory = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)

        if (-not [string]::Equals($lDirectory, $lTempDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        if (-not [string]::Equals([IO.Path]::GetExtension($lFullPath), '.png', [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        if (-not (Test-Path -LiteralPath $lFullPath -PathType Leaf)) {
            return $false
        }

        $lStream = [IO.File]::OpenRead($lFullPath)
        try {
            $lSignature = [byte[]]::new(8)
            if ($lStream.Read($lSignature, 0, $lSignature.Length) -ne $lSignature.Length) {
                return $false
            }

            return [Linq.Enumerable]::SequenceEqual(
                $lSignature,
                [byte[]]@(137, 80, 78, 71, 13, 10, 26, 10))
        }
        finally {
            $lStream.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Get-InvertedBitmap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Image]$Image
    )

    $lBitmap = [System.Drawing.Bitmap]::new(
        $Image.Width,
        $Image.Height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $lGraphics = $null
    $lImageAttributes = $null

    try {
        $lGraphics = [System.Drawing.Graphics]::FromImage($lBitmap)
        $lGraphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy

        $lColorMatrix = [System.Drawing.Imaging.ColorMatrix]::new()
        $lColorMatrix.Matrix00 = -1
        $lColorMatrix.Matrix11 = -1
        $lColorMatrix.Matrix22 = -1
        $lColorMatrix.Matrix40 = 1
        $lColorMatrix.Matrix41 = 1
        $lColorMatrix.Matrix42 = 1

        $lImageAttributes = [System.Drawing.Imaging.ImageAttributes]::new()
        $lImageAttributes.SetColorMatrix($lColorMatrix)
        $lGraphics.DrawImage(
            $Image,
            [System.Drawing.Rectangle]::new(0, 0, $Image.Width, $Image.Height),
            0,
            0,
            $Image.Width,
            $Image.Height,
            [System.Drawing.GraphicsUnit]::Pixel,
            $lImageAttributes)

        return $lBitmap
    }
    catch {
        $lBitmap.Dispose()
        throw
    }
    finally {
        if ($null -ne $lImageAttributes) {
            $lImageAttributes.Dispose()
        }

        if ($null -ne $lGraphics) {
            $lGraphics.Dispose()
        }
    }
}

function ConvertTo-InvertedClipboardPng {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-ClipboardPngPath -Path $Path)) {
        throw 'Clipboard does not contain a valid PNG file in the temp directory.'
    }

    $lFullPath = [IO.Path]::GetFullPath($Path)
    $lReplacementPath = Join-Path (
        [IO.Path]::GetDirectoryName($lFullPath)) (
        '.{0}.{1}.png' -f [IO.Path]::GetFileNameWithoutExtension($lFullPath), [guid]::NewGuid().ToString('N'))
    $lBackupPath = $lReplacementPath + '.bak'
    $lSourceImage = $null
    $lInvertedBitmap = $null

    try {
        $lSourceImage = [System.Drawing.Image]::FromFile($lFullPath)
        $lInvertedBitmap = Get-InvertedBitmap -Image $lSourceImage
        $lSourceImage.Dispose()
        $lSourceImage = $null

        $lInvertedBitmap.Save($lReplacementPath, [System.Drawing.Imaging.ImageFormat]::Png)
        [IO.File]::Replace($lReplacementPath, $lFullPath, $lBackupPath)

        return $lFullPath
    }
    finally {
        if ($null -ne $lInvertedBitmap) {
            $lInvertedBitmap.Dispose()
        }

        if ($null -ne $lSourceImage) {
            $lSourceImage.Dispose()
        }

        if (Test-Path -LiteralPath $lReplacementPath) {
            Remove-Item -LiteralPath $lReplacementPath -Force
        }

        if (Test-Path -LiteralPath $lBackupPath) {
            Remove-Item -LiteralPath $lBackupPath -Force
        }
    }
}

function Get-ClipboardImage {
    [CmdletBinding()]
    param()

    if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) {
        return $null
    }

    return [System.Windows.Forms.Clipboard]::GetImage()
}

function Invoke-ClipboardNoImageNotification {
    [CmdletBinding()]
    param()

    $lAudioPath = Join-Path $PSScriptRoot 'clipboard-no-image.wav'
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

function Save-ClipboardImage {
    [CmdletBinding()]
    param()

    $lClipboardImage = $null
    $lOutputBitmap = $null

    try {
        $lClipboardImage = Get-ClipboardImage
        if ($null -eq $lClipboardImage) {
            Invoke-ClipboardNoImageNotification
            throw 'Clipboard does not contain an image.'
        }

        $lOutputBitmap = [System.Drawing.Bitmap]::new($lClipboardImage)
        $lOutputPath = Get-ClipboardImagePath
        $lOutputBitmap.Save($lOutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
        Set-Clipboard -Value $lOutputPath -ErrorAction Stop

        return $lOutputPath
    }
    finally {
        if ($null -ne $lOutputBitmap) {
            $lOutputBitmap.Dispose()
        }

        if (($null -ne $lClipboardImage) -and ($lClipboardImage -is [System.IDisposable])) {
            $lClipboardImage.Dispose()
        }
    }
}

Export-ModuleMember -Function ConvertTo-InvertedClipboardPng, Save-ClipboardImage
