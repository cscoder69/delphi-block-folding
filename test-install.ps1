# Tests the installer exactly as it ships: the zip of dist\ is extracted to a folder
# outside the project and everything runs from there, without user input.
#
#   1. Rules of the installer, in a registry key made up for the test: no Delphi, a
#      missing version, an old registration made by hand, update, uninstall, /data.
#   2. Each of the five IDEs with its isolated registry profile (bds -r): the package
#      the installer put there is loaded, the menu is looked for and a block is folded
#      and opened. With that IDE open, the installer must refuse to run.
#
# Nothing here touches the normal Delphi profile or the real settings of the plugin.
param(
    [string]$Zip = '',
    [string[]]$Targets = @('11', '12', '12x64', '13', '13x64'),
    [switch]$SkipIde,
    [string]$IdeProfile = 'BlockFoldingProbe',
    [int]$TimeoutSeconds = 240
)
$ErrorActionPreference = 'Stop'
if ($IdeProfile -in 'BDS', 'UnitStylerTest', 'UnitStylerReal') { throw "Profile $IdeProfile is not ours to use." }
$Root = $PSScriptRoot
if ($Zip -eq '') {
    $Zip = (Get-ChildItem -LiteralPath (Join-Path $Root 'dist') -Filter 'CSCoderBlockFolding-*.zip' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
}
if (-not $Zip -or -not (Test-Path -LiteralPath $Zip)) { throw 'No zip in dist\. Run package.ps1 first.' }
$ZipVersion = [IO.Path]::GetFileNameWithoutExtension($Zip) -replace '^CSCoderBlockFolding-', ''
$Bds = @{ '11' = '22.0'; '12' = '23.0'; '13' = '37.0' }
$Names = @{ '11' = 'Delphi 11'; '12' = 'Delphi 12'; '13' = 'Delphi 13' }

$Work = Join-Path $env:TEMP ('CSCoderBlockFoldingTest\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Extracted = Join-Path $Work 'zip'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Extracted)
$Setup = Join-Path $Extracted 'BlockFoldingSetup.ps1'
Write-Output "Zip: $Zip ($((Get-Item -LiteralPath $Zip).Length) bytes), version $ZipVersion"
Write-Output "Extracted to: $Extracted"

$script:Failures = 0
$script:Checks = 0
function Check([string]$What, [bool]$Ok, [string]$Detail = '') {
    $script:Checks++
    if (-not $Ok) { $script:Failures++ }
    Write-Output ($(if ($Ok) { '  ok      ' } else { '  FAILED  ' }) + $What + $(if ($Detail -ne '' -and -not $Ok) { "  <<< $Detail" }))
}
function Run-Setup([string[]]$Arguments) {
    $lines = & powershell -NoProfile -ExecutionPolicy Bypass -File $Setup @Arguments 2>&1 | ForEach-Object { "$_" }
    @{ Code = $LASTEXITCODE; Text = ($lines -join "`n") }
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
# Names of the values of a key that are a Block Folding package.
function Ours([string]$Key) {
    if (-not (Test-Path -LiteralPath $Key)) { return @() }
    @((Get-Item -LiteralPath $Key).Property | Where-Object { $_ -match '(?i)(^|\\)BlockFolding\.bpl$' })
}
function Packed([string]$Tag, [string]$Platform) { Join-Path $Extracted "bin\$Tag\$Platform\BlockFolding.bpl" }

# What an installed package must be: the file of the zip, registered once, with its description.
function Check-Installed([string]$Label, [string]$RegistryRoot, [string]$InstallDir, [string]$Version, [string]$Platform) {
    $tag = "D$Version"
    $file = Join-Path $InstallDir "$tag\$Platform\BlockFolding.bpl"
    $key = "HKCU:\$RegistryRoot\$($Bds[$Version])\" + $(if ($Platform -eq 'Win64') { 'Known Packages x64' } else { 'Known Packages' })
    $exists = Test-Path -LiteralPath $file
    Check "$Label $tag $Platform`: file is in $tag\$Platform" $exists
    if ($exists) {
        Check "$Label $tag $Platform`: same bytes as the one in the zip (SHA-256)" ((Hash $file) -eq (Hash (Packed $tag $Platform)))
        $v = (Get-Item -LiteralPath $file).VersionInfo.ProductVersion
        Check "$Label $tag $Platform`: version $ZipVersion" ($v -eq $ZipVersion) $v
    }
    $ours = @(Ours $key)
    Check "$Label $tag $Platform`: registered once, pointing at that file" (($ours.Count -eq 1) -and ($ours[0] -eq $file)) ($ours -join ' ; ')
    if ($ours.Count -eq 1) {
        $text = (Get-ItemProperty -LiteralPath $key).($ours[0])
        Check "$Label $tag $Platform`: description in the package list" ($text -eq 'CS.Coder - Block Folding (https://www.cscoder.com.br)') $text
    }
}

# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '== 1. Rules of the installer (made-up registry key)'
$Fake = 'Software\CSCoderTest\BlockFoldingInstall'
$FakeKey = "HKCU:\$Fake"
$FakeDir = Join-Path $Work 'fake'
$FakeBin = Join-Path $FakeDir 'bin'
$FakeArgs = @('-RegistryRoot', $Fake, '-InstallDir', $FakeBin, '-SkipProcessCheck')
if (Test-Path -LiteralPath $FakeKey) { Remove-Item -LiteralPath $FakeKey -Recurse -Force }
New-Item -Path $FakeKey -Force | Out-Null

$r = Run-Setup (@('-Action', 'install') + $FakeArgs)
Check 'no Delphi at all: says so and stops (exit 3)' (($r.Code -eq 3) -and ($r.Text -match 'No supported Delphi')) "exit $($r.Code)"
Check 'no Delphi at all: nothing copied' (-not (Test-Path -LiteralPath $FakeBin))

# Delphi 11 with an old registration made by hand; Delphi 12 uninstalled (key without
# RootDir); Delphi 13 with both IDEs.
New-Item -Path "$FakeKey\22.0\Known Packages" -Force | Out-Null
Set-ItemProperty -LiteralPath "$FakeKey\22.0" -Name 'RootDir' -Value 'X:\NoSuchDelphi11\'
$oldPath = 'X:\old place\dist\D11-x86\v0.3\BlockFolding.bpl'
Set-ItemProperty -LiteralPath "$FakeKey\22.0\Known Packages" -Name $oldPath -Value 'registered by hand'
Set-ItemProperty -LiteralPath "$FakeKey\22.0\Known Packages" -Name 'X:\other\OtherBlockFolding.bpl' -Value 'not ours'
Set-ItemProperty -LiteralPath "$FakeKey\22.0\Known Packages" -Name 'X:\other\BFProbe.bpl' -Value 'not ours'
New-Item -Path "$FakeKey\22.0\Disabled Packages" -Force | Out-Null
Set-ItemProperty -LiteralPath "$FakeKey\22.0\Disabled Packages" -Name 'X:\older\BlockFolding.bpl' -Value 'disabled once'
New-Item -Path "$FakeKey\22.0\Package Cache\BlockFolding.bpl" -Force | Out-Null
New-Item -Path "$FakeKey\22.0\Package Cache\Other.bpl" -Force | Out-Null
New-Item -Path "$FakeKey\23.0\Known Packages" -Force | Out-Null
New-Item -Path "$FakeKey\37.0\Known Packages" -Force | Out-Null
New-Item -Path "$FakeKey\37.0\Known Packages x64" -Force | Out-Null
Set-ItemProperty -LiteralPath "$FakeKey\37.0" -Name 'RootDir' -Value 'X:\NoSuchDelphi13\'

$r = Run-Setup (@('-Action', 'install') + $FakeArgs)
Check 'install: exit 0' ($r.Code -eq 0) "exit $($r.Code)`n$($r.Text)"
Check 'install: one line for Delphi 11, 32-bit only' ($r.Text -match '(?m)^\s*\[OK\] Delphi 11 \(32-bit\)\s*$')
Check 'install: one line for Delphi 13, both IDEs' ($r.Text -match '(?m)^\s*\[OK\] Delphi 13 \(32-bit, 64-bit\)\s*$')
Check 'install: Delphi 12 without RootDir is skipped, no line' ($r.Text -notmatch 'Delphi 12')
Check 'install: nothing copied for the skipped Delphi 12' (-not (Test-Path -LiteralPath (Join-Path $FakeBin 'D12')))
Check 'install: nothing registered for the skipped Delphi 12' ((Ours "$FakeKey\23.0\Known Packages").Count -eq 0)
Check 'install: no 64-bit copy for Delphi 11' (-not (Test-Path -LiteralPath (Join-Path $FakeBin 'D11\Win64')))
Check-Installed 'install' $Fake $FakeBin '11' 'Win32'
Check-Installed 'install' $Fake $FakeBin '13' 'Win32'
Check-Installed 'install' $Fake $FakeBin '13' 'Win64'
$kp = @((Get-Item -LiteralPath "$FakeKey\22.0\Known Packages").Property)
Check 'migration: the registration made by hand is gone' ($kp -notcontains $oldPath)
Check 'migration: packages that are not ours stay registered' (($kp -contains 'X:\other\OtherBlockFolding.bpl') -and ($kp -contains 'X:\other\BFProbe.bpl'))
Check 'migration: gone from the disabled packages too' ((Ours "$FakeKey\22.0\Disabled Packages").Count -eq 0)
Check 'migration: its package cache is cleared, others stay' ((-not (Test-Path -LiteralPath "$FakeKey\22.0\Package Cache\BlockFolding.bpl")) -and (Test-Path -LiteralPath "$FakeKey\22.0\Package Cache\Other.bpl"))

# Settings and log as the plugin leaves them, next to something of another tool.
New-Item -Path "$FakeKey\22.0\CSCoder\BlockFolding" -Force | Out-Null
Set-ItemProperty -LiteralPath "$FakeKey\22.0\CSCoder\BlockFolding" -Name 'Marker' -Value 'mine'
New-Item -Path "$FakeKey\22.0\CSCoder\OtherTool" -Force | Out-Null
New-Item -Path "$FakeKey\37.0\CSCoder\BlockFolding" -Force | Out-Null
Set-ItemProperty -LiteralPath "$FakeKey\37.0\CSCoder\BlockFolding" -Name 'Marker' -Value 'mine too'
Set-Content -LiteralPath (Join-Path $FakeDir 'diagnostico.log') -Value 'log'

$r = Run-Setup (@('-Action', 'install') + $FakeArgs)
Check 'update (install over the installed one): exit 0' ($r.Code -eq 0) "exit $($r.Code)"
Check-Installed 'update' $Fake $FakeBin '11' 'Win32'
Check-Installed 'update' $Fake $FakeBin '13' 'Win64'
Check 'update: settings kept' ((Get-ItemProperty -LiteralPath "$FakeKey\22.0\CSCoder\BlockFolding").Marker -eq 'mine')

# A download without the packages of one version.
$Partial = Join-Path $Work 'partial\bin'
Copy-Item -LiteralPath (Join-Path $Extracted 'bin') -Destination $Partial -Recurse
Remove-Item -LiteralPath (Join-Path $Partial 'D13') -Recurse -Force
$r = Run-Setup (@('-Action', 'install', '-SourceDir', $Partial) + $FakeArgs)
Check 'package of a version missing in the download: that Delphi gets a [--] line, the others install' (($r.Code -eq 0) -and ($r.Text -match '\[--\] Delphi 13') -and ($r.Text -match '\[OK\] Delphi 11'))
$r = Run-Setup (@('-Action', 'install') + $FakeArgs)

$r = Run-Setup (@('-Action', 'uninstall') + $FakeArgs)
Check 'uninstall: exit 0, three registrations removed' (($r.Code -eq 0) -and ($r.Text -match 'registrations removed: 3')) "exit $($r.Code)`n$($r.Text)"
Check 'uninstall: no registration left' (((Ours "$FakeKey\22.0\Known Packages") + (Ours "$FakeKey\37.0\Known Packages") + (Ours "$FakeKey\37.0\Known Packages x64")).Count -eq 0)
Check 'uninstall: package files removed' (-not (Test-Path -LiteralPath $FakeBin))
Check 'uninstall: settings kept' ((Test-Path -LiteralPath "$FakeKey\22.0\CSCoder\BlockFolding") -and (Test-Path -LiteralPath "$FakeKey\37.0\CSCoder\BlockFolding"))
Check 'uninstall: log kept' (Test-Path -LiteralPath (Join-Path $FakeDir 'diagnostico.log'))
Check 'uninstall: packages that are not ours stay registered' (@((Get-Item -LiteralPath "$FakeKey\22.0\Known Packages").Property).Count -eq 2)

$r = Run-Setup (@('-Action', 'install') + $FakeArgs)
$r = Run-Setup (@('-Action', 'uninstall', '-RemoveData') + $FakeArgs)
Check 'uninstall /data: exit 0, says the settings of two Delphi were removed' (($r.Code -eq 0) -and ($r.Text -match 'had them: 2')) "exit $($r.Code)`n$($r.Text)"
Check 'uninstall /data: settings removed' ((-not (Test-Path -LiteralPath "$FakeKey\22.0\CSCoder\BlockFolding")) -and (-not (Test-Path -LiteralPath "$FakeKey\37.0\CSCoder\BlockFolding")))
Check 'uninstall /data: what another tool keeps beside them stays' (Test-Path -LiteralPath "$FakeKey\22.0\CSCoder\OtherTool")
Check 'uninstall /data: the empty key above the settings goes' (-not (Test-Path -LiteralPath "$FakeKey\37.0\CSCoder"))
Check 'uninstall /data: log removed, and the folder once empty' (-not (Test-Path -LiteralPath $FakeDir))
$r = Run-Setup (@('-Action', 'uninstall') + $FakeArgs)
Check 'uninstall with nothing installed: exit 0' ($r.Code -eq 0) "exit $($r.Code)"

# ---------------------------------------------------------------------------
function Stop-Ide($process) {
    # Only the instance started here, and what it started.
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" -ErrorAction SilentlyContinue)
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit(10000) | Out-Null
    }
    foreach ($child in $children) { Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue }
}

if (-not $SkipIde) {
    Write-Output ''
    Write-Output "== 2. Installed package inside each IDE (isolated profile $IdeProfile)"
    $ProfileRoot = "Software\Embarcadero\$IdeProfile"
    $IdeBin = Join-Path $Work 'ide\bin'
    $IdeArgs = @('-RegistryRoot', $ProfileRoot, '-InstallDir', $IdeBin, '-SkipProcessCheck')
    foreach ($version in ($Targets | ForEach-Object { $_ -replace 'x64', '' } | Select-Object -Unique)) {
        $profileKey = "HKCU:\$ProfileRoot\$($Bds[$version])"
        if (-not (Test-Path -LiteralPath "$profileKey\Known IDE Packages")) { throw "IDE profile $IdeProfile has no Delphi $version yet. Run run-probe.ps1 -Version $version once to create it." }
        # Default settings, and nothing of ours left from another run.
        if (Test-Path -LiteralPath "$profileKey\CSCoder\BlockFolding") { Remove-Item -LiteralPath "$profileKey\CSCoder\BlockFolding" -Recurse -Force }
        foreach ($list in 'Known Packages', 'Known Packages x64') {
            if (Test-Path -LiteralPath "$profileKey\$list") {
                (Get-Item -LiteralPath "$profileKey\$list").Property | Where-Object { $_ -match 'BFProbe|BFInstallCheck' } | ForEach-Object { Remove-ItemProperty -LiteralPath "$profileKey\$list" -Name $_ }
            }
        }
    }
    $r = Run-Setup (@('-Action', 'install') + $IdeArgs)
    Check 'install into the test profile: exit 0' ($r.Code -eq 0) "exit $($r.Code)`n$($r.Text)"
    $r.Text -split "`n" | Where-Object { $_ -match '\[' } | ForEach-Object { Write-Output "          $($_.Trim())" }

    foreach ($target in $Targets) {
        $version = $target -replace 'x64', ''
        $ide64 = $target -like '*x64'
        $platform = if ($ide64) { 'Win64' } else { 'Win32' }
        $bits = if ($ide64) { 'x64' } else { 'x86' }
        $label = "D$version $platform"
        Write-Output "-- $label"
        Check-Installed 'profile' $ProfileRoot $IdeBin $version $platform
        $installed = Join-Path $IdeBin "D$version\$platform\BlockFolding.bpl"

        # Where this Delphi is comes from the registry, as the installer itself finds it.
        $installation = ([string](Get-ItemProperty -LiteralPath "HKCU:\Software\Embarcadero\BDS\$($Bds[$version])").RootDir).TrimEnd('\')
        $out = Join-Path $Root "build\install-check\D$version-$bits"
        $session = Join-Path $out ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path $session | Out-Null
        $library = Join-Path $installation $(if ($ide64) { 'lib\win64\release' } else { 'lib\win32\release' })
        Push-Location (Join-Path $Root 'tests\install')
        try {
            & (Join-Path $installation $(if ($ide64) { 'bin\dcc64.exe' } else { 'bin\dcc32.exe' })) '-B' '-Q' "-U$library" "-E$out" "-N0$out" "-LE$out" "-LN$out" 'BFInstallCheck.dpk' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Check package build failed' }
        } finally { Pop-Location }
        $checkBpl = Join-Path $out 'BFInstallCheck.bpl'
        $list = "HKCU:\$ProfileRoot\$($Bds[$version])\" + $(if ($ide64) { 'Known Packages x64' } else { 'Known Packages' })
        $report = Join-Path $session 'report.txt'
        $sample = Join-Path $session 'Sample.pas'
        Copy-Item -LiteralPath (Join-Path $Root 'samples\Sample.pas') -Destination $sample
        New-ItemProperty -LiteralPath $list -Name $checkBpl -Value 'Block Folding install check (test only)' -PropertyType String -Force | Out-Null
        $env:BFCHECK_REPORT = $report
        $env:BFCHECK_SAMPLE = $sample
        $ide = $null
        try {
            $ide = Start-Process -FilePath (Join-Path $installation ($(if ($ide64) { 'bin64' } else { 'bin' }) + '\bds.exe')) -ArgumentList '-r', $IdeProfile, '-ns', '-np' -PassThru
            Remove-Item Env:\BFCHECK_REPORT, Env:\BFCHECK_SAMPLE
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            $done = $false
            while ((Get-Date) -lt $deadline -and -not $ide.HasExited) {
                try { if ((Test-Path -LiteralPath $report) -and (Select-String -LiteralPath $report -Pattern '^DONE' -Quiet -ErrorAction Stop)) { $done = $true; break } } catch { }
                Start-Sleep -Seconds 2
            }
            Check "$label`: the check ran to the end inside the IDE" $done $(if ($ide.HasExited) { 'the IDE closed by itself' } else { 'time limit' })

            # With this Delphi open the installer must refuse, and change nothing.
            $refuseDir = Join-Path $Work "refused-$target\bin"
            $before = @((Get-Item -LiteralPath "$FakeKey\22.0\Known Packages").Property) -join '|'
            $r = Run-Setup @('-Action', 'install', '-RegistryRoot', $Fake, '-InstallDir', $refuseDir)
            Check "$label`: with this Delphi open, install refuses with a message (exit 2)" (($r.Code -eq 2) -and ($r.Text -match 'Delphi is running')) "exit $($r.Code)"
            Check "$label`: refused install copied nothing and registered nothing" ((-not (Test-Path -LiteralPath $refuseDir)) -and ((@((Get-Item -LiteralPath "$FakeKey\22.0\Known Packages").Property) -join '|') -eq $before))
            $r = Run-Setup @('-Action', 'uninstall', '-RegistryRoot', $Fake, '-InstallDir', $refuseDir)
            Check "$label`: with this Delphi open, uninstall refuses too (exit 2)" ($r.Code -eq 2) "exit $($r.Code)"
        } finally {
            Remove-Item Env:\BFCHECK_REPORT, Env:\BFCHECK_SAMPLE -ErrorAction SilentlyContinue
            if ($ide) { Stop-Ide $ide }
            Remove-ItemProperty -LiteralPath $list -Name $checkBpl -ErrorAction SilentlyContinue
        }
        $lines = @(if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Encoding UTF8 })
        $lines | ForEach-Object { Write-Output "          $_" }
        $module = ($lines | Where-Object { $_ -like 'MODULE | *' } | Select-Object -First 1) -replace '^MODULE \| ', ''
        Check "$label`: the IDE loaded the installed file" ($module -eq $installed) $module
        Check "$label`: menu CS.Coder > Block Folding is there" ([bool]($lines -match '^MENU \| CS\.Coder: True \| Block Folding: True \| below CS\.Coder: True'))
        # What the IDE itself keeps folded in the sample (its {$REGION}) is there before and after.
        $before = if (($lines -join "`n") -match '(?m)^BEFORE \| hidden: \[(.*)\]$') { $Matches[1] } else { '?' }
        $fold = if (($lines -join "`n") -match '(?m)^FOLD \| hidden: \[(.*)\] \| cursor line: (\d+)$') { $Matches[1] } else { '?' }
        $cursor = if ($fold -ne '?') { $Matches[2] } else { '?' }
        $open = if (($lines -join "`n") -match '(?m)^OPEN \| hidden: \[(.*)\]$') { $Matches[1] } else { '?' }
        Check "$label`: the block is open before the command" (($before -ne '?') -and ($before -notmatch '\b3[1-8]\b')) $before
        Check "$label`: the menu command folded the if with its else (lines 31..38 hidden, cursor on 30)" ((($fold -split ' ') -contains '31..38') -and ((($fold -split ' ' | Where-Object { $_ -ne '31..38' }) -join ' ') -eq $before) -and ($cursor -eq '30')) "$fold, cursor $cursor"
        Check "$label`: the same command opened it again, and nothing else changed" ($open -eq $before) $open
        Check "$label`: no dialog and no exception" (-not ($lines -match '^(DIALOG|EXCEPTION|EDITOR)'))
    }

    $r = Run-Setup (@('-Action', 'uninstall', '-RemoveData') + $IdeArgs)
    Check 'test profile left clean (uninstall /data): exit 0' ($r.Code -eq 0) "exit $($r.Code)"
    $left = 0
    foreach ($bds in $Bds.Values) { foreach ($list in 'Known Packages', 'Known Packages x64') { $left += (Ours "HKCU:\$ProfileRoot\$bds\$list").Count } }
    Check 'test profile left clean: no registration' ($left -eq 0)
}

Remove-Item -LiteralPath $FakeKey -Recurse -Force
if (-not (Get-ChildItem -LiteralPath 'HKCU:\Software\CSCoderTest' -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath 'HKCU:\Software\CSCoderTest' -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Output "RESULT: $($script:Checks) checks, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
