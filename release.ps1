[CmdletBinding()]
param(
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Commit = $env:GITHUB_SHA
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Commit -notmatch '^[a-fA-F0-9]{40}$') {
    throw 'Release requires a GitHub owner/repository and the full triggering commit SHA.'
}
if (-not $env:GITHUB_TOKEN) { throw 'GITHUB_TOKEN with contents: write is required.' }
$version = & (Join-Path $PSScriptRoot 'version.ps1')
$tag = "v$version"
$api = "https://api.github.com/repos/$Repository"
$headers = @{
    Authorization          = "Bearer $env:GITHUB_TOKEN"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'SetWeightLimit-release'
}

function Invoke-GitHub([string]$Method, [string]$Path, $Body = $null) {
    $arguments = @{ Method = $Method; Uri = "$api/$Path"; Headers = $headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $arguments.ContentType = 'application/json; charset=utf-8'
        $arguments.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    # REST arrays are emitted as one pipeline object; enumerate them for callers.
    $response = Invoke-RestMethod @arguments
    $response
}

function Get-HttpStatus($Failure) {
    if ($Failure.Exception.PSObject.Properties['Response'] -and $null -ne $Failure.Exception.Response) {
        return [int]$Failure.Exception.Response.StatusCode
    }
    return 0
}

function Find-VersionRelease {
    # List with the write-authorized token: published releases AND drafts, across all pages.
    for ($page = 1; ; $page++) {
        $releases = @(Invoke-GitHub 'GET' "releases?per_page=100&page=$page")
        foreach ($release in $releases) {
            if ($release.tag_name -ceq $tag) { return $release }
        }
        if ($releases.Count -lt 100) { return $null }
    }
}

function Assert-TagTarget {
    try { $reference = Invoke-GitHub 'GET' "git/ref/tags/$tag" }
    catch {
        if ((Get-HttpStatus $_) -eq 404) { return $false }
        throw
    }
    $object = $reference.object
    for ($depth = 0; $object.type -eq 'tag' -and $depth -lt 16; $depth++) {
        $annotation = Invoke-GitHub 'GET' "git/tags/$($object.sha)"
        $object = $annotation.object
    }
    if ($object.type -ne 'commit' -or $object.sha -ine $Commit) {
        throw "Tag $tag does not resolve to triggering commit $Commit. Existing tags are never moved."
    }
    return $true
}

function Get-StreamHash([IO.Stream]$Stream) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($Stream)) }
    finally { $hasher.Dispose() }
}

function Assert-ReleaseArchive([string]$Path) {
    $expected = @{
        'ue4ss/Mods/SetWeightLimit/enabled.txt'                  = $null
        'ue4ss/Mods/SetWeightLimit/scripts/main.lua'             = 'src/lua/main.lua'
        'ue4ss/Mods/SetWeightLimit/scripts/capacity.lua'         = 'src/lua/capacity.lua'
        'ue4ss/Mods/SetWeightLimit/scripts/config.lua'           = 'src/lua/config.lua'
        'ue4ss/Mods/ModSettings/definitions/SetWeightLimit.json' = 'src/definitions/SetWeightLimit.json'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($zip.Entries.Count -ne 5) { throw 'Expected exactly five release entries.' }
        $seen = @{}
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name -cnotin @($expected.Keys) -or $seen.ContainsKey($name)) { throw "Unexpected or duplicate ZIP entry: $name" }
            $seen[$name] = $true
            if ($null -eq $expected[$name]) {
                if ($entry.Length -ne 0) { throw 'Activation file must be empty.' }
                continue
            }
            $inputStream = $entry.Open()
            $sourceStream = [IO.File]::OpenRead((Join-Path $PSScriptRoot $expected[$name]))
            try {
                if ((Get-StreamHash $inputStream) -cne (Get-StreamHash $sourceStream)) { throw "ZIP source mismatch: $name" }
            } finally { $inputStream.Dispose(); $sourceStream.Dispose() }
        }
    } finally { $zip.Dispose() }
}

if (Find-VersionRelease) {
    Write-Output "Release $tag already exists (published or draft); nothing changed."
    return
}
$tagExists = Assert-TagTarget
$package = & (Join-Path $PSScriptRoot 'package.ps1') | ConvertFrom-Json
$archive = Join-Path $PSScriptRoot "dist/SetWeightLimit-$version.zip"
if ($package.archive -cne $archive -or $package.files -ne 5) { throw 'Unexpected package output.' }
Assert-ReleaseArchive $archive

# Recheck after packaging, before making any GitHub changes.
if (Find-VersionRelease) {
    Write-Output "Release $tag appeared during packaging; nothing published by this run."
    return
}
if (-not $tagExists) {
    try { $null = Invoke-GitHub 'POST' 'git/refs' @{ ref = "refs/tags/$tag"; sha = $Commit } }
    catch {
        if ((Get-HttpStatus $_) -notin @(409, 422)) { throw }
        if (Find-VersionRelease) {
            Write-Output "Release $tag was created concurrently; nothing changed."
            return
        }
        if (-not (Assert-TagTarget)) { throw }
    }
}
# Covers annotated tags and a concurrent change since the first check.
if (-not (Assert-TagTarget)) { throw "Tag $tag disappeared before release creation." }
try {
    $release = Invoke-GitHub 'POST' 'releases' @{
        tag_name = $tag; target_commitish = $Commit; name = "SetWeightLimit $version"
        draft = $true; prerelease = $false; generate_release_notes = $true
    }
} catch {
    if ((Get-HttpStatus $_) -in @(409, 422) -and (Find-VersionRelease)) {
        Write-Output "Release $tag was created concurrently; existing release left untouched."
        return
    }
    throw
}
try {
    $filename = [IO.Path]::GetFileName($archive)
    $uploadUrl = "https://uploads.github.com/repos/$Repository/releases/$($release.id)/assets?name=$filename"
    $asset = Invoke-RestMethod -Method POST -Uri $uploadUrl -Headers $headers -ContentType 'application/zip' -InFile $archive -ErrorAction Stop
    if ($asset.name -cne $filename -or $asset.state -cne 'uploaded' -or $asset.size -ne (Get-Item -LiteralPath $archive).Length) {
        throw 'Uploaded asset was not confirmed complete.'
    }
    if (-not (Assert-TagTarget)) { throw 'Release tag disappeared before publication.' }
    $published = Invoke-GitHub 'PATCH' "releases/$($release.id)" @{ draft = $false; make_latest = 'legacy' }
    Write-Output "Published $tag with $filename`: $($published.html_url)"
} catch {
    Write-Warning "Release $tag (ID $($release.id)) was not confirmed published. Inspect it manually; this workflow does not delete or repair existing releases."
    throw
}
