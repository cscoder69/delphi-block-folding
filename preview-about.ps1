# Renders the About window to PNG files in build\about, outside the IDE: the five
# languages in light colours and Portuguese in dark colours.
param([ValidateSet('11','12','13')][string]$Version = '12')
$ErrorActionPreference = 'Stop'
$installations = @{ '11' = 'C:\Programas\Embarcadero\Delphi_11_3'; '12' = 'C:\Programas\Embarcadero\Delphi_12_3'; '13' = 'C:\Programas\Embarcadero\Delphi_13_1_v37' }
$installation = $installations[$Version]
$output = Join-Path $PSScriptRoot 'build\about'
New-Item -ItemType Directory -Force -Path $output | Out-Null
Push-Location (Join-Path $PSScriptRoot 'src\plugin')
try {
    & (Join-Path $installation 'bin\brcc32.exe') '-foBlockFolding.res' 'BlockFolding.rc' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Resource build failed' }
} finally { Pop-Location }
Push-Location (Join-Path $PSScriptRoot 'tests')
try {
    & (Join-Path $installation 'bin\dcc32.exe') '-B' '-Q' "-U$(Join-Path $installation 'lib\win32\release')" "-E$output" "-NU$output" 'AboutPreview.dpr'
    if ($LASTEXITCODE -ne 0) { throw 'Preview build failed' }
} finally { Pop-Location }
& (Join-Path $output 'AboutPreview.exe') $output
if ($LASTEXITCODE -ne 0) { throw 'Preview failed' }
Get-ChildItem -LiteralPath $output -Filter 'about-*.png' | ForEach-Object { $_.FullName }
