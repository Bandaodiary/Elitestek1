# C31 Icarus regressions survive a desktop turn interruption. No waves.
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='', [ValidateRange(1,3)][int]$FrameDivisor=2,
      [ValidateSet('smoke','matrix','variant','negative','faults','startup')][string]$TestKind='matrix',
      [int]$TimeoutSeconds=1800)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -eq ''){$RunId=[guid]::NewGuid().ToString('N')}
if($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $TimeoutSeconds -lt 1){throw 'invalid run/configuration'}
$runLog=Join-Path $caseRoot "logs\r2_rgb2_regression_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'RunId already exists'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId -TestKind $TestKind -FrameDivisor $FrameDivisor -TimeoutSeconds $TimeoutSeconds"
    try {
        $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
        if($r.ReturnValue -ne 0){throw 'WMI launch failed'}
        $workerPid=[int]$r.ProcessId
    } catch {
        $workerPid=[int](& (Join-Path $PSScriptRoot 'start_detached_process.ps1') -CommandLine $command -CurrentDirectory $caseRoot)
    }
    [ordered]@{run_id=$RunId;worker_pid=$workerPid;status_path=$statusPath}|ConvertTo-Json
    exit 0
}
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$runRoot=Join-Path $simRoot "c1_r2_rgb2_regression_$RunId"
if((Test-Path -LiteralPath $runRoot) -or (Test-Path -LiteralPath $runLog)){throw 'private/run directory exists'}
New-Item -ItemType Directory -Path $runRoot,$runLog|Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew()
$state='running';$step='prepare';$runExit=0;$message='C31 detached regression';$workerInJob=$null
$workerBudget=$null;$budgetLease=$null;$budgetOwned=$false
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
function Save-State {
    [ordered]@{run_id=$RunId;test_kind=$TestKind;state=$state;step=$step;exit_code=$runExit;message=$message;
        frame_divisor=$FrameDivisor;source_pixels_per_word=2;actual_vs_de=$true;worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;workload_budget=$workerBudget;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);run_directory=$runRoot;
        simulator_directory_present=(Test-Path -LiteralPath $runRoot)}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C31RegressionJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C31RegressionJobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'Cannot verify Windows Job isolation'}
    $workerInJob=$jobValue
    if($workerInJob){throw 'Worker is in a Windows Job; refusing to launch regression'}
    . (Join-Path $PSScriptRoot 'set_fpga_worker_budget.ps1')
    $env:TEMP=Join-Path $runRoot 'tmp';$env:TMP=$env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP|Out-Null
    $scriptName=if($TestKind -eq 'startup'){'run_r2_rgb2_startup_probe.py'}elseif($TestKind -eq 'faults'){'run_r2_rgb2_host_fault_probe.py'}else{'run_r2_rgb2_host_probe.py'}
    $arguments=@('-B','-u',(Join-Path $caseRoot "golden\$scriptName"),'--temporary-parent',$runRoot)
    if($TestKind -ne 'startup'){$arguments+=@('--frame-divisor',"$FrameDivisor")}
    if($TestKind -eq 'smoke'){$arguments+=@('--shapes','8x8','--stalls','1','--nn-target','2')}
    if($TestKind -eq 'variant'){$arguments+=@('--profile','drop_res1')}
    if($TestKind -eq 'negative'){$arguments+=@('--negative-only')}
    $quoted=@($arguments|ForEach-Object {if($_.Contains('"')){throw 'unexpected quote'};'"'+$_+'"'})
    $step='regression';Save-State
    # Own the readers, rather than Start-Process's background file writers.
    # These bounded, no-wave regressions emit only small text logs; explicitly
    # awaiting both tasks makes end-of-log/cleanup validation deterministic.
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
    $info.Arguments=$quoted -join ' '
    $info.WorkingDirectory=$runRoot
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process
    $p.StartInfo=$info
    try {
        if(-not $p.Start()){throw 'could not start regression'}
        $stdoutTask=$p.StandardOutput.ReadToEndAsync()
        $stderrTask=$p.StandardError.ReadToEndAsync()
        $handle=$p.Handle
        if(-not $p.WaitForExit($TimeoutSeconds*1000)){
            & taskkill.exe /PID $p.Id /T /F | Out-Null
            throw 'regression exceeded execution limit'
        }
        $p.WaitForExit()
        $stdoutText=$stdoutTask.GetAwaiter().GetResult()
        $stderrText=$stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $runLog 'result.log'),$stdoutText,(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $runLog 'stderr.log'),$stderrText,(New-Object Text.UTF8Encoding($false)))
        if($null -eq $p.ExitCode -or $p.ExitCode -ne 0){throw "regression failed (exit=$($p.ExitCode))"}
    } finally {$p.Dispose()}
    $prefix=if($TestKind -eq 'faults'){'C1_R2_RGB2_HOST_FAULT_'}else{'C1_R2_RGB2_HOST_SYSTEM_'}
    $expected=if($TestKind -eq 'startup'){2}elseif($TestKind -eq 'smoke'){1}elseif($TestKind -in @('faults','negative')){8}else{4}
    # Match only the uppercase metadata marker. Case-insensitive '_VECTORS'
    # also matches 'temporary_vectors' in CLEAN, deleting our own evidence.
    $lines=@(Get-Content -LiteralPath (Join-Path $runLog 'result.log')|Where-Object {$_ -cnotmatch '^C1_R2_RGB2_HOST_SYSTEM_VECTORS '})
    $passMarker=if($TestKind -eq 'negative'){'NEGATIVE_PASS '}else{'PASS '}
    $passCount=@($lines|Where-Object {$_ -match ('^'+$prefix+$passMarker)}).Count
    $cleanCount=@($lines|Where-Object {$_ -eq ($prefix+'CLEAN temporary_vectors_and_simulator_removed=1')}).Count
    if($TestKind -eq 'startup'){
        $cleanCount=@($lines|Where-Object {$_ -eq 'C31_STARTUP_CLEAN temporary_vectors_and_simulator_removed=1'}).Count
        if(@($lines|Where-Object {$_ -match '^C31_STARTUP_NEGATIVE_PASS '}).Count -ne 1 -or @($lines|Where-Object {$_ -match '^C31_STARTUP_POSITIVE_PASS '}).Count -ne 2){throw 'startup clock/negative coverage incomplete'}
    }
    $hasError=($lines -join "`n") -cmatch 'FATAL|ERROR:|Traceback|RuntimeError'
    if($passCount -ne $expected -or $cleanCount -ne 1 -or $hasError){throw "regression coverage: pass=$passCount expected=$expected clean=$cleanCount error=$hasError"}
    $state='complete';$step='done';$message='C31 regression passed'
} catch {$state='failed';$step='error';$runExit=1;$message=$_.Exception.Message}
finally {
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne "c1_r2_rgb2_regression_$RunId"){throw 'unsafe cleanup target'}
    try {
        if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
    } catch {$state='failed';$step='cleanup';$runExit=1;$message='Private cleanup failed: '+$_.Exception.Message}
    Save-State
    if($budgetLease){if($budgetOwned){$budgetLease.ReleaseMutex()};$budgetLease.Dispose()}
}
exit $runExit
