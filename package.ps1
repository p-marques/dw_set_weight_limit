[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$project = $PSScriptRoot
$version = '0.1.0'
$dist = Join-Path $project 'dist'
$archive = Join-Path $dist "SetWeightLimit-$version.zip"

# Explicit allowlist: only these runtime files can enter the release.
$files = @(
    'SetWeightLimit/enabled.txt'
    'SetWeightLimit/scripts/main.lua'
    'SetWeightLimit/scripts/config.lua'
)
foreach ($relative in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $project $relative) -PathType Leaf)) {
        throw "Missing release file: $relative"
    }
}
if ((Get-Item -LiteralPath (Join-Path $project $files[0])).Length -ne 0) {
    throw 'enabled.txt must be empty.'
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$stream = [IO.File]::Open($archive, [IO.FileMode]::Create, [IO.FileAccess]::Write)
$zip = $null
try {
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($relative in $files) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            (Join-Path $project $relative),
            "ue4ss/Mods/$relative",
            [IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
}
finally {
    if ($null -ne $zip) { $zip.Dispose() }
    $stream.Dispose()
}

[pscustomobject]@{
    archive = $archive
    size_bytes = (Get-Item -LiteralPath $archive).Length
    sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
} | ConvertTo-Json
