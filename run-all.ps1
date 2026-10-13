# Runs the probe in every installed IDE, one after the other, and keeps each
# console output next to the reports.
param([ValidateSet('probe','layout','fold')][string]$Mode = 'probe')
$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'build\run-all.log'
Set-Content -LiteralPath $log -Value ("run-all " + (Get-Date -Format 's')) -Encoding UTF8
foreach ($target in @(@('13', $false), @('13', $true), @('12', $false), @('12', $true), @('11', $false))) {
    $name = "D$($target[0]) " + $(if ($target[1]) { 'x64' } else { 'x86' })
    Add-Content -LiteralPath $log -Value "===== $name" -Encoding UTF8
    try {
        if ($target[1]) { $output = & (Join-Path $PSScriptRoot 'run-probe.ps1') -Version $target[0] -Ide64 -Mode $Mode -TimeoutSeconds 300 2>&1 }
        else { $output = & (Join-Path $PSScriptRoot 'run-probe.ps1') -Version $target[0] -Mode $Mode -TimeoutSeconds 300 2>&1 }
        Add-Content -LiteralPath $log -Value ($output | Out-String) -Encoding UTF8
    } catch {
        Add-Content -LiteralPath $log -Value "FAILED: $_" -Encoding UTF8
    }
}
Add-Content -LiteralPath $log -Value 'ALL DONE' -Encoding UTF8
Get-Content -LiteralPath $log -Encoding UTF8
