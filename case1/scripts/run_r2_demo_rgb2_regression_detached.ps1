# C30 Icarus regressions survive a desktop turn interruption. No waves.
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='',[switch]$OverlapResize=$true,
      [ValidateSet('matrix','odd','vendor','native512')][string]$TestKind='matrix',
      [int]$TimeoutSeconds=1800)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -eq ''){$RunId=[guid]::NewGuid().ToString('N')}
if($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $TimeoutSeconds -lt 1){throw 'invalid run/configuration'}
$runLog=Join-Path $caseRoot "logs\r2_demo_rgb2_regression_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'RunId already exists'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $overlapArg=if($OverlapResize){' -OverlapResize'}else{''}
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId -TestKind $TestKind -TimeoutSeconds $TimeoutSeconds$overlapArg"
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
$runRoot=Join-Path $simRoot "c1_r2_demo_rgb2_regression_$RunId"
if((Test-Path -LiteralPath $runRoot) -or (Test-Path -LiteralPath $runLog)){throw 'private/run directory exists'}
New-Item -ItemType Directory -Path $runRoot,$runLog|Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew()
$state='running';$step='prepare';$runExit=0;$message='C30 detached regression';$workerInJob=$null
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
function Save-State {
    [ordered]@{run_id=$RunId;test_kind=$TestKind;state=$state;step=$step;exit_code=$runExit;message=$message;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;
        overlap_resize=[bool]$OverlapResize;actual_vendor_rtl=($TestKind -eq 'vendor');
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);run_directory=$runRoot;
        simulator_directory_present=(Test-Path -LiteralPath $runRoot)}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C30RasterRegressionJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C30RasterRegressionJobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'Cannot verify Windows Job isolation'}
    $workerInJob=$jobValue
    if($workerInJob){throw 'Worker is in a Windows Job; refusing to launch regression'}
    $env:TEMP=Join-Path $runRoot 'tmp';$env:TMP=$env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP|Out-Null
    $arguments=@('-B','-u',(Join-Path $caseRoot 'golden\run_r2_demo_rgb2_capture_probe.py'),'--temporary-parent',$runRoot)
    if($OverlapResize){$arguments+=@('--overlap-resize')}
    if($TestKind -eq 'odd'){$arguments+=@('--odd-roi')}
    if($TestKind -eq 'vendor'){$arguments+=@('--vendor')}
    if($TestKind -like 'native*'){$arguments+=@('--native','--stalls','0','--fifo',$TestKind.Substring(6))}
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
    $prefix='C1_R2_DEMO_RGB2_CAPTURE_'
    $expected=if($TestKind -like 'native*'){1}else{2}
    $lines=@(Get-Content -LiteralPath (Join-Path $runLog 'result.log')|Where-Object {$_ -cnotmatch '^C1_R2_DEMO_RGB2_VECTORS '})
    $passCount=@($lines|Where-Object {$_ -cmatch ('^'+$prefix+'PASS ')}).Count
    $cleanCount=@($lines|Where-Object {$_ -eq ($prefix+'CLEAN temporary_vectors_and_simulator_removed=1')}).Count
    $selection='C30_RESIZE_SELECTION overlap='+[int][bool]$OverlapResize
    if(@($lines|Where-Object {$_ -ceq $selection}).Count -ne $expected){throw 'actual Resize selection mismatch'}
    $producer='C30_RASTER_PRODUCER vendor_rtl='+[int]($TestKind -eq 'vendor')+' final_pair_waits_for_vs=1 no_ready=1'
    if(@($lines|Where-Object {$_ -ceq $producer}).Count -ne $expected){throw 'actual raster producer mismatch'}
    $hasError=($lines -join "`n") -cmatch 'FATAL|ERROR:|Traceback|RuntimeError'
    if($passCount -ne $expected -or $cleanCount -ne 1 -or $hasError){throw "regression coverage: pass=$passCount expected=$expected clean=$cleanCount error=$hasError"}
    $state='complete';$step='done';$message='C30 regression passed'
} catch {$state='failed';$step='error';$runExit=1;$message=$_.Exception.Message}
finally {
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne "c1_r2_demo_rgb2_regression_$RunId"){throw 'unsafe cleanup target'}
    try {
        if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
    } catch {$state='failed';$step='cleanup';$runExit=1;$message='Private cleanup failed: '+$_.Exception.Message}
    Save-State
}
exit $runExit


