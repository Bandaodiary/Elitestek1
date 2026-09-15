$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$edaBytes=0
foreach($suffix in @('a','b','c')) {
    $runId="c1_ti60_r2_graph96_i3_20260913_$suffix"
    $folder=Join-Path $caseRoot "logs\efinity_resource_runs\$runId"
    $state=Get-Content -LiteralPath (Join-Path $folder 'status.json') -Raw | ConvertFrom-Json
    if($state.state -ne 'complete' -or $state.exit_code -ne 0){throw "EDA not terminal: $runId"}
    if(Get-Process -Id $state.process_id -ErrorAction SilentlyContinue){throw "EDA worker still present: $runId"}
    $privateRoot=Join-Path $env:TEMP "c1_efinity_resource_c1_ti60_r2_graph96_$runId"
    if(Test-Path -LiteralPath $privateRoot){throw "EDA private directory remains: $runId"}
    $edaBytes+=(Get-ChildItem -LiteralPath $folder -File | Measure-Object -Property Length -Sum).Sum
}
if(@(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'sim') -Directory -Filter 'c1_r2_graph_*').Count -ne 0){throw 'Graph simulator directory remains'}
$simBytes=(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'logs') -File -Filter 'r2_graph*20260913*.log' | Measure-Object -Property Length -Sum).Sum
"C1_R2_GRAPH_CLOSURE_PASS eda_runs=3 workers_present=0 private_directories=0 simulator_directories=0 eda_retained_bytes=$edaBytes graph_log_bytes=$simBytes waveform_requested=0"
