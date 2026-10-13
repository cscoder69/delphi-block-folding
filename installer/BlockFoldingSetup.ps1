# CS.Coder - Block Folding: install / uninstall for every Delphi found on this PC.
# Run through Install.bat or Uninstall.bat. Works per Windows user, no administrator needed.
#
#   -Action install     copies the packages and registers them in each Delphi (11, 12, 13)
#   -Action uninstall   unregisters and removes them; add -RemoveData to delete the settings too
#
# The remaining parameters exist for automated tests.
param(
  [Parameter(Mandatory = $true)][ValidateSet('install', 'uninstall')][string]$Action,
  [switch]$RemoveData,
  [string]$RegistryRoot = 'Software\Embarcadero\BDS',
  [string]$InstallDir = '',
  [string]$SourceDir = '',
  [switch]$SkipProcessCheck
)

$ErrorActionPreference = 'Stop'
# Resolved here, not as parameter defaults: Windows PowerShell 5.1 does not
# always have $PSScriptRoot available while binding parameters.
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($InstallDir -eq '') { $InstallDir = Join-Path $env:LOCALAPPDATA 'CSCoder\BlockFolding\bin' }
if ($SourceDir -eq '') { $SourceDir = Join-Path $Here 'bin' }
$Product = 'CS.Coder - Block Folding'
# What Delphi shows in Component > Install Packages.
$Description = "$Product (https://www.cscoder.com.br)"
$IssuesUrl = 'https://github.com/cscoder69/delphi-block-folding/issues'
# The package file has the same name for every Delphi, so each one gets its own folder.
$PackageFile = 'BlockFolding.bpl'
$Versions = @(
  @{ Key = '22.0'; Tag = 'D11'; Name = 'Delphi 11' },
  @{ Key = '23.0'; Tag = 'D12'; Name = 'Delphi 12' },
  @{ Key = '37.0'; Tag = 'D13'; Name = 'Delphi 13' }
)
# The package wherever it was registered from, including copies registered by hand.
$OurPackage = '(?i)(^|\\)BlockFolding\.bpl$'
# The plugin keeps its settings below the registry key of each Delphi.
$SettingsKey = 'CSCoder\BlockFolding'

function Say([string]$Text) { Write-Host $Text }

function Open-Key([string]$SubPath, [bool]$Writable) {
  [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubPath, $Writable)
}

# Removes our entries from one key. Returns how many were removed.
function Remove-OurValues([string]$SubPath) {
  $key = Open-Key $SubPath $true
  if (-not $key) { return 0 }
  try {
    $names = @($key.GetValueNames() | Where-Object { $_ -match $OurPackage })
    foreach ($n in $names) { $key.DeleteValue($n, $false) }
    return $names.Count
  } finally { $key.Close() }
}

function Remove-OurSubKeys([string]$SubPath) {
  $key = Open-Key $SubPath $true
  if (-not $key) { return }
  try {
    foreach ($n in @($key.GetSubKeyNames() | Where-Object { $_ -match $OurPackage })) {
      $key.DeleteSubKeyTree($n, $false)
    }
  } finally { $key.Close() }
}

function Unregister-Version($v) {
  $base = "$RegistryRoot\$($v.Key)"
  $n = 0
  foreach ($k in 'Known Packages', 'Known Packages x64', 'Disabled Packages', 'Disabled Packages x64') {
    $n += Remove-OurValues "$base\$k"
  }
  foreach ($k in 'Package Cache', 'Package Cache x64') { Remove-OurSubKeys "$base\$k" }
  return $n
}

function Register-Package($v, [string]$Platform, [string]$KeyName) {
  $source = Join-Path $SourceDir "$($v.Tag)\$Platform\$PackageFile"
  if (-not (Test-Path $source)) { return $false }
  # No such key: this Delphi has no IDE for that platform.
  $key = Open-Key "$RegistryRoot\$($v.Key)\$KeyName" $true
  if (-not $key) { return $false }
  try {
    $targetDir = Join-Path $InstallDir "$($v.Tag)\$Platform"
    New-Item -ItemType Directory -Force $targetDir | Out-Null
    $target = Join-Path $targetDir $PackageFile
    Copy-Item $source $target -Force
    $key.SetValue($target, $Description, [Microsoft.Win32.RegistryValueKind]::String)
    return $true
  } finally { $key.Close() }
}

function Find-Versions {
  $found = @()
  foreach ($v in $Versions) {
    $key = Open-Key "$RegistryRoot\$($v.Key)" $false
    if (-not $key) { continue }
    try {
      # A leftover key without RootDir is a Delphi that is no longer installed.
      if ([string]$key.GetValue('RootDir', '') -ne '') { $found += $v }
    } finally { $key.Close() }
  }
  return $found
}

# Deletes the settings of one Delphi. Returns $true when there were any.
function Remove-Settings($v) {
  $parentPath = "$RegistryRoot\$($v.Key)\" + (Split-Path $SettingsKey -Parent)
  $parent = Open-Key $parentPath $true
  if (-not $parent) { return $false }
  try {
    $leaf = Split-Path $SettingsKey -Leaf
    $had = @($parent.GetSubKeyNames()) -contains $leaf
    if ($had) { $parent.DeleteSubKeyTree($leaf, $false) }
    $empty = ($parent.SubKeyCount -eq 0) -and ($parent.ValueCount -eq 0)
  } finally { $parent.Close() }
  # The key above is shared by the CS.Coder tools: it only goes when nothing else is in it.
  if ($empty) {
    $base = Open-Key "$RegistryRoot\$($v.Key)" $true
    if ($base) { try { $base.DeleteSubKey((Split-Path $SettingsKey -Parent), $false) } finally { $base.Close() } }
  }
  return $had
}

# ---------------------------------------------------------------------------

Say ''
Say "$Product - $Action"
Say ''
if ($Action -eq 'install') {
  # Said before anything is installed.
  Say 'BETA VERSION: still being tested and may have defects.'
  Say "Report problems at $IssuesUrl"
  Say ''
}

# Delphi rewrites its package list when it closes, which would undo our changes.
if (-not $SkipProcessCheck -and (Get-Process -Name 'bds' -ErrorAction SilentlyContinue)) {
  Say 'Delphi is running. Close every Delphi window and run this again.'
  Say 'Nothing was changed.'
  exit 2
}

if ($Action -eq 'install') {
  $found = @(Find-Versions)
  if ($found.Count -eq 0) {
    Say 'No supported Delphi (11, 12 or 13) was found for this Windows user.'
    exit 3
  }
  $done = 0
  foreach ($v in $found) {
    [void](Unregister-Version $v)   # also clears older copies registered from other folders
    $w32 = Register-Package $v 'Win32' 'Known Packages'
    $w64 = Register-Package $v 'Win64' 'Known Packages x64'
    if ($w32 -or $w64) {
      $done++
      $bits = @(); if ($w32) { $bits += '32-bit' }; if ($w64) { $bits += '64-bit' }
      Say ("  [OK] $($v.Name) (" + ($bits -join ', ') + ')')
    } else {
      Say "  [--] $($v.Name): package for this version is not in this download"
    }
  }
  Say ''
  if ($done -eq 0) {
    Say 'Nothing was installed.'
    exit 4
  }
  Say 'Done. Open Delphi: the commands are in the main menu, CS.Coder > Block Folding.'
  Say "Installed in: $InstallDir"
  exit 0
}

# uninstall: every version, installed or not
$removed = 0
foreach ($v in $Versions) { $removed += (Unregister-Version $v) }
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
Say "  Package registrations removed: $removed"

$dataDir = Split-Path $InstallDir -Parent
if ($RemoveData) {
  $cleared = 0
  foreach ($v in $Versions) { if (Remove-Settings $v) { $cleared++ } }
  # Only our own files are deleted, never a whole folder blindly.
  foreach ($f in 'diagnostico.log', 'diagnostico.on') {
    $p = Join-Path $dataDir $f
    if (Test-Path $p) { Remove-Item $p -Force }
  }
  Say "  Settings removed (Delphi versions that had them: $cleared), and the diagnostic log."
} else {
  Say '  Your settings were kept. To delete them too, run: Uninstall.bat /data'
}
if ((Test-Path $dataDir) -and -not (Get-ChildItem $dataDir -Force)) { Remove-Item $dataDir -Force }
Say ''
Say 'Done.'
exit 0
