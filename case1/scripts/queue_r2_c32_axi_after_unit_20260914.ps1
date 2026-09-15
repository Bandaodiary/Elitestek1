# One-shot extension of the already running, exact C31 -> C32 queue.
# This worker only waits on process handles; actual tests run in their own
# budgeted workers. A failed or interrupted writer unit never launches AXI.
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='c32_axi_after_writer_20260914_a')
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$upstreamRun='c32_after_c31_native_20260914_a'
$upstreamPid=3452
$upstreamStart='2026-09-14T17:09:54.4711607+08:00'
$unitRun='c32_writer_matrix_20260914_a'
$nextRun='c32_write_axi_contention_20260914_a'
$upstreamFolder=Join-Path $caseRoot "logs\r2_serial_queue_runs\$upstreamRun"
$unitFolder=Join-Path $caseRoot "logs\r2_cutthrough_writer_runs\$unitRun"
$runLog=Join-Path $caseRoot "logs\r2_serial_queue_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
function Pin-Upstream{
    $p=Get-Process -Id $upstreamPid -ErrorAction Stop
    if($p.ProcessName -ne 'powershell' -or $p.StartTime.ToUniversalTime().Ticks -ne ([DateTime]::Parse($upstreamStart)).ToUniversalTime().Ticks){
        $p.Dispose();throw 'upstream queue PID reused'
    }
    $nativeHandle=$p.Handle
    return $p
}
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'queue RunId exists'}
    if(Test-Path -LiteralPath (Join-Path $caseRoot "logs\r2_cutthrough_write_axi_runs\$nextRun")){throw 'AXI RunId exists'}
    $pin=Pin-Upstream;$pin.Dispose()
    $dep=Get-Content -LiteralPath (Join-Path $upstreamFolder 'status.json') -Raw|ConvertFrom-Json
    if($dep.run_id -ne $upstreamRun -or $dep.worker_pid -ne $upstreamPid -or $dep.worker_start -ne $upstreamStart -or $dep.state -ne 'waiting' -or $dep.next_run -ne $unitRun){throw 'unexpected upstream queue state'}
    New-Item -ItemType Directory -Path $runLog|Out-Null
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $launch=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
    if($launch.ReturnValue -ne 0){throw 'WMI queue launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$launch.ProcessId;status_path=$statusPath;next_run=$nextRun}|ConvertTo-Json
    exit 0
}
if(Test-Path -LiteralPath $statusPath){throw 'queue worker already initialized'}
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$runRoot=Join-Path $simRoot "c1_r2_c32_axi_queue_$RunId"
if(Test-Path -LiteralPath $runRoot){throw 'private queue directory exists'}
New-Item -ItemType Directory -Path $runRoot|Out-Null
$env:TEMP=$runRoot;$env:TMP=$runRoot
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$state='waiting';$step='upstream_queue';$runExit=0;$message='waiting on exact live queue before observing its writer worker'
$workerInJob=$null;$upstreamPin=$null;$unitPin=$null;$unitPid=$null;$unitStart=$null;$nextWorker=$null
function Save-State{
    [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$runExit;message=$message;worker_pid=$PID;
        worker_start=$workerStart;worker_in_windows_job=$workerInJob;upstream_queue=$upstreamRun;
        upstream_pid=$upstreamPid;upstream_start=$upstreamStart;writer_run=$unitRun;writer_pid=$unitPid;writer_start=$unitStart;
        next_run=$nextRun;next_worker_pid=$nextWorker;queue_process_executes_simulator=$false;
        next_run_completion_claim=$false;private_directory_present=(Test-Path -LiteralPath $runRoot)}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
try{
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C32AxiQueueJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C32AxiQueueJobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'cannot check queue Job isolation'}
    $workerInJob=$jobValue;if($workerInJob){throw 'queue bound to Windows Job'}
    [Diagnostics.Process]::GetCurrentProcess().PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
    $upstreamPin=Pin-Upstream;Save-State
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not $upstreamPin.WaitForExit(10000)){
        if($watch.Elapsed.TotalHours -ge 6){throw 'upstream wait limit; predecessor left untouched'}
    }
    $dep=Get-Content -LiteralPath (Join-Path $upstreamFolder 'status.json') -Raw|ConvertFrom-Json
    $upstreamPrivate=Join-Path $simRoot "c1_r2_c32_queue_$upstreamRun"
    if($dep.run_id -ne $upstreamRun -or $dep.worker_pid -ne $upstreamPid -or $dep.worker_start -ne $upstreamStart -or
       $dep.state -ne 'dispatched' -or $dep.exit_code -ne 0 -or $dep.next_run -ne $unitRun -or -not $dep.next_worker_pid -or
       $dep.private_directory_present -ne $false -or (Test-Path -LiteralPath $upstreamPrivate) -or
       (Test-Path -LiteralPath (Join-Path $upstreamFolder 'interruption.json'))){throw 'upstream queue not cleanly dispatched; no AXI launch'}
    $unitPid=[int]$dep.next_worker_pid
    $unitPin=Get-Process -Id $unitPid -ErrorAction SilentlyContinue
    if($unitPin){
        if($unitPin.ProcessName -ne 'powershell'){throw 'writer worker PID reused'}
        $unitStart=$unitPin.StartTime.ToString('o');$unitHandle=$unitPin.Handle
    }
    # The freshly launched worker may need a few seconds to create status.
    # Partial tiny status writes are retried; this is not a simulator restart.
    $unitState=$null
    for($attempt=0;$attempt -lt 60 -and $null -eq $unitState;$attempt++){
        try{$unitState=Get-Content -LiteralPath (Join-Path $unitFolder 'status.json') -Raw|ConvertFrom-Json}catch{Start-Sleep -Seconds 1}
    }
    if($null -eq $unitState -or $unitState.run_id -ne $unitRun -or $unitState.worker_pid -ne $unitPid -or -not $unitState.worker_start){throw 'writer status identity missing'}
    if($unitPin){
        if(([DateTime]::Parse($unitState.worker_start)).ToUniversalTime().Ticks -ne ([DateTime]::Parse($unitStart)).ToUniversalTime().Ticks){throw 'writer status/process identity differs'}
    }else{
        # An already exited worker must provide a clean terminal record; a
        # stale running status without a handle is never a valid predecessor.
        if($unitState.state -notin @('complete','failed')){throw 'writer handle missing without terminal evidence'}
        $unitStart=$unitState.worker_start
    }
    if(([DateTime]::Parse($unitStart)).ToUniversalTime().Ticks -le ([DateTime]::Parse($upstreamStart)).ToUniversalTime().Ticks){throw 'writer predates its launch queue'}
    $step='writer_worker';$message='waiting on observed writer identity; a failure will stop this chain';Save-State
    if($unitPin){
        while(-not $unitPin.WaitForExit(10000)){
            if($watch.Elapsed.TotalHours -ge 6){throw 'writer wait limit; writer left untouched'}
        }
    }
    $unitState=Get-Content -LiteralPath (Join-Path $unitFolder 'status.json') -Raw|ConvertFrom-Json
    $unitPrivate=Join-Path $simRoot "c1_r2_cutthrough_writer_$unitRun"
    if($unitState.run_id -ne $unitRun -or $unitState.worker_pid -ne $unitPid -or $unitState.worker_start -ne $unitStart -or
       $unitState.state -ne 'complete' -or $unitState.exit_code -ne 0 -or $unitState.worker_in_windows_job -ne $false -or
       $unitState.run_directory -ne $unitPrivate -or $unitState.simulator_directory_present -ne $false -or
       (Test-Path -LiteralPath $unitPrivate) -or (Test-Path -LiteralPath (Join-Path $unitFolder 'interruption.json'))){throw 'writer unit failed/interrupted/not cleaned; AXI diagnostic not launched'}
    $step='launch_axi';Save-State
    # This successor independently rechecks the full unit evidence and then
    # enforces Job isolation, no peer FPGA tools and the shared heavy budget.
    $out=& (Join-Path $PSScriptRoot 'run_r2_cutthrough_write_contention_detached.ps1') -RunId $nextRun -WriterUnitRun $unitRun -TimeoutSeconds 900
    if($LASTEXITCODE -ne 0){throw 'AXI successor launch failed'}
    $next=($out -join "`n")|ConvertFrom-Json
    if($next.run_id -ne $nextRun -or -not $next.worker_pid){throw 'unexpected AXI successor identity'}
    $nextWorker=$next.worker_pid;$state='dispatched';$step='axi_started';$message='AXI diagnostic worker launched; its own result remains to be checked'
}catch{$state='failed';$step='error';$runExit=1;$message=$_.Exception.Message}
finally{
    if($upstreamPin){$upstreamPin.Dispose()};if($unitPin){$unitPin.Dispose()}
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne "c1_r2_c32_axi_queue_$RunId"){throw 'unsafe queue cleanup target'}
    try{if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}}
    catch{$state='failed';$step='cleanup';$runExit=1;$message=$_.Exception.Message}
    Save-State
}
exit $runExit
