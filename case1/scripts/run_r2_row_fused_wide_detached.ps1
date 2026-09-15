# C35 shared-MAC arithmetic and all-operator fallback, after PW feeder validation.
# The waiting worker never kills, restarts or cleans its predecessor.
[CmdletBinding()]
param(
    [switch]$Worker,[switch]$CheckOnly,[string]$RunId='c35_row_fused_wide_20260914_a',[switch]$ResumeVerified,
    [ValidateRange(1,1800)][int]$TimeoutSeconds=1200
)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$depRun='c35_row_fused_graph_20260914_d'
$depPid=42272;$depStart='2026-09-14T23:26:31.2668937+08:00'
$depStatus=Join-Path $caseRoot "logs\r2_row_fused_graph_runs\$depRun\status.json"
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$depPrivate=Join-Path $simRoot "c1_r2_row_fused_graph_$depRun"
$runRoot=Join-Path $simRoot "c1_r2_row_fused_wide_$RunId"
$runLog=Join-Path $caseRoot "logs\r2_row_fused_wide_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
function Read-Predecessor{
    $s=Get-Content -LiteralPath $depStatus -Raw|ConvertFrom-Json
    if($s.run_id -ne $depRun -or $s.worker_pid -ne $depPid -or $s.worker_start -ne $depStart){throw 'unexpected predecessor identity'}
    return $s
}
function Pin-Predecessor{
    $p=Get-Process -Id $depPid -ErrorAction SilentlyContinue
    if($null -eq $p){return $null}
    if($p.ProcessName -ne 'powershell' -or $p.StartTime.ToUniversalTime().Ticks -ne ([DateTime]::Parse($depStart)).ToUniversalTime().Ticks){
        $p.Dispose()
        $null=Require-PredecessorTerminal
        return $null
    }
    $handle=$p.Handle
    return $p
}
function Require-PredecessorTerminal{
    $s=Read-Predecessor
    if($s.state -ne 'complete' -or $s.exit_code -ne 0 -or $s.simulator_directory_present -ne $false -or (Test-Path -LiteralPath $depPrivate)){
        throw 'predecessor has no clean terminal record'
    }
    # A timeout may leave an actual child running. Never interpret the parent
    # terminal state as proof that its child has also exited.
    if($s.child_pid){
        $p=Get-Process -Id $s.child_pid -ErrorAction SilentlyContinue
        if($p){
            try{
                if(-not $s.child_start -or $p.StartTime.ToUniversalTime().Ticks -eq ([DateTime]::Parse($s.child_start)).ToUniversalTime().Ticks){
                    throw 'predecessor child still alive; C35 not started'
                }
            }finally{$p.Dispose()}
        }
    }
    return $s.state
}
if(-not $Worker){
    if((Test-Path -LiteralPath $runLog) -or (Test-Path -LiteralPath $runRoot)){throw 'C35 RunId already exists'}
    $s=Read-Predecessor;$p=Pin-Predecessor
    if($p){$p.Dispose()}else{$null=Require-PredecessorTerminal}
    if($CheckOnly){
        [ordered]@{preflight_only=$true;run_id=$RunId;predecessor=$depRun;predecessor_live=($null -ne $p);
            launches_EDA=$false;modifies_files=$false}|ConvertTo-Json -Compress
        exit 0
    }
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -TimeoutSeconds $TimeoutSeconds"
    if($ResumeVerified){$command+=' -ResumeVerified'}
    $launch=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
    if($launch.ReturnValue -ne 0){throw 'WMI C35 launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$launch.ProcessId;status_path=$statusPath}|ConvertTo-Json -Compress
    exit 0
}
if((Test-Path -LiteralPath $runLog) -or (Test-Path -LiteralPath $runRoot)){throw 'C35 worker already initialized'}
New-Item -ItemType Directory -Path $runRoot,$runLog|Out-Null
$env:TEMP=$runRoot;$env:TMP=$runRoot
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$watch=[Diagnostics.Stopwatch]::StartNew()
$state='waiting';$step='predecessor';$runExit=0;$message='waiting for exact C35 shared-MAC worker exit'
$workerInJob=$null;$budgetLease=$null;$budgetOwned=$false;$workerBudget=$null
$safeCleanup=$true;$anchor=$null;$child=$null;$childPid=$null;$childStart=$null;$depResult=$null;$freeMemoryKiB=$null
function Save-State{
    [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$runExit;message=$message;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;
        predecessor=$depRun;predecessor_result=$depResult;child_pid=$childPid;child_start=$childStart;
        workload_budget=$workerBudget;free_memory_kib_before_launch=$freeMemoryKiB;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);run_directory=$runRoot;
        simulator_directory_present=(Test-Path -LiteralPath $runRoot);
        full_DAG=($state -eq 'complete');actual_AXI=$false;native_fps_claim=$false;physical_RAM_measured=$false}|ConvertTo-Json -Depth 4|
        Set-Content -LiteralPath $statusPath -Encoding UTF8
}
try{
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C35WideJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $current=[Diagnostics.Process]::GetCurrentProcess();$inJob=$false
    if(-not [C35WideJobCheck]::IsProcessInJob($current.Handle,[IntPtr]::Zero,[ref]$inJob)){throw 'cannot verify Windows Job'}
    $workerInJob=$inJob;if($workerInJob){throw 'C35 worker bound to Windows Job'}
    $current.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
    [long]$allowed=$current.ProcessorAffinity.ToInt64();[long]$mask=0;$count=0
    for($bit=0;$bit -lt 63 -and $count -lt 2;$bit++){
        [long]$candidate=[long]1 -shl $bit
        if(($allowed -band $candidate) -ne 0){$mask=$mask -bor $candidate;$count++}
    }
    if($count -lt 1){throw 'no allowed processor'}
    $current.ProcessorAffinity=[IntPtr]$mask
    $anchor=Pin-Predecessor;Save-State
    if($anchor){
        while(-not $anchor.WaitForExit(0)){
            if($watch.Elapsed.TotalHours -ge 8){throw 'observation deadline; predecessor left untouched'}
            Start-Sleep -Seconds 10
        }
    }
    $depResult=Require-PredecessorTerminal
    $freeMemoryKiB=[long](Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory
    if($freeMemoryKiB -lt 8388608){throw 'less than 8 GiB available; no C35 EDA launch'}
    . (Join-Path $PSScriptRoot 'set_fpga_worker_budget.ps1')
    $state='running';$step='component';$message='640-wide full-DAG paired row-fusion regression';Save-State
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
    $info.Arguments='-B -u "'+(Join-Path $caseRoot 'golden\run_r2_row_fused_graph_wide_probe.py')+'" --small-run '+$depRun+' --temporary-parent "'+$runRoot+'"'
    if($ResumeVerified){$info.Arguments+=' --resume-run c35_row_fused_wide_20260914_a'}
    $info.WorkingDirectory=$runRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $child=New-Object Diagnostics.Process;$child.StartInfo=$info
    if(-not $child.Start()){throw 'C35 Python probe launch failed'}
    $handle=$child.Handle;$childPid=$child.Id;$childStart=$child.StartTime.ToString('o');Save-State
    $outTask=$child.StandardOutput.ReadToEndAsync();$errTask=$child.StandardError.ReadToEndAsync()
    $timedOut=-not $child.WaitForExit($TimeoutSeconds*1000)
    if($timedOut){
        # Only this pinned child tree belongs to this worker. No broad kills.
        & taskkill.exe /PID $child.Id /T /F|Out-Null
        if(-not $child.WaitForExit(30000)){$safeCleanup=$false;throw 'own probe still alive; private directory retained'}
    }
    $child.WaitForExit();$out=$outTask.GetAwaiter().GetResult();$err=$errTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $runLog 'result.log'),$out,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $runLog 'result.stderr.log'),$err,(New-Object Text.UTF8Encoding($false)))
    if($timedOut){throw 'C35 own probe timeout; partial text retained'}
    if($child.ExitCode -ne 0 -or $err.Trim() -or
       [regex]::Matches($out,'(?m)^C35_ROW_FUSED_GRAPH_CASE ').Count -ne 6 -or
       [regex]::Matches($out,'(?m)^C35_ROW_FUSED_GRAPH_WIDE_PAIRED ').Count -ne 3 -or
       [regex]::Matches($out,'(?m)^C35_ROW_FUSED_GRAPH_EVIDENCE_PASS ').Count -ne 1 -or
       [regex]::Matches($out,'(?m)^C35_ROW_FUSED_GRAPH_WIDE_SUMMARY ').Count -ne 1 -or
       $out -notmatch '(?m)^C35_ROW_FUSED_GRAPH_WIDE_CLEAN temporary_vectors_and_simulator_removed=1'){
        throw 'C35 full DAG evidence incomplete or failed'
    }
    $state='complete';$step='done';$message='640-wide paired row-transfer math/traffic measured; not actual AXI/PNR/native fps'

}catch{$state='failed';$step='error';$runExit=1;$message=$_.Exception.Message}
finally{
    if($anchor){$anchor.Dispose()}
    if($childPid -and -not $child.WaitForExit(0)){$safeCleanup=$false}
    if($childPid){
        $remainingTools=@(Get-Process -Name vvp,iverilog,ivl,xsim,xsimk,xelab,xvlog,efx_map,efx_pnr -ErrorAction SilentlyContinue)
        if($remainingTools.Count){$safeCleanup=$false}
    }
    if(-not $safeCleanup){$state='failed';$step='cleanup_deferred';$runExit=1;$message='process still active or exit not verified; private directory retained'}
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
       (Split-Path -Leaf $resolved) -ne "c1_r2_row_fused_wide_$RunId"){throw 'unsafe own C35 cleanup target'}
    try{if($safeCleanup -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}}
    catch{$state='failed';$step='cleanup';$runExit=1;$message=$_.Exception.Message}
    Save-State
    if($child){$child.Dispose()}
    if($budgetLease){if($budgetOwned){$budgetLease.ReleaseMutex()};$budgetLease.Dispose()}
}
exit $runExit



