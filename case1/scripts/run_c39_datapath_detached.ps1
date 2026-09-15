# Bounded C39 Icarus leaf regression, outside the desktop Windows Job.
[CmdletBinding()]
param([switch]$Worker,
      [ValidateSet('fallback','shadow','window','capacity','compile','requant')][string]$Phase='fallback',
      [Parameter(Mandatory=$true)][string]$RunId,
      [ValidateSet('combined','direct','native','onehot')][string]$Variant='combined',
      [ValidateRange(900,3600)][int]$FallbackTimeoutSeconds=900,
      [string]$AfterModelQueue='', [int]$AfterQueuePid=0, [string]$AfterQueueStart='')
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_]+$'){throw 'invalid RunId'}
if($AfterModelQueue){
    if($AfterModelQueue -notmatch '^[A-Za-z0-9_]+$' -or $AfterQueuePid -le 0 -or
       $AfterQueueStart -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{1,7}[+-]\d\d:\d\d$'){
        throw 'explicit predecessor queue identity required'
    }
    [void]([DateTime]$AfterQueueStart)
}elseif($AfterQueuePid -ne 0 -or $AfterQueueStart){throw 'predecessor queue name missing'}
if($Phase -eq 'requant' -and $Variant -ne 'combined'){throw 'requant-only run must not claim another datapath variant'}
$runLog=Join-Path $caseRoot "logs\c39_datapath_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'run already exists; inspect original worker'}
    $shell="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$shell`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -Phase $Phase -RunId $RunId -Variant $Variant -FallbackTimeoutSeconds $FallbackTimeoutSeconds"
    if($AfterModelQueue){$command+=" -AfterModelQueue $AfterModelQueue -AfterQueuePid $AfterQueuePid -AfterQueueStart $AfterQueueStart"}
    $start=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
    if($start.ReturnValue -ne 0){throw "WMI create failed $($start.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=$start.ProcessId;status_path=$statusPath}|ConvertTo-Json
    exit 0
}
New-Item -ItemType Directory -Path $runLog -ErrorAction Stop|Out-Null
$self=Get-Process -Id $PID
$self.ProcessorAffinity=[IntPtr]3
$self.PriorityClass='BelowNormal'
$workerStart=$self.StartTime.ToString('o')
$watch=[Diagnostics.Stopwatch]::StartNew()
$state='waiting';$step='external_tools';$message='waiting for tool/memory budget'
$child=$null;$childPid=$null;$childStart=$null;$childInJob=$null;$workerInJob=$null;$resultCode=$null
$freeMemoryKiB=$null;$external=@()
function Save-State{
    [ordered]@{run_id=$RunId;phase=$Phase;variant=$Variant;state=$state;step=$step;message=$message;exit_code=$resultCode;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;
        child_pid=$childPid;child_start=$childStart;child_in_windows_job=$childInJob;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);external_pids=$external;
        free_memory_kib=$freeMemoryKiB;affinity_mask=3;priority='BelowNormal';
        predecessor_queue=$AfterModelQueue;predecessor_pid=$AfterQueuePid;predecessor_start=$AfterQueueStart;
        waveform_enabled=$false;fallback_wall_timeout_seconds=$FallbackTimeoutSeconds;
        phase_complete_claim=($state -eq 'complete');goal_complete_claim=$false}|
        ConvertTo-Json -Depth 4|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
try{
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class C39LeafJob { [DllImport("kernel32.dll",SetLastError=true)] public static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool r); }'
    $workerInJob=$false
    if(-not [C39LeafJob]::IsProcessInJob($self.Handle,[IntPtr]::Zero,[ref]$workerInJob) -or $workerInJob){throw 'worker is not Job-independent'}
    if($AfterModelQueue){
        $dependencyPath=Join-Path $caseRoot "logs\c39_model_queue_runs\$AfterModelQueue\status.json"
        $step='predecessor_queue';$message='waiting for exact original model queue; no EDA launched';Save-State
        while($true){
            $dep=$null
            for($attempt=0;$attempt -lt 5;$attempt++){
                try{
                    $dep=Get-Content -LiteralPath $dependencyPath -Raw|ConvertFrom-Json -ErrorAction Stop
                    if(-not $dep.run_id){throw 'incomplete predecessor status'}
                    break
                }catch{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 200}
            }
            if($dep.run_id -ne $AfterModelQueue -or $dep.worker_pid -ne $AfterQueuePid -or
               ([DateTime]$dep.worker_start).ToUniversalTime().Ticks -ne ([DateTime]$AfterQueueStart).ToUniversalTime().Ticks){
                throw 'predecessor model queue identity changed'
            }
            $original=Get-Process -Id $AfterQueuePid -ErrorAction SilentlyContinue
            if($original -and $original.StartTime.ToUniversalTime().Ticks -ne ([DateTime]$AfterQueueStart).ToUniversalTime().Ticks){
                $original.Dispose();$original=$null
            }
            try{
                if($dep.state -eq 'failed'){throw 'predecessor model queue failed; keep its original evidence'}
                if($dep.state -eq 'complete'){
                    if($dep.exit_code -ne 0 -or $dep.worker_in_windows_job -ne $false -or @($dep.models).Count -ne 3 -or
                       @($dep.models|Where-Object {$_.state -ne 'complete' -or $_.independent_check_pass -ne $true -or $_.temporary_removed -ne $true}).Count){
                        throw 'predecessor model queue did not verify three clean terminal phases'
                    }
                    if($original){while(-not $original.WaitForExit(5000)){Save-State}}
                    break
                }
                if(-not $original){throw 'predecessor worker disappeared without terminal evidence'}
                # Pin and wait briefly; the next iteration rechecks terminal state.
                [void]$original.WaitForExit(5000);Save-State
            }finally{if($original){$original.Dispose()}}
        }
    }
    while($true){
        $external=@(Get-Process -Name efx_map,efx_pnr,efx_sta,xsim,xsimk,vvp,ivl,xelab,xvlog -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Id)
        $freeMemoryKiB=[long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
        Save-State
        if($external.Count -eq 0 -and $freeMemoryKiB -ge 8388608){break}
        Start-Sleep -Seconds 10
    }
    $python='D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'
    $scriptName=switch($Variant){
        'direct' {'golden\run_c39_direct_datapath_probe.py'}
        'native' {'golden\run_c39_native_datapath_probe.py'}
        'onehot' {'golden\run_c39_onehot_datapath_probe.py'}
        default {'golden\run_c39_datapath_probe.py'}
    }
    $script=Join-Path $caseRoot $scriptName
    $stdout=Join-Path $runLog 'stdout.log'
    $stderr=Join-Path $runLog 'stderr.log'
    $argsText="-X utf8 -B -u `"$script`" --phase $Phase --fallback-timeout $FallbackTimeoutSeconds"
    $child=Start-Process -FilePath $python -ArgumentList $argsText -WorkingDirectory $caseRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $childPid=$child.Id;$childStart=$child.StartTime.ToString('o')
    $child.ProcessorAffinity=[IntPtr]3;$child.PriorityClass='BelowNormal'
    $childInJob=$false
    if(-not [C39LeafJob]::IsProcessInJob($child.Handle,[IntPtr]::Zero,[ref]$childInJob) -or $childInJob){throw 'child is not Job-independent'}
    $state='running';$step=$Phase;$message='original candidate regression running';Save-State
    while(-not $child.WaitForExit(5000)){Save-State}
    $child.Refresh();$resultCode=$child.ExitCode
    $tail=Get-Content -LiteralPath $stdout -Tail 15
    $marker="C39_DATAPATH_PHASE_PASS phase=$Phase actual_candidate_sources=1 temporary_removed=1 waves=0"
    if($resultCode -ne 0 -or -not ($tail -contains $marker)){throw 'candidate regression failed or terminal cleanup marker missing'}
    if($Variant -ne 'combined'){
        $header=Get-Content -LiteralPath $stdout -TotalCount 1
        $expectedHeader=switch($Variant){
            'native' {'C39_NATIVE_VARIANT_BEGIN actual_compact_RGB_DW_construction=1'}
            'onehot' {'C39_ONEHOT_VARIANT_BEGIN actual_shared_decode_unpack=1'}
            'direct' {'C39_DIRECT_VARIANT_BEGIN actual_producer_native_sources=1'}
            default {throw 'unknown explicit candidate header'}
        }
        if($header -ne $expectedHeader){throw 'actual regression source variant header differs'}
    }
    $state='complete';$step='done';$message='phase passed; runner removed private simulation directory';Save-State
}catch{
    $message=$_.Exception.Message
    # Never clean or kill a child merely because observation failed.
    if($child -and -not $child.HasExited){$state='observation_failed_child_live';$step='inspect_pinned_child'}
    else{$state='failed'}
    Save-State
    exit 1
}finally{
    if($child){$child.Dispose()}
    $self.Dispose()
}
