$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runId='c2_shared_restore_i3_20260913_a'
$runLog=Join-Path $caseRoot "logs\efinity_resource_runs\$runId"
$state=Get-Content -LiteralPath (Join-Path $runLog 'status.json') -Raw | ConvertFrom-Json
$privateRoot=Join-Path $env:TEMP "c1_efinity_resource_c1_ti60_r2_shared96_$runId"
if($state.state -ne 'complete' -or $state.exit_code -ne 0){throw 'Shared EDA run incomplete'}
if(Get-Process -Id $state.process_id -ErrorAction SilentlyContinue){throw 'Shared EDA worker present'}
if(Test-Path -LiteralPath $privateRoot){throw 'Shared private EDA directory remains'}
if(@(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'sim') -Directory -Filter 'c1_r2_c2_restore_*').Count -ne 0){throw 'C2 simulator directory remains'}
$bytes=(Get-ChildItem -LiteralPath $runLog -File | Measure-Object -Property Length -Sum).Sum
$simBytes=(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'logs') -File -Filter 'r2_shared_probe_20260913_*.log' | Measure-Object -Property Length -Sum).Sum
"C1_R2_SHARED_CLOSURE_PASS eda_runs=1 worker_present=0 private_directory_present=0 simulator_directories=0 eda_retained_bytes=$bytes simulation_log_bytes=$simBytes waveform_requested=0"
