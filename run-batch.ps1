# Runs one mode of the probe in the IDEs given as "13", "13x64", "12", "12x64", "11",
# one after the other, appending the console output to build\batch-<mode>.log.
param([Parameter(Mandatory)][string]$Mode, [string[]]$Targets = @('13', '13x64', '12', '12x64', '11'), [int]$TimeoutSeconds = 400)
$log = Join-Path $PSScriptRoot "build\batch-$Mode.log"
foreach ($target in $Targets) {
    $arguments = @{ Version = ($target -replace 'x64', ''); Mode = $Mode; TimeoutSeconds = $TimeoutSeconds }
    if ($target -like '*x64') { $arguments.Ide64 = $true }
    Add-Content -LiteralPath $log -Value "######## D$target $(Get-Date -Format 's')" -Encoding UTF8
    try { $output = & (Join-Path $PSScriptRoot 'run-probe.ps1') @arguments 2>&1 | Select-Object -Last 3 }
    catch { $output = "RESULT: $_" }
    Add-Content -LiteralPath $log -Value ($output | Out-String) -Encoding UTF8
}
Add-Content -LiteralPath $log -Value "BATCH DONE $($Targets -join ' ')" -Encoding UTF8
"BATCH DONE $($Targets -join ' ')"
