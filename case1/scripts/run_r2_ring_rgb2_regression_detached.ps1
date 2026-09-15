# C34 independent host tests; real ring unit evidence required before execution.
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='',
      [string]$WriterRun='c34_ring_write_axi_20260914_a',
      [ValidateRange(1,3)][int]$FrameDivisor=2,
      [ValidateSet('smoke','paired','matrix','variant','negative','faults')][string]$TestKind='smoke',
      [ValidateRange(1,7200)][int]$TimeoutSeconds=1800)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -eq ''){$RunId=[guid]::NewGuid().ToString('N')}
if($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $WriterRun -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runLog=Join-Path $caseRoot "logs\r2_ring_rgb2_regression_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'RunId exists'}
    $priorPath=Join-Path $caseRoot "logs\r2_ring_write_axi_runs\$WriterRun\status.json"
    if(-not (Test-Path -LiteralPath $priorPath)){throw 'C34 actual writer test not yet available'}
    $prior=Get-Content -LiteralPath $priorPath -Raw|ConvertFrom-Json
    if($prior.state -ne 'complete' -or $prior.exit_code -ne 0){throw 'C34 actual writer test not complete'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -WriterRun $WriterRun -TestKind $TestKind -FrameDivisor $FrameDivisor -TimeoutSeconds $TimeoutSeconds"
    try{
        $launch=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
        if($launch.ReturnValue -ne 0){throw 'WMI launch failed'}
        $workerPid=[int]$launch.ProcessId
    }catch{$workerPid=[int](& (Join-Path $PSScriptRoot 'start_detached_process.ps1') -CommandLine $command -CurrentDirectory $caseRoot)}
    [ordered]@{run_id=$RunId;worker_pid=$workerPid;status_path=$statusPath}|ConvertTo-Json
    exit 0
}
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$runRoot=Join-Path $simRoot "c1_r2_ring_rgb2_regression_$RunId"
if((Test-Path -LiteralPath $runRoot) -or (Test-Path -LiteralPath $runLog)){throw 'private/run directory exists'}
New-Item -ItemType Directory -Path $runRoot,$runLog|Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew()
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$state='running';$step='prepare';$runExit=0;$message='C34 detached host regression'
$workerInJob=$null;$workerBudget=$null;$budgetLease=$null;$budgetOwned=$false;$safeCleanup=$true
function Save-State{
    [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$runExit;message=$message;
        test_kind=$TestKind;writer_run=$WriterRun;frame_divisor=$FrameDivisor;aw_wait_w=2;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;workload_budget=$workerBudget;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);run_directory=$runRoot;
        simulator_directory_present=(Test-Path -LiteralPath $runRoot);source_pixels_per_word=2;actual_vs_de=$true}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
function Invoke-Probe([string[]]$Arguments,[string]$Stem,[int]$Seconds){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
    $info.Arguments=(@($Arguments|ForEach-Object {if($_.Contains('"')){throw 'unexpected quote'};'"'+$_+'"'})) -join ' '
    $info.WorkingDirectory=$runRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{
        if(-not $process.Start()){throw 'could not start C34 probe'}
        $handle=$process.Handle
        $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
        $timedOut=-not $process.WaitForExit($Seconds*1000)
        if($timedOut){
            & taskkill.exe /PID $process.Id /T /F|Out-Null
            if(-not $process.WaitForExit(30000)){$script:safeCleanup=$false;throw 'probe remains alive; private directory retained'}
        }
        $process.WaitForExit();$out=$outTask.GetAwaiter().GetResult();$err=$errTask.GetAwaiter().GetResult()
        $errName=if($Stem -eq 'result'){'stderr.log'}else{"$Stem.stderr.log"}
        [IO.File]::WriteAllText((Join-Path $runLog "$Stem.log"),$out,(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $runLog $errName),$err,(New-Object Text.UTF8Encoding($false)))
        if($timedOut){throw 'C34 probe timeout; partial logs retained'}
        if($null -eq $process.ExitCode -or $process.ExitCode -ne 0){throw "C34 $Stem failed exit=$($process.ExitCode)"}
        return $out
    }finally{$process.Dispose()}
}
try{
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C34HostJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C34HostJobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'cannot check Job isolation'}
    $workerInJob=$jobValue;if($workerInJob){throw 'worker bound to Windows Job'}
    . (Join-Path $PSScriptRoot 'set_fpga_worker_budget.ps1')
    $env:TEMP=Join-Path $runRoot 'tmp';$env:TMP=$env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP|Out-Null
    $step='writer_gate';Save-State
    $out=Invoke-Probe @('-B','-u',(Join-Path $caseRoot 'golden\check_r2_ring_write_evidence.py'),'--run',$WriterRun) 'writer_gate' 60
    if($out -notmatch 'C34_RING_EVIDENCE_PASS '){throw 'C34 writer evidence incomplete'}
    $step='source_gate';Save-State
    $out=Invoke-Probe @('-B','-u',(Join-Path $caseRoot 'golden\check_r2_ring_host_evidence.py')) 'source_gate' 60
    if($out -notmatch 'C34_HOST_SOURCE_PASS '){throw 'C34 source evidence incomplete'}
    $scriptName=if($TestKind -eq 'faults'){'run_r2_ring_rgb2_host_fault_probe.py'}else{'run_r2_ring_rgb2_host_probe.py'}
    $arguments=@('-B','-u',(Join-Path $caseRoot "golden\$scriptName"),'--temporary-parent',$runRoot,
        '--frame-divisor',"$FrameDivisor",'--aw-wait-w','2')
    if($TestKind -eq 'smoke'){$arguments+=@('--shapes','8x8','--stalls','1','--nn-target','2')}
    if($TestKind -eq 'paired'){$arguments+=@('--shapes','32x32','--stalls','1','--nn-target','2','--paired')}
    if($TestKind -eq 'variant'){$arguments+=@('--profile','drop_res1')}
    if($TestKind -eq 'negative'){$arguments+=@('--negative-only')}
    $step='regression';Save-State
    $out=Invoke-Probe $arguments 'result' $TimeoutSeconds
    $prefix=if($TestKind -eq 'faults'){'C1_R2_RING_RGB2_HOST_FAULT_'}else{'C1_R2_RING_RGB2_HOST_SYSTEM_'}
    $marker=if($TestKind -eq 'negative'){'NEGATIVE_PASS '}else{'PASS '}
    $expected=if($TestKind -in @('smoke','paired')){1}elseif($TestKind -in @('faults','negative')){8}else{4}
    if([regex]::Matches($out,'(?m)^'+$prefix+$marker).Count -ne $expected -or
       [regex]::Matches($out,'(?m)^'+$prefix+'CLEAN temporary_vectors_and_simulator_removed=1').Count -ne 1 -or
       $out -cmatch 'FATAL|ERROR:|Traceback|RuntimeError'){throw 'C34 host coverage incomplete'}
    $state='complete';$step='done';$message='C34 host regression complete; independent data gate still required'
}catch{$state='failed';$step='error';$runExit=1;$message=$_.Exception.Message}
finally{
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
       (Split-Path -Leaf $resolved) -ne "c1_r2_ring_rgb2_regression_$RunId"){throw 'unsafe private cleanup target'}
    try{if($safeCleanup -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}}
    catch{$state='failed';$step='cleanup';$runExit=1;$message=$_.Exception.Message}
    Save-State
    if($budgetLease){if($budgetOwned){$budgetLease.ReleaseMutex()};$budgetLease.Dispose()}
}
exit $runExit
