# Read-only closure; does not delete or modify unrelated simulation artifacts.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$retainedBytes=0L
foreach($variant in @('a','b','c')) {
    $runId="c1_ti60_r2_rgb96_i3_20260913_$variant"
    $runLog=Join-Path $caseRoot "logs\efinity_resource_runs\$runId"
    $state=Get-Content -LiteralPath (Join-Path $runLog 'status.json') -Raw | ConvertFrom-Json
    $privateRoot=Join-Path $env:TEMP "c1_efinity_resource_c1_ti60_r2_rgb96_$runId"
    if($state.state -ne 'complete' -or $state.exit_code -ne 0){throw "$runId not complete"}
    if(Get-Process -Id $state.process_id -ErrorAction SilentlyContinue){throw "$runId worker present"}
    if(Test-Path -LiteralPath $privateRoot){throw "$runId private directory remains"}
    $bytes=(Get-ChildItem -LiteralPath $runLog -File | Measure-Object -Property Length -Sum).Sum
    $retainedBytes+=$bytes
    "C1_R2_RGB_CLOSURE_RUN_PASS run=$runId worker_present=0 private_directory_present=0 retained_bytes=$bytes"
}
if(@(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'sim') -Directory -Filter 'c1_r2_rgb_*').Count -ne 0){throw 'RGB simulator directory remains'}
$simBytes=(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'logs') -File -Filter 'r2_rgb_row_probe_20260913_*.log' | Measure-Object -Property Length -Sum).Sum
"C1_R2_RGB_CLOSURE_PASS eda_runs=3 eda_retained_bytes=$retainedBytes simulation_log_bytes=$simBytes simulator_directories=0 waveform_requested=0"
