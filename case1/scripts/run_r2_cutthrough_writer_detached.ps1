# C32 isolated unit regression. Never launches Vivado or changes C31 sources.
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='', [ValidateRange(1,3600)][int]$TimeoutSeconds=600)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -eq ''){$RunId=[guid]::NewGuid().ToString('N')}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runLog=Join-Path $caseRoot "logs\r2_cutthrough_writer_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'RunId exists'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -TimeoutSeconds $TimeoutSeconds"
    try{
        $launch=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
        if($launch.ReturnValue -ne 0){throw 'WMI launch failed'}
        $workerPid=[int]$launch.ProcessId
    }catch{$workerPid=[int](& (Join-Path $PSScriptRoot 'start_detached_process.ps1') -CommandLine $command -CurrentDirectory $caseRoot)}
    [ordered]@{run_id=$RunId;worker_pid=$workerPid;status_path=$statusPath}|ConvertTo-Json
    exit 0
}
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$runRoot=Join-Path $simRoot "c1_r2_cutthrough_writer_$RunId"
if((Test-Path -LiteralPath $runRoot) -or (Test-Path -LiteralPath $runLog)){throw 'private directory exists'}
New-Item -ItemType Directory -Path $runRoot,$runLog|Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew()
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$state='running';$step='prepare';$runExit=0;$message='C32 independent writer regression'
$workerInJob=$null;$workerBudget=$null;$budgetLease=$null;$budgetOwned=$false
function Save-State{
    [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$runExit;message=$message;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;workload_budget=$workerBudget;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);run_directory=$runRoot;
        simulator_directory_present=(Test-Path -LiteralPath $runRoot);actual_AXI=$false;whole_CNN_fps_claim=$false}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
try{
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C32JobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C32JobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'cannot check Job isolation'}
    $workerInJob=$jobValue
    if($workerInJob){throw 'worker bound to Windows Job'}
    . (Join-Path $PSScriptRoot 'set_fpga_worker_budget.ps1')
    $env:TEMP=Join-Path $runRoot 'tmp';$env:TMP=$env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP|Out-Null
    $step='regression';Save-State
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
    $info.Arguments='-B -u "'+(Join-Path $caseRoot 'golden\run_r2_cutthrough_writer_probe.py')+'" --temporary-parent "'+$runRoot+'"'
    $info.WorkingDirectory=$runRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$info
    try{
        if(-not $p.Start()){throw 'could not start C32 runner'}
        $stdoutTask=$p.StandardOutput.ReadToEndAsync();$stderrTask=$p.StandardError.ReadToEndAsync();$handle=$p.Handle
        if(-not $p.WaitForExit($TimeoutSeconds*1000)){
            & taskkill.exe /PID $p.Id /T /F|Out-Null
            throw 'C32 regression timeout'
        }
        $p.WaitForExit();$out=$stdoutTask.GetAwaiter().GetResult();$err=$stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $runLog 'result.log'),$out,(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $runLog 'stderr.log'),$err,(New-Object Text.UTF8Encoding($false)))
        if($null -eq $p.ExitCode -or $p.ExitCode -ne 0){throw "C32 regression failed exit=$($p.ExitCode)"}
    }finally{$p.Dispose()}
    if([regex]::Matches($out,'(?m)^C32_WRITER_RTL_PASS ').Count -ne 22 -or
       [regex]::Matches($out,'(?m)^C32_WRITER_CLEAN temporary_vectors_and_simulator_removed=1').Count -ne 1 -or
       ($out+$err) -cmatch 'FATAL|ERROR:|Traceback|RuntimeError'){throw 'C32 regression evidence incomplete'}
    $state='complete';$step='done';$message='C32 isolated writer passed; no whole-host claim'
}catch{$state='failed';$step='error';$runExit=1;$message=$_.Exception.Message}
finally{
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne "c1_r2_cutthrough_writer_$RunId"){throw 'unsafe private cleanup target'}
    try{if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}}
    catch{$state='failed';$step='cleanup';$runExit=1;$message=$_.Exception.Message}
    Save-State
    if($budgetLease){if($budgetOwned){$budgetLease.ReleaseMutex()};$budgetLease.Dispose()}
}
exit $runExit
