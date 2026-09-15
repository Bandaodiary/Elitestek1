# One-shot recovery of five explicitly identified interrupted C31 runs.
# Never changes the original status or claims simulation/PNR success.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$tempRoot='C:\Users\30982\AppData\Local\Temp'
$records=@(
    @{group='r2_rgb2_host_xsim_runs';id='c31_rgb2_native_sixframe_20260914_a';pid=36896;leaf='c1_r2_rgb2_host_xsim_c31_rgb2_native_sixframe_20260914_a';root=$simRoot},
    @{group='r2_rgb2_regression_runs';id='c31_rgb2_matrix_20260914_b';pid=25296;leaf='c1_r2_rgb2_regression_c31_rgb2_matrix_20260914_b';root=$simRoot},
    @{group='r2_rgb2_regression_runs';id='c31_rgb2_faults_20260914_a';pid=10068;leaf='c1_r2_rgb2_regression_c31_rgb2_faults_20260914_a';root=$simRoot},
    @{group='r2_rgb2_regression_runs';id='c31_rgb2_negative_20260914_a';pid=36852;leaf='c1_r2_rgb2_regression_c31_rgb2_negative_20260914_a';root=$simRoot},
    @{group='efinity_resource_runs';id='c31_rgb2_host96_pnr_20260914_b';pid=9700;leaf='c1_efinity_resource_c1_ti60_r2_rgb2_host96_c31_rgb2_host96_pnr_20260914_b';root=$tempRoot}
)
$processes=@(Get-CimInstance Win32_Process)
$pids=@($records|ForEach-Object {$_.pid})
if(@($processes|Where-Object {$_.ProcessId -in $pids -or $_.Name -in @('xsim.exe','efx_map.exe','efx_pnr.exe','vvp.exe') -or
    ($_.Name -eq 'python.exe' -and $_.CommandLine -like '*c31_*')}).Count){throw 'Known worker or simulator still live; refusing cleanup'}
$total=0L
foreach($r in $records){
    $target=[IO.Path]::GetFullPath((Join-Path $r.root $r.leaf))
    $parent=[IO.Path]::GetFullPath($r.root).TrimEnd('\')
    if(-not $target.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase) -or
       (Split-Path -Leaf $target) -ne $r.leaf){throw 'Target escaped exact permitted parent'}
    $log=Join-Path $caseRoot ('logs\'+$r.group+'\'+$r.id)
    if(Test-Path -LiteralPath (Join-Path $log 'interruption.json')){throw 'Recovery was already recorded'}
    $status=Get-Content -LiteralPath (Join-Path $log 'status.json') -Raw|ConvertFrom-Json
    if($status.state -ne 'running'){throw 'Unexpected terminal status; audit again'}
    $bytes=0L
    if(Test-Path -LiteralPath $target){
        if($r.group -eq 'efinity_resource_runs'){
            foreach($name in @('c1_ti60_r2_rgb2_host96.hier_util.rpt','c1_ti60_r2_rgb2_host96.place.rpt')){
                $source=Join-Path $target ('out\'+$name)
                if((Get-Item -LiteralPath $source).Length -gt 400000){throw 'Unexpectedly large retained report'}
                Copy-Item -LiteralPath $source -Destination (Join-Path $log ('partial_'+$name))
            }
        }
        $bytes=[long]((Get-ChildItem -LiteralPath $target -Recurse -File|Measure-Object Length -Sum).Sum)
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    $total+=$bytes
    [ordered]@{run_id=$r.id;observed_at=(Get-Date -Format o);original_status_preserved=$true;
        terminal_evidence='worker and all relevant simulator handles absent';worker_pid=$r.pid;
        reason='interrupted; cause not established';private_directory=$target;removed_bytes=$bytes;
        private_directory_present=(Test-Path -LiteralPath $target);pass_claim=$false}|ConvertTo-Json|
        Set-Content -LiteralPath (Join-Path $log 'interruption.json') -Encoding UTF8
    Write-Output ('C31_INTERRUPTED_RUN_CLEAN run='+$r.id+' bytes='+$bytes+' status_preserved=1')
}
Write-Output ('C31_INTERRUPTED_CLEANUP_PASS runs=5 removed_bytes='+$total+' recoverable_by_rebuild=1')
