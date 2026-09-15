# One-shot C33-native -> C34 unit-test handoff. Pins exact process handles/start
# times; never kills or cleans the predecessor. No polling of large logs.
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='c34_after_c33_native_20260914_a')
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid queue RunId'}
$depRun='c33_credit_native_sixframe_20260914_a'
$nextRun='c34_ring_write_axi_20260914_a'
$depFolder=Join-Path $caseRoot "logs\r2_credit_rgb2_host_xsim_runs\$depRun"
$runLog=Join-Path $caseRoot "logs\r2_serial_queue_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
$expected=@(
    @{pid=40356;name='powershell';started='2026-09-14T20:09:26.3228623+08:00'},
    @{pid=42296;name='xsim';started='2026-09-14T20:10:08.5018231+08:00'},
    @{pid=43584;name='xsimk';started='2026-09-14T20:10:09.4948777+08:00'}
)
function Pin-Predecessor{
    $pins=@()
    foreach($e in $expected){
        $p=Get-Process -Id $e.pid -ErrorAction Stop
        if($p.ProcessName -ne $e.name -or $p.StartTime.ToUniversalTime().Ticks -ne ([DateTime]::Parse($e.started)).ToUniversalTime().Ticks){throw 'predecessor PID reused or identity changed'}
        $nativeHandle=$p.Handle
        $pins+=,$p
    }
    return $pins
}
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'queue RunId already exists'}
    if(Test-Path -LiteralPath (Join-Path $caseRoot "logs\r2_ring_write_axi_runs\$nextRun")){throw 'next RunId already exists'}
    $pins=@(Pin-Predecessor);foreach($p in $pins){$p.Dispose()}
    $dep=Get-Content -LiteralPath (Join-Path $depFolder 'status.json') -Raw|ConvertFrom-Json
    if($dep.worker_pid -ne 40356 -or $dep.worker_start -ne $expected[0].started -or $dep.state -ne 'running'){throw 'unexpected predecessor state'}
    $front=Get-CimInstance Win32_Process -Filter 'ProcessId=42296'
    $kernel=Get-CimInstance Win32_Process -Filter 'ProcessId=43584'
    $commandParent=Get-CimInstance Win32_Process -Filter ("ProcessId="+$front.ParentProcessId)
    if($kernel.ParentProcessId -ne 42296 -or $kernel.Name -ne 'xsimk.exe' -or
       $front.Name -ne 'xsim.exe' -or $commandParent.Name -ne 'cmd.exe' -or
       $commandParent.ParentProcessId -ne 40356){throw 'predecessor process ancestry differs'}
    New-Item -ItemType Directory -Path $runLog|Out-Null
    $expected|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $runLog 'pinned_processes.json') -Encoding UTF8
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $launch=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
    if($launch.ReturnValue -ne 0){throw 'WMI queue launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$launch.ProcessId;status_path=$statusPath;next_run=$nextRun}|ConvertTo-Json
    exit 0
}
if(Test-Path -LiteralPath $statusPath){throw 'queue worker already initialized'}
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$runRoot=Join-Path $simRoot "c1_r2_c34_queue_$RunId"
if(Test-Path -LiteralPath $runRoot){throw 'queue private directory exists'}
New-Item -ItemType Directory -Path $runRoot|Out-Null
$env:TEMP=$runRoot;$env:TMP=$runRoot
$state='waiting';$step='predecessor';$runExit=0;$message='waiting for exact C33 handles, terminal status and private cleanup'
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$workerInJob=$null;$depResult=$null;$nextWorker=$null;$pins=@()
function Save-State{
    [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$runExit;message=$message;worker_pid=$PID;
        worker_start=$workerStart;worker_in_windows_job=$workerInJob;predecessor_run=$depRun;predecessor_result=$depResult;
        next_run=$nextRun;next_worker_pid=$nextWorker;queue_process_executes_simulator=$false;
        next_run_completion_claim=$false;private_directory_present=(Test-Path -LiteralPath $runRoot)}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
try{
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C34QueueJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C34QueueJobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'cannot check queue Job isolation'}
    $workerInJob=$jobValue
    if($workerInJob){throw 'queue bound to Windows Job'}
    [Diagnostics.Process]::GetCurrentProcess().PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
    $pins=@(Pin-Predecessor);Save-State
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(@($pins|Where-Object {-not $_.WaitForExit(0)}).Count){
        if($watch.Elapsed.TotalHours -ge 6){throw 'queue wait limit reached; predecessor left untouched'}
        Start-Sleep -Seconds 10
    }
    $dep=Get-Content -LiteralPath (Join-Path $depFolder 'status.json') -Raw|ConvertFrom-Json
    $expectedPrivate=Join-Path $simRoot "c1_r2_credit_rgb2_host_xsim_$depRun"
    if($dep.run_id -ne $depRun -or $dep.worker_start -ne $expected[0].started -or $dep.state -notin @('complete','failed') -or
       $dep.simulator_directory_present -ne $false -or $dep.run_directory -ne $expectedPrivate -or
       (Test-Path -LiteralPath $expectedPrivate) -or (Test-Path -LiteralPath (Join-Path $depFolder 'interruption.json'))){
        throw 'predecessor lacks clean terminal evidence; no successor launched'
    }
    $depResult=$dep.state;$step='launch_next';Save-State
    # The successor enforces the shared heavy-worker mutex, peer-tool check,
    # two logical CPUs and BelowNormal priority before any compilation.
    $out=& (Join-Path $PSScriptRoot 'run_r2_ring_write_contention_detached.ps1') -RunId $nextRun -TimeoutSeconds 600
    if($LASTEXITCODE -ne 0){throw 'successor launch failed'}
    $next=($out -join "`n")|ConvertFrom-Json
    if($next.run_id -ne $nextRun -or -not $next.worker_pid){throw 'unexpected successor identity'}
    $nextWorker=$next.worker_pid;$state='dispatched';$step='next_started';$message='C34 worker launched serially; inspect its own status for actual outcome'
}catch{$state='failed';$step='error';$runExit=1;$message=$_.Exception.Message}
finally{
    foreach($p in $pins){$p.Dispose()}
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne "c1_r2_c34_queue_$RunId"){throw 'unsafe queue cleanup target'}
    try{if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}}
    catch{$state='failed';$step='cleanup';$runExit=1;$message=$_.Exception.Message}
    Save-State
}
exit $runExit
