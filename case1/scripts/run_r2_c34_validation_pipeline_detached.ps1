# One-shot validation continuation, not a simulator worker or a goal-completion claim.
# Anchors the already running upstream queue; never restarts/kills/cleans a child.
[CmdletBinding()]
param([switch]$Worker,[switch]$CheckOnly,
      [string]$RunId='c34_validation_after_writer_20260914_a',
      [ValidateRange(60,43200)][int]$WaitLimitSeconds=28800)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid pipeline RunId'}
$upstreamRun='c34_after_c33_native_20260914_a'
$upstreamPid=39756
$upstreamStart='2026-09-14T20:29:36.7875968+08:00'
$writerRun='c34_ring_write_axi_20260914_a'
$upstreamFolder=Join-Path $caseRoot "logs\r2_serial_queue_runs\$upstreamRun"
$runLog=Join-Path $caseRoot "logs\r2_validation_pipeline_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
$stages=@()
foreach($kind in @('smoke','paired','matrix','variant','faults','negative')){
    $stages+=,[ordered]@{kind=$kind;run="c34_ring_host_${kind}_20260914_a";directory='r2_ring_rgb2_regression_runs'}
}
$stages+=,[ordered]@{kind='pnr';run='c34_ring_rgb2_host96_pnr_20260914_a';directory='efinity_resource_runs'}
function Read-Json([string]$Path){
    # Files are small. A writer can briefly be replacing its own status record.
    for($attempt=0;$attempt -lt 30;$attempt++){
        try{if(Test-Path -LiteralPath $Path){return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}}catch{}
        Start-Sleep -Milliseconds 500
    }
    throw "status unavailable after bounded observation: $Path; no restart attempted"
}
function Pin-Process([int]$TargetPid,[string]$Started){
    $process=Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    if(-not $process){return $null}
    if($process.ProcessName -ne 'powershell' -or $process.StartTime.ToUniversalTime().Ticks -ne ([DateTime]::Parse($Started)).ToUniversalTime().Ticks){
        $process.Dispose();throw 'PID identity mismatch; process left untouched'
    }
    $nativeHandle=$process.Handle
    return $process
}
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'pipeline RunId exists'}
    foreach($stage in $stages){
        if(Test-Path -LiteralPath (Join-Path $caseRoot ("logs\"+$stage.directory+'\'+$stage.run))){throw 'planned child RunId already exists'}
    }
    $up=Read-Json (Join-Path $upstreamFolder 'status.json')
    if($up.run_id -ne $upstreamRun -or $up.worker_pid -ne $upstreamPid -or $up.worker_start -ne $upstreamStart -or
       $up.next_run -ne $writerRun -or $up.state -ne 'waiting'){throw 'not the expected active upstream queue'}
    $anchor=Pin-Process $upstreamPid $upstreamStart
    if(-not $anchor){throw 'upstream queue is not alive; inspect it instead of duplicating work'}
    $anchor.Dispose()
    if($CheckOnly){
        [ordered]@{check_only=$true;upstream_actual_pid=$upstreamPid;upstream_actual_start=$upstreamStart;
            child_stages=$stages;hardware_tools_launched=0;files_created=0}|ConvertTo-Json -Depth 5
        exit 0
    }
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -WaitLimitSeconds $WaitLimitSeconds"
    $launch=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
    if($launch.ReturnValue -ne 0){throw 'WMI pipeline launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$launch.ProcessId;status_path=$statusPath}|ConvertTo-Json
    exit 0
}
if($CheckOnly){throw 'invalid Worker/CheckOnly combination'}
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$runRoot=Join-Path $simRoot "c1_r2_c34_pipeline_$RunId"
if((Test-Path -LiteralPath $runLog) -or (Test-Path -LiteralPath $runRoot)){throw 'private/run directory exists'}
New-Item -ItemType Directory -Path $runLog,$runRoot|Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew()
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$workerInJob=$null;$state='waiting';$step='upstream_queue';$message='waiting for pinned upstream queue'
$runExit=0;$activeChild=$null;$activeChildStart=$null;$completed=@();$safeCleanup=$true;$anchor=$null;$freeMemoryKiB=$null
$originalTemp=$env:TEMP;$originalTmp=$env:TMP
function Save-State{
    [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$runExit;message=$message;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;
        upstream_queue=$upstreamRun;writer_run=$writerRun;active_child_pid=$activeChild;active_child_start=$activeChildStart;
        validated_children=$completed;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        private_directory_present=(Test-Path -LiteralPath $runRoot);single_heavy_child=$true;
        free_memory_kib_before_last_launch=$freeMemoryKiB;minimum_free_memory_kib=8388608;thermal_safety_claim=$false;
        goal_complete_claim=$false;native_fps_claim=$false;board_claim=$false}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
function Wait-ExactExit($Process){
    while(-not $Process.WaitForExit(10000)){
        if($watch.Elapsed.TotalSeconds -ge $WaitLimitSeconds){throw 'pipeline observation deadline; child left running and untouched'}
    }
}
function Wait-Completed([string]$Directory,[string]$Name,[int]$TargetPid){
    $folder=Join-Path $caseRoot "logs\$Directory\$Name"
    $status=Read-Json (Join-Path $folder 'status.json')
    $actualPid=if($Directory -eq 'efinity_resource_runs'){$status.process_id}else{$status.worker_pid}
    if($status.run_id -ne $Name -or $actualPid -ne $TargetPid -or -not $status.worker_start){throw 'child identity differs from actual launch'}
    $script:activeChild=$TargetPid;$script:activeChildStart=$status.worker_start;Save-State
    $pin=Pin-Process $TargetPid $status.worker_start
    try{if($pin){Wait-ExactExit $pin}}finally{if($pin){$pin.Dispose()}}
    $status=Read-Json (Join-Path $folder 'status.json')
    if($status.run_id -ne $Name -or $status.worker_start -ne $script:activeChildStart -or
       $status.state -ne 'complete' -or $status.exit_code -ne 0 -or $status.worker_in_windows_job -ne $false -or
       (Test-Path -LiteralPath (Join-Path $folder 'interruption.json'))){throw "child $Name not cleanly complete; no next stage launched"}
    $private=[IO.Path]::GetFullPath($status.run_directory)
    if($Directory -eq 'efinity_resource_runs'){
        if((Split-Path -Leaf $private) -ne "c1_efinity_resource_c1_ti60_r2_ring_rgb2_host96_$Name" -or
           $status.run_directory_present -ne $false){throw 'Efinity private identity/cleanup differs'}
    }else{
        $prefix=if($Directory -eq 'r2_ring_write_axi_runs'){'c1_r2_ring_write_axi_'}else{'c1_r2_ring_rgb2_regression_'}
        $expected=[IO.Path]::GetFullPath((Join-Path $simRoot ($prefix+$Name)))
        if($private -ne $expected -or $status.simulator_directory_present -ne $false){throw 'simulation private identity/cleanup differs'}
    }
    if(Test-Path -LiteralPath $private){throw 'child private directory still exists'}
    $script:activeChild=$null;$script:activeChildStart=$null
    return $status
}
function Invoke-Gate([string]$Script,[string[]]$Arguments,[string]$Stem,[string]$Marker){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
    $argsList=@('-B','-u',(Join-Path $caseRoot "golden\$Script"))+$Arguments
    $info.Arguments=(@($argsList|ForEach-Object {if($_.Contains('"')){throw 'unexpected argument quote'};'"'+$_+'"'})) -join ' '
    $info.WorkingDirectory=$runRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.EnvironmentVariables['TEMP']=$runRoot;$info.EnvironmentVariables['TMP']=$runRoot
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{
        if(-not $process.Start()){throw 'cannot start evidence gate'}
        $nativeHandle=$process.Handle
        $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
        $timedOut=-not $process.WaitForExit(60000)
        if($timedOut){
            $process.Kill()
            if(-not $process.WaitForExit(10000)){$script:safeCleanup=$false;throw 'own evidence process still live; own private files retained'}
        }
        $process.WaitForExit();$out=$outTask.GetAwaiter().GetResult();$err=$errTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $runLog "$Stem.log"),$out,(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $runLog "$Stem.stderr.log"),$err,(New-Object Text.UTF8Encoding($false)))
        if($timedOut -or $process.ExitCode -ne 0 -or $err.Trim() -or $out -notmatch ('(?m)^'+$Marker+' ')){throw "evidence gate failed: $Stem"}
    }finally{$process.Dispose()}
}
try{
    # Restrict transient Add-Type compiler files to this worker's private tree.
    $env:TEMP=$runRoot;$env:TMP=$runRoot
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C34PipelineJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    $current=[Diagnostics.Process]::GetCurrentProcess()
    if(-not [C34PipelineJobCheck]::IsProcessInJob($current.Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'cannot verify Job isolation'}
    $workerInJob=$jobValue;if($workerInJob){throw 'pipeline is in a Windows Job'}
    $current.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
    [long]$allowed=$current.ProcessorAffinity.ToInt64();[long]$mask=0;$count=0
    for($bit=0;$bit -lt 63 -and $count -lt 2;$bit++){
        [long]$candidate=[long]1 -shl $bit
        if(($allowed -band $candidate) -ne 0){$mask=$mask -bor $candidate;$count++}
    }
    if($count -eq 0){throw 'no available CPU affinity'}
    $current.ProcessorAffinity=[IntPtr]$mask
    # WMI fallback children must never inherit a TEMP nested under a queue
    # that may exit while they are still running. Gates get their own PSI env.
    $env:TEMP=$originalTemp;$env:TMP=$originalTmp
    $anchor=Pin-Process $upstreamPid $upstreamStart
    Save-State
    if($anchor){Wait-ExactExit $anchor}
    $up=Read-Json (Join-Path $upstreamFolder 'status.json')
    $upPrivate=Join-Path $simRoot "c1_r2_c34_queue_$upstreamRun"
    if($up.run_id -ne $upstreamRun -or $up.worker_pid -ne $upstreamPid -or $up.worker_start -ne $upstreamStart -or
       $up.state -ne 'dispatched' -or $up.exit_code -ne 0 -or $up.next_run -ne $writerRun -or
       -not $up.next_worker_pid -or $up.private_directory_present -ne $false -or (Test-Path -LiteralPath $upPrivate)){
        throw 'upstream queue lacks exact successful dispatch and cleanup'
    }
    $step='writer';$message='waiting for actual ring writer worker';Save-State
    $writer=Wait-Completed 'r2_ring_write_axi_runs' $writerRun $up.next_worker_pid
    $step='writer_gate';Save-State
    Invoke-Gate 'check_r2_ring_write_evidence.py' @('--run',$writerRun) 'writer_gate' 'C34_RING_EVIDENCE_PASS'
    $stages|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $runLog 'validation_stages.json') -Encoding UTF8
    foreach($stage in $stages){
        if($watch.Elapsed.TotalSeconds -ge $WaitLimitSeconds){throw 'pipeline deadline before next launch'}
        if(Test-Path -LiteralPath (Join-Path $caseRoot ("logs\"+$stage.directory+'\'+$stage.run))){throw 'child RunId was created elsewhere; not launching duplicate'}
        $peers=@(Get-Process -Name xsim,xsimk,xelab,xvlog,vvp,iverilog,efx_map,efx_pnr -ErrorAction SilentlyContinue)
        if($peers.Count){throw 'another heavy FPGA tool is active; no overlapping launch'}
        $osMemory=Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory
        $freeMemoryKiB=[long]$osMemory.FreePhysicalMemory
        if($freeMemoryKiB -lt 8388608){throw 'less than 8 GiB free memory before next heavy child; no launch'}
        $state='running';$step=$stage.kind;$message='launching one independent child';Save-State
        if($stage.kind -eq 'pnr'){
            $out=& (Join-Path $PSScriptRoot 'run_efinity_ti60_resource_map_detached.ps1') -RunId $stage.run -DesignName c1_ti60_r2_ring_rgb2_host96 -ProjectInPlace -RunPnr -CdcAudit -TimeoutSeconds 1800
        }else{
            $out=& (Join-Path $PSScriptRoot 'run_r2_ring_rgb2_regression_detached.ps1') -RunId $stage.run -WriterRun $writerRun -TestKind $stage.kind -FrameDivisor 2 -TimeoutSeconds 2400
        }
        if($LASTEXITCODE -ne 0){throw 'child outer launch failed'}
        $child=($out -join "`n")|ConvertFrom-Json
        if($child.run_id -ne $stage.run -or -not $child.worker_pid){throw 'unexpected child launch record'}
        $childStatus=Wait-Completed $stage.directory $stage.run $child.worker_pid
        $step=$stage.kind+'_gate';$message='checking independent data/resource evidence';Save-State
        $option=if($stage.kind -eq 'pnr'){'--pnr'}else{'--run'}
        $marker=if($stage.kind -eq 'pnr'){'C34_PNR_PASS'}elseif($stage.kind -eq 'negative'){'C34_HOST_RAM_NEGATIVE_PASS'}else{'C34_HOST_EVIDENCE_PASS'}
        Invoke-Gate 'check_r2_ring_host_evidence.py' @($option,$stage.run) ($stage.kind+'_gate') $marker
        $completed+=,[ordered]@{kind=$stage.kind;run=$stage.run;worker_start=$childStatus.worker_start;seconds=$childStatus.elapsed_seconds}
        Save-State
    }
    $state='complete';$step='candidate_validated';$message='C34 short data tests and intended PNR footprint validated; native FPS and board integration remain open'
}catch{$state='failed';$step='error';$runExit=1;$message=$_.Exception.Message}
finally{
    if($anchor){$anchor.Dispose()}
    $env:TEMP=$originalTemp;$env:TMP=$originalTmp
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
       (Split-Path -Leaf $resolved) -ne "c1_r2_c34_pipeline_$RunId"){throw 'unsafe own pipeline cleanup target'}
    try{if($safeCleanup -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}}
    catch{$state='failed';$step='cleanup';$runExit=1;$message=$_.Exception.Message}
    Save-State
}
exit $runExit
