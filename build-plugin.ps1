# Builds the Block Folding plugin package for one IDE into build\plugin\D<version>-<bits>.
param([ValidateSet('11','12','13')][string]$Version = '13', [switch]$Ide64)
$ErrorActionPreference = 'Stop'
$installations = @{ '11' = 'C:\Programas\Embarcadero\Delphi_11_3'; '12' = 'C:\Programas\Embarcadero\Delphi_12_3'; '13' = 'C:\Programas\Embarcadero\Delphi_13_1_v37' }
$installation = $installations[$Version]
if ($Ide64 -and $Version -eq '11') { throw 'Delphi 11 has no 64-bit IDE.' }
$bits = if ($Ide64) { 'x64' } else { 'x86' }
$output = Join-Path $PSScriptRoot "build\plugin\D$Version-$bits"
New-Item -ItemType Directory -Force -Path $output | Out-Null
$library = Join-Path $installation $(if ($Ide64) { 'lib\win64\release' } else { 'lib\win32\release' })
Push-Location (Join-Path $PSScriptRoot 'src\plugin')
try {
    # Version, icon and licence texts shown by the About window.
    & (Join-Path $installation 'bin\brcc32.exe') '-foBlockFolding.res' 'BlockFolding.rc' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Resource build failed' }
    & (Join-Path $installation $(if ($Ide64) { 'bin\dcc64.exe' } else { 'bin\dcc32.exe' })) '-B' '-Q' "-U$library" "-E$output" "-N0$output" "-LE$output" "-LN$output" 'BlockFolding.dpk'
    if ($LASTEXITCODE -ne 0) { throw 'Plugin build failed' }
} finally { Pop-Location }
Write-Output "Built: $(Join-Path $output 'BlockFolding.bpl')"
