[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$files=[ordered]@{
    'SetWeightLimit/enabled.txt'=$null
    'SetWeightLimit/scripts/main.lua'='src/lua/main.lua'
    'SetWeightLimit/scripts/capacity.lua'='src/lua/capacity.lua'
    'ModSettings/definitions/SetWeightLimit.json'='src/definitions/SetWeightLimit.json'
}
foreach ($entry in $files.GetEnumerator()) {
    if ($null -eq $entry.Value) { continue } # Generate the empty activation entry in the ZIP.
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $entry.Value) -PathType Leaf)) { throw "Missing release file: $($entry.Value)" }
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$dist=Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$archive=Join-Path $dist 'SetWeightLimit-0.3.0.zip'
$stream=[IO.File]::Open($archive,[IO.FileMode]::Create,[IO.FileAccess]::Write)
$zip=$null
try {
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
    foreach ($entry in $files.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            $zip.CreateEntry('ue4ss/Mods/'+$entry.Key) | Out-Null
            continue
        }
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $PSScriptRoot $entry.Value),('ue4ss/Mods/'+$entry.Key),[IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { if ($zip) { $zip.Dispose() }; $stream.Dispose() }
@{archive=$archive;files=$files.Count;sha256=(Get-FileHash -LiteralPath $archive).Hash} | ConvertTo-Json
