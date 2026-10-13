# Builds the probe package and runs it inside a real Delphi IDE, without user input.
# The IDE starts with its own registry profile (bds -r), so the normal IDE
# configuration and its installed packages are not read or changed. Everything
# is written below build\.
param(
    [ValidateSet('11','12','13')][string]$Version = '13',
    # Use the 64-bit IDE (Delphi 12 and 13): bin64\bds.exe and a Win64 package.
    [switch]$Ide64,
    [switch]$BuildOnly,
    # Run in the user's normal IDE profile, with the plugins and options it really has. Only
    # with the user's explicit permission: nothing there is changed except the entry of the
    # test package, which is removed when the run ends.
    [switch]$RealProfile,
    # Mode real: a project folder to copy into the session (the original is only read), its
    # project file and the unit to open, both relative to that folder.
    [string]$RealProject,
    [string]$RealDproj,
    [string]$RealUnit,
    # Mouse and keyboard sent through the system, with the test IDE in the foreground.
    [switch]$RealInput,
    # Load the CnPack wizards installed on this machine into the test IDE.
    [switch]$WithCnPack,
    # Code folding in the editor options of the test profile.
    [ValidateSet('True','False')][string]$Elisions = 'True',
    # probe: the five questions. layout: argument types of the folding methods. fold: the prototype.
    [ValidateSet('probe','layout','fold','foldrisk','folddebug','foldkeep','foldmulti','plugin','foldnest','cnpack','real')][string]$Mode = 'probe',
    # Mode foldrisk: the single internal call to try (UnElide2True, UnElide2False, unElideLine).
    [string]$Risk = '',
    [string]$IdeProfile = 'BlockFoldingProbe',
    [int]$TimeoutSeconds = 420
)
$ErrorActionPreference = 'Stop'
$installations = @{
    '11' = @{ Path = 'C:\Programas\Embarcadero\Delphi_11_3'; Bds = '22.0' }
    '12' = @{ Path = 'C:\Programas\Embarcadero\Delphi_12_3'; Bds = '23.0' }
    '13' = @{ Path = 'C:\Programas\Embarcadero\Delphi_13_1_v37'; Bds = '37.0' }
}
if ($RealProfile) { $IdeProfile = 'BDS' }
elseif ($IdeProfile -in 'BDS', 'UnitStylerTest') { throw "Profile $IdeProfile is not ours to use." }
$installation = $installations[$Version].Path
if ($Ide64 -and $Version -eq '11') { throw 'Delphi 11 has no 64-bit IDE.' }
$bits = if ($Ide64) { 'x64' } else { 'x86' }
$bds = Join-Path $installation ($(if ($Ide64) { 'bin64' } else { 'bin' }) + '\bds.exe')
$knownPackages = if ($Ide64) { 'Known Packages x64' } else { 'Known Packages' }
$knownIde = if ($Ide64) { 'Known IDE Packages x64' } else { 'Known IDE Packages' }
$profileKey = "HKCU:\Software\Embarcadero\$IdeProfile\$($installations[$Version].Bds)"
$root = Join-Path $PSScriptRoot "build\D$Version-$bits"
$packageDirectory = Join-Path $root 'pkg'
$session = Join-Path $root ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$report = Join-Path $session 'report.txt'
New-Item -ItemType Directory -Force -Path $packageDirectory | Out-Null

# 1. Probe package.
$library = Join-Path $installation $(if ($Ide64) { 'lib\win64\release' } else { 'lib\win32\release' })
Push-Location (Join-Path $PSScriptRoot 'src')
try {
    Push-Location 'plugin'
    try { & (Join-Path $installation 'bin\brcc32.exe') '-foBlockFolding.res' 'BlockFolding.rc' | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Resource build failed' } } finally { Pop-Location }
    & (Join-Path $installation $(if ($Ide64) { 'bin\dcc64.exe' } else { 'bin\dcc32.exe' })) '-B' '-Q' "-U$library;$(Join-Path $PSScriptRoot 'src\plugin')" "-E$packageDirectory" "-N0$packageDirectory" "-LE$packageDirectory" "-LN$packageDirectory" 'BFProbe.dpk'
    if ($LASTEXITCODE -ne 0) { throw 'Probe package build failed' }
} finally { Pop-Location }
$bpl = Join-Path $packageDirectory 'BFProbe.bpl'
Write-Output "Built: $bpl"
if ($BuildOnly) { return }

New-Item -ItemType Directory -Force -Path $session | Out-Null
$sample = Join-Path $session 'Sample.pas'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'samples\Sample.pas') -Destination $sample
$sample2 = Join-Path $session 'Sample2.pas'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'samples\Sample2.pas') -Destination $sample2
# A unit of about ten thousand lines, for the test with hundreds of folds.
$bigFile = Join-Path $session 'Big.pas'
$big = New-Object Text.StringBuilder
[void]$big.Append("unit Big;`r`n`r`ninterface`r`n`r`nimplementation`r`n`r`n")
foreach ($n in 1..400) {
    [void]$big.Append("procedure P$n(A: Integer);`r`nvar`r`n  I, X: Integer;`r`nbegin`r`n  X := 0;`r`n  try`r`n    for I := 0 to A do`r`n    begin`r`n      if I > 3 then`r`n      begin`r`n        X := X + I;`r`n        X := X * 2;`r`n      end`r`n      else`r`n      begin`r`n        X := X - 1;`r`n      end;`r`n      case X of`r`n        1:`r`n          begin`r`n            X := 10;`r`n            X := X + 1;`r`n          end;`r`n      else`r`n        X := 0;`r`n      end;`r`n    end;`r`n  finally`r`n    X := 0;`r`n  end;`r`nend;`r`n`r`n")
}
[void]$big.Append("end.`r`n")
[IO.File]::WriteAllText($bigFile, $big.ToString(), [Text.Encoding]::ASCII)
# Console project around the sample unit, for the debugging test.
$projectFile = Join-Path $session 'Demo.dpr'
Set-Content -LiteralPath $projectFile -Encoding ASCII -Value @('program Demo;', '', '{$APPTYPE CONSOLE}', '', 'uses', '  Sample in ''Sample.pas'';', '', 'var', '  D: TDemo;', '', 'begin', '  D := TDemo.Create;', '  D.Run(5);', '  D.Free;', 'end.')

function Stop-Ide($process) {
    # Only the instance started here, and what it started, is ended, and without
    # asking it to close: a polite close shows save prompts nobody would answer.
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" -ErrorAction SilentlyContinue)
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit(10000) | Out-Null
    }
    foreach ($child in $children) { Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Mode -eq 'real') {
    # A copy is opened; the folder given is only read.
    $copy = Join-Path $session 'proj'
    Copy-Item -LiteralPath $RealProject -Destination $copy -Recurse
    Get-ChildItem -LiteralPath $copy -Recurse -File | Where-Object IsReadOnly | ForEach-Object { $_.IsReadOnly = $false }
    $projectFile = Join-Path $copy $RealDproj
    $sample = Join-Path $copy $RealUnit
    if (-not (Test-Path -LiteralPath $projectFile) -or -not (Test-Path -LiteralPath $sample)) { throw 'Project file or unit not found in the copy.' }
}

# 2. First start creates the isolated profile from the installation defaults.
if (-not $RealProfile -and -not (Test-Path "$profileKey\$knownIde")) {
    Write-Output "Creating IDE profile $IdeProfile ($($installations[$Version].Bds), $bits)..."
    $first = Start-Process -FilePath $bds -ArgumentList '-r', $IdeProfile, '-ns', '-np' -PassThru
    $deadline = (Get-Date).AddSeconds(180)
    while (-not (Test-Path "$profileKey\$knownIde") -and (Get-Date) -lt $deadline -and -not $first.HasExited) { Start-Sleep -Seconds 2 }
    Start-Sleep -Seconds 20
    Stop-Ide $first
    if (-not (Test-Path "$profileKey\$knownIde")) { throw 'IDE profile was not created' }
}

# 3. Only the probe package is registered, and only in the isolated profile.
if (-not (Test-Path "$profileKey\$knownPackages")) { New-Item -Path "$profileKey\$knownPackages" -Force | Out-Null }
(Get-Item "$profileKey\$knownPackages").Property | Where-Object { $_ -like '*BFProbe*' } | ForEach-Object { Remove-ItemProperty -Path "$profileKey\$knownPackages" -Name $_ }
New-ItemProperty -Path "$profileKey\$knownPackages" -Name $bpl -Value 'Block folding probe (investigation)' -PropertyType String -Force | Out-Null

# A compilation must not leave a progress dialog waiting for someone to click OK.
if (-not $RealProfile) {
if (-not (Test-Path "$profileKey\Compiling")) { New-Item -Path "$profileKey\Compiling" -Force | Out-Null }
Set-ItemProperty -Path "$profileKey\Compiling" -Name 'Show Compiler Progress' -Value 'False'
}

# Editor option under test, and optionally CnPack, only in the isolated profile.
if (-not $RealProfile) {
if (-not (Test-Path "$profileKey\Editor\Options")) { New-Item -Path "$profileKey\Editor\Options" -Force | Out-Null }
Set-ItemProperty -Path "$profileKey\Editor\Options" -Name 'Enable Elisions' -Value $Elisions
if (-not (Test-Path "$profileKey\Experts")) { New-Item -Path "$profileKey\Experts" -Force | Out-Null }
Remove-ItemProperty -Path "$profileKey\Experts" -Name 'CnWizards_Loader' -ErrorAction SilentlyContinue
if ($WithCnPack) { Set-ItemProperty -Path "$profileKey\Experts" -Name 'CnWizards_Loader' -Value 'C:\Programas\Embarcadero\Componentes\CnPack\CnWizards\CnWizLoader.dll' }
}

# 4. Run: the package finds the report path in the environment and drives itself.
$env:BFPROBE_REPORT = $report
$env:BFPROBE_SAMPLE = $sample
$env:BFPROBE_MODE = $Mode
$env:BFPROBE_RISK = $Risk
$env:BFPROBE_INPUT = $(if ($RealInput) { 'real' } else { '' })
$env:BFPROBE_BIG = $bigFile
$env:BFPROBE_SAMPLE2 = $sample2
$env:BFPROBE_PROJECT = $projectFile
try {
    if ($RealProfile) { $ide = Start-Process -FilePath $bds -ArgumentList '-ns', '-np' -PassThru }
    else { $ide = Start-Process -FilePath $bds -ArgumentList '-r', $IdeProfile, '-ns', '-np' -PassThru }
} finally {
    Remove-Item Env:\BFPROBE_REPORT, Env:\BFPROBE_SAMPLE, Env:\BFPROBE_MODE, Env:\BFPROBE_RISK, Env:\BFPROBE_INPUT, Env:\BFPROBE_BIG, Env:\BFPROBE_SAMPLE2, Env:\BFPROBE_PROJECT -ErrorAction SilentlyContinue
}
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$done = $false
while ((Get-Date) -lt $deadline -and -not $ide.HasExited) {
    # The package rewrites the report at every step; a read that collides with a write is simply repeated.
    try { if ((Test-Path $report) -and (Select-String -LiteralPath $report -Pattern '^DONE \|' -Quiet -ErrorAction Stop)) { $done = $true; break } } catch { }
    Start-Sleep -Seconds 2
}
# The IDE may have closed right after the last line was written.
if (-not $done) { Start-Sleep -Seconds 1; try { $done = [bool]((Test-Path $report) -and (Select-String -LiteralPath $report -Pattern '^DONE \|' -Quiet -ErrorAction Stop)) } catch { } }
if ($done -and $Mode -eq 'fold') {
    # The prototype asks the IDE to close with the fold active; nobody answers a dialog, the package does.
    $closed = $ide.WaitForExit(60000)
    Write-Output ("IDE closed by itself with the fold active: $closed" + $(if ($closed) { " (exit code $($ide.ExitCode))" }))
    if (Test-Path $report) { Get-Content -LiteralPath $report -Encoding UTF8 | Select-String -Pattern '^DIALOGO' | ForEach-Object { $_.Line } }
}
$exited = $ide.HasExited -and -not $done
if (-not $done -and -not $ide.HasExited) { Write-Output 'The IDE process was still running at the time limit (hung or blocked).' }
Stop-Ide $ide
# The profile goes back to its defaults for the next run.
if (-not $RealProfile) {
    Set-ItemProperty -Path "$profileKey\Editor\Options" -Name 'Enable Elisions' -Value 'True'
    Remove-ItemProperty -Path "$profileKey\Experts" -Name 'CnWizards_Loader' -ErrorAction SilentlyContinue
}
# The package stays registered only while a run is in progress.
Remove-ItemProperty -Path "$profileKey\$knownPackages" -Name $bpl -ErrorAction SilentlyContinue
Write-Output "Session: $session"
if (-not (Test-Path $report)) { Write-Output 'No report was written.' }
if ($exited) { Write-Output 'The IDE process ended by itself before the probe finished.' }
if (-not $done) { throw 'Probe did not finish (IDE blocked, closed or timed out).' }
Write-Output 'Probe finished.'
