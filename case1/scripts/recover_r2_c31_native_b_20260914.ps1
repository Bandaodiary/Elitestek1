# Exact recovery after worker 27580/xsim 14612 were independently found absent.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$run='c31_rgb2_native_sixframe_20260914_b'
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$leaf='c1_r2_rgb2_host_xsim_'+$run
$target=[IO.Path]::GetFullPath((Join-Path $simRoot $leaf))
$log=Join-Path $caseRoot ('logs\r2_rgb2_host_xsim_runs\'+$run)
if(@(Get-CimInstance Win32_Process|Where-Object {$_.ProcessId -in @(27580,14612) -or $_.Name -eq 'xsim.exe'}).Count){throw 'Worker or xsim still present; refusing recovery'}
if(Test-Path -LiteralPath (Join-Path $log 'interruption.json')){throw 'Already recovered'}
if((Get-Content -LiteralPath (Join-Path $log 'status.json') -Raw|ConvertFrom-Json).state -ne 'running'){throw 'Status changed; inspect again'}
if(-not $target.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $target) -ne $leaf){throw 'Unsafe exact target'}
$bytes=0L
if(Test-Path -LiteralPath $target){
    $stdout=Join-Path $target 'xsim.stdout.log'
    if(Test-Path -LiteralPath $stdout){
        if((Get-Item -LiteralPath $stdout).Length -gt 1000000){throw 'Unexpectedly large partial log'}
        Get-Content -LiteralPath $stdout|Where-Object {$_ -cmatch '^C1_R2_RGB2_HOST_SYSTEM_'}|
            Set-Content -LiteralPath (Join-Path $log 'partial_xsim_results.log') -Encoding UTF8
    }
    $bytes=[long]((Get-ChildItem -LiteralPath $target -File -Recurse|Measure-Object Length -Sum).Sum)
    Remove-Item -LiteralPath $target -Recurse -Force
}
[ordered]@{run_id=$run;observed_at=(Get-Date -Format o);original_status_preserved=$true;
    terminal_evidence='worker 27580 and xsim 14612 absent; no other xsim process';
    reason='interrupted; cause not established';worker_original_start='2026-09-14T02:23:22.3942200+08:00';
    private_directory=$target;removed_bytes=$bytes;private_directory_present=(Test-Path -LiteralPath $target);
    pass_claim=$false}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $log 'interruption.json') -Encoding UTF8
'C31_NATIVE_B_INTERRUPTED_CLEAN bytes='+$bytes+' partial_results_preserved=1 original_status_preserved=1 recoverable_by_rebuild=1'
