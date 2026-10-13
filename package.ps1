# Builds the plugin for the five targets and assembles what gets distributed:
#
#   dist\CSCoderBlockFolding-<version>.zip    Install.bat / Uninstall.bat, the .bpl of every
#                                             target, the readme and the licence texts
#
# The version is read from src\plugin\BlockFolding.rc, the only place it is written.
# -SkipBuild reuses the .bpl already in build\plugin. -OutputDir writes the zip somewhere
# else than dist\, to try a change without replacing what is published.
param([switch]$SkipBuild, [string]$OutputDir = '')

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Targets = @(
  @{ Version = '11'; Ide64 = $false; Tag = 'D11'; Platform = 'Win32' },
  @{ Version = '12'; Ide64 = $false; Tag = 'D12'; Platform = 'Win32' },
  @{ Version = '12'; Ide64 = $true;  Tag = 'D12'; Platform = 'Win64' },
  @{ Version = '13'; Ide64 = $false; Tag = 'D13'; Platform = 'Win32' },
  @{ Version = '13'; Ide64 = $true;  Tag = 'D13'; Platform = 'Win64' }
)

# 0.<yy>.<mm>.<dd><letter>. The .rc holds it four times; they must agree before anything ships.
$rc = Get-Content -LiteralPath (Join-Path $Root 'src\plugin\BlockFolding.rc') -Raw
function Read-Rc([string]$Pattern) {
  $m = [regex]::Match($rc, $Pattern)
  if (-not $m.Success) { throw "BlockFolding.rc: not found: $Pattern" }
  $m.Groups[1].Value
}
$Version = Read-Rc 'VALUE\s+"ProductVersion",\s*"([^"\\]+)'
$fileText = Read-Rc 'VALUE\s+"FileVersion",\s*"([^"\\]+)'
$fileNumbers = (Read-Rc '(?m)^FILEVERSION\s+([\d,\s]+?)\s*$') -replace '\s', '' -replace ',', '.'
$productNumbers = (Read-Rc '(?m)^PRODUCTVERSION\s+([\d,\s]+?)\s*$') -replace '\s', '' -replace ',', '.'
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+[a-z]?$') { throw "BlockFolding.rc: unexpected ProductVersion '$Version'" }
$numbers = $Version -replace '[a-z]$', ''
if (($fileText -ne $numbers) -or ($fileNumbers -ne $numbers) -or ($productNumbers -ne $numbers)) {
  throw "BlockFolding.rc: the four versions disagree (ProductVersion $Version, FileVersion $fileText, FILEVERSION $fileNumbers, PRODUCTVERSION $productNumbers)"
}

function Get-Bpl($Target) {
  Join-Path $Root ("build\plugin\D$($Target.Version)-" + $(if ($Target.Ide64) { 'x64' } else { 'x86' }) + '\BlockFolding.bpl')
}

if (-not $SkipBuild) {
  foreach ($t in $Targets) {
    if ($t.Ide64) { & (Join-Path $Root 'build-plugin.ps1') -Version $t.Version -Ide64 }
    else { & (Join-Path $Root 'build-plugin.ps1') -Version $t.Version }
  }
}

$Dist = if ($OutputDir -ne '') { $OutputDir } else { Join-Path $Root 'dist' }
$Stage = Join-Path $Dist "CSCoderBlockFolding-$Version"
$Zip = "$Stage.zip"
New-Item -ItemType Directory -Force $Dist | Out-Null
# Only what this script makes is replaced.
Get-ChildItem -LiteralPath $Dist -Filter 'CSCoderBlockFolding-*' | Remove-Item -Recurse -Force
New-Item -ItemType Directory -Force $Stage | Out-Null

foreach ($t in $Targets) {
  $bpl = Get-Bpl $t
  if (-not (Test-Path -LiteralPath $bpl)) { throw "Missing package: $bpl" }
  # What ships must say the version this zip is named after.
  $built = (Get-Item -LiteralPath $bpl).VersionInfo.ProductVersion
  if ($built -ne $Version) { throw "$bpl is version '$built', expected '$Version'. Build it again." }
  $dir = Join-Path $Stage "bin\$($t.Tag)\$($t.Platform)"
  New-Item -ItemType Directory -Force $dir | Out-Null
  Copy-Item -LiteralPath $bpl -Destination $dir
}
Copy-Item (Join-Path $Root 'installer\*') $Stage
Copy-Item (Join-Path $Root 'LICENSE.txt'), (Join-Path $Root 'LICENCA.txt') $Stage
Copy-Item (Join-Path $Root 'installer-readme\README.txt'), (Join-Path $Root 'installer-readme\LEIAME.txt') $Stage

Add-Type -AssemblyName System.IO.Compression.FileSystem
# Entry by entry, to name them with forward slashes: Windows PowerShell would write
# backslashes, which other systems read as part of the file name.
$archive = [System.IO.Compression.ZipFile]::Open($Zip, 'Create')
try {
  foreach ($file in (Get-ChildItem -LiteralPath $Stage -Recurse -File | Sort-Object FullName)) {
    $entry = $file.FullName.Substring($Stage.Length + 1).Replace('\', '/')
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry, 'Optimal')
  }
} finally { $archive.Dispose() }
Remove-Item $Stage -Recurse -Force

Write-Host ''
Write-Host "dist ready: $Zip  ($((Get-Item -LiteralPath $Zip).Length) bytes)"
$archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
try { $archive.Entries | ForEach-Object { '  ' + $_.FullName + '  (' + $_.Length + ' bytes)' } } finally { $archive.Dispose() }
