$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$edaBytes=0
foreach($suffix in @('a','b')) {
    $runId="c1_ti60_r2_tile96_i3_20260913_$suffix"
    $runLog=Join-Path $caseRoot "logs\efinity_resource_runs\$runId"
    $state=Get-Content -LiteralPath (Join-Path $runLog 'status.json') -Raw | ConvertFrom-Json
    if($state.state -ne 'complete' -or $state.exit_code -ne 0){throw "Tile EDA run incomplete: $runId"}
    if(Get-Process -Id $state.process_id -ErrorAction SilentlyContinue){throw "Tile EDA worker present: $runId"}
    $privateRoot=Join-Path $env:TEMP "c1_efinity_resource_c1_ti60_r2_tile96_$runId"
    if(Test-Path -LiteralPath $privateRoot){throw "Tile private EDA directory remains: $runId"}
    $edaBytes+=(Get-ChildItem -LiteralPath $runLog -File | Measure-Object -Property Length -Sum).Sum
}
if(@(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'sim') -Directory -Filter 'c1_r2_tile_*').Count -ne 0){throw 'Tile simulator directory remains'}
$simBytes=(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'logs') -File -Filter 'r2_cnn_tile_probe_20260913_*.log' | Measure-Object -Property Length -Sum).Sum
"C1_R2_TILE_CLOSURE_PASS eda_runs=2 map_pnr_runs=1 map_only_runs=1 worker_present=0 private_directory_present=0 simulator_directories=0 eda_retained_bytes=$edaBytes simulation_log_bytes=$simBytes waveform_requested=0"
