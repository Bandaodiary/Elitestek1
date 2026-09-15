# C34 real AXI two-writer diagnostic; does not change the retained host.
[CmdletBinding()]
param(
    [switch]$Worker,[string]$RunId='',
    [string]$PredecessorRun='c33_write_axi_contention_20260914_c',
    [ValidateRange(1,3600)][int]$TimeoutSeconds=900
)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -eq ''){$RunId=[guid]::NewGuid().ToString('N')}
if($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $PredecessorRun -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runLog=Join-Path $caseRoot "logs\r2_ring_write_axi_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'RunId exists'}
    $unitStatus=Join-Path $caseRoot "logs\r2_credit_write_axi_runs\$PredecessorRun\status.json"
    if(-not (Test-Path -LiteralPath $unitStatus)){throw 'writer unit run has not finished; defer AXI diagnostic'}
    $unit=Get-Content -LiteralPath $unitStatus -Raw|ConvertFrom-Json
    if($unit.state -ne 'complete' -or $unit.exit_code -ne 0){throw 'writer unit run is not complete; defer AXI diagnostic'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -PredecessorRun $PredecessorRun -TimeoutSeconds $TimeoutSeconds"
    try{
        $launch=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
        if($launch.ReturnValue -ne 0){throw 'WMI launch failed'}
        $workerPid=[int]$launch.ProcessId
    }catch{$workerPid=[int](& (Join-Path $PSScriptRoot 'start_detached_process.ps1') -CommandLine $command -CurrentDirectory $caseRoot)}
    [ordered]@{run_id=$RunId;worker_pid=$workerPid;status_path=$statusPath}|ConvertTo-Json
    exit 0
}
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$runRoot=Join-Path $simRoot "c1_r2_ring_write_axi_$RunId"
if((Test-Path -LiteralPath $runRoot) -or (Test-Path -LiteralPath $runLog)){throw 'private directory exists'}
New-Item -ItemType Directory -Path $runRoot,$runLog|Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew()
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$state='running';$step='prepare';$runExit=0;$message='C34 actual AXI competing-writer diagnostic'
$workerInJob=$null;$workerBudget=$null;$budgetLease=$null;$budgetOwned=$false;$safeCleanup=$true
function Save-State{
    [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$runExit;message=$message;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;workload_budget=$workerBudget;
        predecessor_writer_run=$PredecessorRun;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);run_directory=$runRoot;
        simulator_directory_present=(Test-Path -LiteralPath $runRoot);actual_AXI=$true;actual_camera=$false;whole_CNN_fps_claim=$false}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
function Invoke-PythonProbe([string]$Arguments,[string]$Stem,[int]$Seconds){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
    $info.Arguments=$Arguments;$info.WorkingDirectory=$runRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{
        if(-not $process.Start()){throw 'could not start C34 AXI probe'}
        $handle=$process.Handle
        $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
        $timedOut=-not $process.WaitForExit($Seconds*1000)
        if($timedOut){
            & taskkill.exe /PID $process.Id /T /F|Out-Null
            if(-not $process.WaitForExit(30000)){$script:safeCleanup=$false;throw 'probe did not exit after timeout; private directory retained'}
        }
        $process.WaitForExit();$out=$outTask.GetAwaiter().GetResult();$err=$errTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $runLog "$Stem.log"),$out,(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $runLog "$Stem.stderr.log"),$err,(New-Object Text.UTF8Encoding($false)))
        if($timedOut){throw 'C34 AXI probe timeout; partial checkpoints retained'}
        if($null -eq $process.ExitCode -or $process.ExitCode -ne 0){throw "C34 $Stem failed exit=$($process.ExitCode)"}
        return $out
    }finally{$process.Dispose()}
}
try{
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C34AxiJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C34AxiJobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'cannot check Job isolation'}
    $workerInJob=$jobValue;if($workerInJob){throw 'worker bound to Windows Job'}
    . (Join-Path $PSScriptRoot 'set_fpga_worker_budget.ps1')
    $env:TEMP=Join-Path $runRoot 'tmp';$env:TMP=$env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP|Out-Null
    $step='writer_gate';Save-State
    $gate=Invoke-PythonProbe ('-B -u "'+(Join-Path $caseRoot 'golden\check_r2_credit_write_evidence.py')+'" --run '+$PredecessorRun) 'writer_gate' 60
    if($gate -notmatch 'C33_CREDIT_EVIDENCE_PASS '){throw 'writer predecessor gate incomplete'}
    $step='word_model';Save-State
    $model=Invoke-PythonProbe ('-B -u "'+(Join-Path $caseRoot 'golden\check_r2_ring_reservation_model.py')+'"') 'word_model' 60
    if($model -notmatch 'C34_RING_MODEL_PASS '){throw 'ring word model incomplete'}
    $step='regression';Save-State
    $out=Invoke-PythonProbe ('-B -u "'+(Join-Path $caseRoot 'golden\run_r2_ring_write_contention.py')+'" --temporary-parent "'+$runRoot+'"') 'result' $TimeoutSeconds
    if([regex]::Matches($out,'(?m)^C34_WRITE_AXI_PASS ').Count -ne 92 -or
       [regex]::Matches($out,'(?m)^C34_WRITE_AXI_COMPARE ').Count -ne 24 -or
       [regex]::Matches($out,'(?m)^C34_WRITE_AXI_NEGATIVE_PASS ').Count -ne 2 -or
       [regex]::Matches($out,'(?m)^C34_WRITE_AXI_SUMMARY ').Count -ne 1 -or
       [regex]::Matches($out,'(?m)^C34_WRITE_AXI_CLEAN temporary_vectors_and_simulator_removed=1').Count -ne 1 -or
       $out -cmatch 'FATAL|ERROR:|Traceback|RuntimeError'){throw 'C34 AXI evidence incomplete'}
    $state='complete';$step='done';$message='C34 AXI diagnostic completed; signed contention deltas are not a speedup gate'
}catch{$state='failed';$step='error';$runExit=1;$message=$_.Exception.Message}
finally{
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne "c1_r2_ring_write_axi_$RunId"){throw 'unsafe private cleanup target'}
    try{if($safeCleanup -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}}
    catch{$state='failed';$step='cleanup';$runExit=1;$message=$_.Exception.Message}
    Save-State
    if($budgetLease){if($budgetOwned){$budgetLease.ReleaseMutex()};$budgetLease.Dispose()}
}
exit $runExit
