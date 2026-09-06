[CmdletBinding()]
param(
    [switch]$Check,
    [string]$StyLua,
    [string]$Prettier,
    [string]$Node,
    [string]$PSScriptAnalyzer,
    [string]$ClangFormat,
    [string]$CMakeFormat
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $root '.format.json') -Raw | ConvertFrom-Json
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Resolve-Formatter([string]$Path, [string]$Command, [string]$Parameter) {
    if (-not $Path) {
        $found = Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { throw "Missing $Command. Supply -$Parameter with its executable path; no tools are installed automatically." }
        $Path = $found.Source
    }
    try {
        $item = Get-Item -LiteralPath (Resolve-Path -LiteralPath $Path).ProviderPath
        if ($item.PSIsContainer) { throw 'Expected a file.' }
        return $item.FullName
    } catch {
        throw "Cannot resolve -$Parameter '$Path'. Supply an existing executable file."
    }
}

function Assert-Version([string]$Name, [string]$Actual) {
    $expected = $config.versions.$Name
    if ($Actual -cne $expected) { throw "$Name version mismatch: expected $expected, found '$Actual'. Supply the pinned tool explicitly." }
    Write-Output "$Name $Actual"
}

function Get-Version([string]$Executable) {
    $output = & $Executable --version
    if ($LASTEXITCODE -ne 0) { throw "Version query failed: $Executable" }
    if (($output -join "`n") -notmatch '(?<![\d.])(\d+\.\d+\.\d+)(?![\d.])') { throw "Cannot parse tool version: $Executable" }
    return $Matches[1]
}

# Resolve every required tool and validate versions before any source rewrite.
$StyLua = Resolve-Formatter $StyLua 'stylua.exe' 'StyLua'
Assert-Version 'stylua' (Get-Version $StyLua)
$Prettier = Resolve-Formatter $Prettier 'prettier.cmd' 'Prettier'
$prettierArgs = @()
if ([IO.Path]::GetExtension($Prettier) -in @('.js', '.cjs', '.mjs')) {
    $Node = Resolve-Formatter $Node 'node.exe' 'Node'
    $prettierArgs = @($Prettier)
    $prettierExe = $Node
} else { $prettierExe = $Prettier }
$version = & $prettierExe @prettierArgs --version
if ($LASTEXITCODE -ne 0) { throw 'Prettier version query failed.' }
Assert-Version 'prettier' ($version -join '').Trim()

if ($PSScriptAnalyzer) {
    $modulePath = Resolve-Formatter $PSScriptAnalyzer '' 'PSScriptAnalyzer'
} else {
    $module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object { $_.Version.ToString() -ceq $config.versions.PSScriptAnalyzer } | Select-Object -First 1
    if (-not $module) { throw "Missing PSScriptAnalyzer $($config.versions.PSScriptAnalyzer). Supply -PSScriptAnalyzer with its .psd1 path." }
    $modulePath = $module.Path
}
$manifest = Test-ModuleManifest -Path $modulePath
Assert-Version 'PSScriptAnalyzer' $manifest.Version.ToString()
Import-Module -Name $modulePath -Force -ErrorAction Stop
$formatter = Get-Command Invoke-Formatter -Module PSScriptAnalyzer
if ($formatter.Module.Version.ToString() -cne $config.versions.PSScriptAnalyzer) { throw 'Loaded PSScriptAnalyzer version differs from its manifest.' }
if ($config.files.cpp.Count) {
    $ClangFormat = Resolve-Formatter $ClangFormat 'clang-format.exe' 'ClangFormat'
    Assert-Version 'clang-format' (Get-Version $ClangFormat)
}
if ($config.files.cmake.Count) {
    $CMakeFormat = Resolve-Formatter $CMakeFormat 'cmake-format.exe' 'CMakeFormat'
    Assert-Version 'cmake-format' (Get-Version $CMakeFormat)
}

$selected = @{}
$allFiles = @()
foreach ($group in $config.files.PSObject.Properties) {
    $selected[$group.Name] = @($group.Value | ForEach-Object {
            $path = [IO.Path]::GetFullPath((Join-Path $root $_))
            if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "File selection escapes repository: $_" }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Selected file is missing: $_. Update .format.json if it was removed." }
            $path
        })
    $allFiles += $selected[$group.Name]
}
if (@($allFiles | Select-Object -Unique).Count -ne $allFiles.Count) { throw 'Duplicate formatter file selection.' }

function Normalize-Text([string]$Text) {
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n") + "`n"
}

$script:failed = $false
function Invoke-CheckedTool([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        if (-not $Check) { throw "Formatter failed: $Executable (exit $LASTEXITCODE)" }
        $script:failed = $true
    }
}

# Byte checks also catch BOMs/CRLF that a language formatter may ignore.
foreach ($path in $allFiles) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $text = $utf8.GetString($bytes).TrimStart([char]0xFEFF)
    $normalized = Normalize-Text $text
    if ([Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($utf8.GetBytes($normalized))) {
        if ($Check) {
            Write-Output "Encoding/newline difference: $path"
            $script:failed = $true
        } else { [IO.File]::WriteAllText($path, $normalized, $utf8) }
    }
}

$luaArgs = @('--config-path', (Join-Path $root '.stylua.toml'), '--verify')
if ($Check) { $luaArgs += @('--check', '--output-format', 'Summary') }
Invoke-CheckedTool $StyLua ($luaArgs + $selected.lua)
$prettierMode = if ($Check) { '--check' } else { '--write' }
Invoke-CheckedTool $prettierExe ($prettierArgs + @('--config', (Join-Path $root '.prettierrc.json'), '--no-editorconfig', $prettierMode) + $selected.prettier)

foreach ($path in $selected.powershell) {
    $original = $utf8.GetString([IO.File]::ReadAllBytes($path)).TrimStart([char]0xFEFF)
    $formatted = Normalize-Text (& $formatter -ScriptDefinition $original -Settings (Join-Path $root 'PowerShellFormatting.psd1'))
    if ($original -cne $formatted) {
        if ($Check) {
            Write-Output "PowerShell formatting difference: $path"
            $script:failed = $true
        } else { [IO.File]::WriteAllText($path, $formatted, $utf8) }
    }
}
if ($selected.cpp.Count) {
    $cppArgs = @('--style=file:' + (Join-Path $root '.clang-format'))
    if ($Check) { $cppArgs += @('--dry-run', '--Werror') } else { $cppArgs += '-i' }
    Invoke-CheckedTool $ClangFormat ($cppArgs + $selected.cpp)
}
if ($selected.cmake.Count) {
    $cmakeMode = if ($Check) { '--check' } else { '--in-place' }
    Invoke-CheckedTool $CMakeFormat (@('--config-files', (Join-Path $root '.cmake-format.json'), $cmakeMode) + $selected.cmake)
}
if ($script:failed) {
    Write-Output 'Formatting check failed. Run format.ps1 with the same tool paths to apply formatting.'
    exit 1
}
Write-Output "Formatting $(if ($Check) { 'check passed' } else { 'completed' }): $($allFiles.Count) selected files."
