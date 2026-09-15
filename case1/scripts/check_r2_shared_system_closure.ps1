# Read-only closure checks, then a small generated JSON report. No deletion.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runFolders=@()
$private=@()
foreach($id in @('c10_xsim_native_20260913_a','c10_xsim_native_20260913_b','c10_xsim_renamed_smoke_20260913_c')) {
    $folder=Join-Path $caseRoot "logs\r2_shared_xsim_runs\$id"
    $s=Get-Content -LiteralPath (Join-Path $folder 'status.json') -Raw | ConvertFrom-Json
    if($s.state -ne 'complete' -or $s.exit_code -ne 0 -or $s.worker_in_windows_job -ne $false -or $s.simulator_directory_present){throw "Unclosed xsim $id"}
    if(Test-Path -LiteralPath $s.run_directory){throw "Private xsim directory exists: $id"}
    $owned=Get-CimInstance Win32_Process -Filter "ProcessId = $($s.worker_pid)" -ErrorAction SilentlyContinue
    if($owned -and $owned.CommandLine -like "* -RunId $id *"){throw "Live owned worker: $id"}
    $runFolders+=$folder;$private+=$s.run_directory
}
$eda=@(
    @('c1_ti60_r2_shared96','c1_ti60_r2_shared96_i3_20260913_b'),
    @('c1_ti60_r2_shared_system96','c10_shared_system96_i3_20260913_c'),
    @('c1_ti60_r2_shared96','c2_shared_restore_i3_20260913_a')
)
foreach($item in $eda) {
    $design=$item[0];$id=$item[1];$folder=Join-Path $caseRoot "logs\efinity_resource_runs\$id"
    $s=Get-Content -LiteralPath (Join-Path $folder 'status.json') -Raw | ConvertFrom-Json
    if($s.state -ne 'complete' -or $s.exit_code -ne 0){throw "Unclosed EDA $id"}
    $temp=Join-Path $env:TEMP "c1_efinity_resource_${design}_$id"
    if(Test-Path -LiteralPath $temp){throw "Private EDA directory exists: $id"}
    $owned=Get-CimInstance Win32_Process -Filter "ProcessId = $($s.process_id)" -ErrorAction SilentlyContinue
    if($owned -and $owned.CommandLine -like "* -RunId $id *"){throw "Live owned EDA: $id"}
    $runFolders+=$folder;$private+=$temp
}
# The mixed historical directory is deliberately NOT interpreted as a success.
$mixed=Join-Path $caseRoot 'logs\efinity_resource_runs\c1_ti60_r2_shared96_i3_20260913_a'
if(-not (Test-Path -LiteralPath (Join-Path $mixed 'NAME_COLLISION_NOTICE.md'))){throw 'Missing collision disclosure'}
$mixedTemp=Join-Path $env:TEMP 'c1_efinity_resource_c1_ti60_r2_shared96_c1_ti60_r2_shared96_i3_20260913_a'
if(Test-Path -LiteralPath $mixedTemp){throw 'Failed-run private directory remains'}
$private+=$mixedTemp
$residue=@(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'sim') -Directory | Where-Object { $_.Name -like 'c1_r2_shared_*' -or $_.Name -like 'c1_r2_c2_restore_*' -or $_.Name -like 'c1_r2_driver_*' })
if($residue.Count){throw 'C10/C2 recovery disposable simulator directories remain'}
$files=@($runFolders | ForEach-Object { Get-ChildItem -LiteralPath $_ -File })
$files+=@(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'logs') -File | Where-Object { $_.Name -match '^r2_(c10_|c2_restored_|shared_(apb|smoke|matrix|no_background))' -and $_.Name -notmatch '^r2_c10_(cleanup|closure)' })
$bytes=($files | Measure-Object -Property Length -Sum).Sum
$report=[ordered]@{
    state='complete';simulator_runs_checked=3;eda_success_runs_checked=3;mixed_failed_run_disclosed=1
    private_directories_remaining=0;checked_private_paths=$private;waveforms_requested=$false
    retained_text_files=$files.Count;retained_text_bytes=$bytes
    scope='C10 tests/EDA and C2 recovery only; excludes pre-existing mixed C2 archive and this JSON; no unrelated files removed'
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $caseRoot 'logs\r2_c10_cleanup_20260913.json') -Encoding UTF8
"C1_R2_C10_CLOSURE_PASS private_remaining=0 detached_xsim_runs=3 eda_success_runs=3 retained_text_files=$($files.Count) retained_text_bytes=$bytes"
