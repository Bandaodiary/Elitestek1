# One bounded serial experiment; never restarts or kills predecessor/EDA workers.
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='c39_ablation_20260915a',
      [ValidateSet('combined_ablation','native_acceptance','onehot_acceptance')][string]$Profile='combined_ablation')
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid run identifier'}
$runLog=Join-Path $caseRoot "logs\c39_resource_queue_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if($Profile -eq 'onehot_acceptance'){
    $dependencyRun='c39_onehot_fallback_20260915a'
    $expectedWorker=37320;$expectedWorkerStart='2026-09-15T19:58:38.0939319+08:00'
    $jobs=@(@{variant='joint_s2_onehot_cdc';design='c1_ti60_c39_joint_s2_onehot_cdc';pnr=$true;cdc=$true})
}elseif($Profile -eq 'native_acceptance'){
    $dependencyRun='c39_native_fallback_20260915b'
    $expectedWorker=36548;$expectedWorkerStart='2026-09-15T18:54:47.6903828+08:00'
    $jobs=@(
        @{variant='window';design='c1_ti60_c39_host_window';pnr=$false},
        @{variant='joint_s2_native';design='c1_ti60_c39_joint_s2_native';pnr=$true}
    )
}else{
    $dependencyRun='c39_fallback_20260915a'
    $expectedWorker=36888;$expectedWorkerStart='2026-09-15T18:20:16.7147271+08:00'
    $jobs=@(
        @{variant='combined';design='c1_ti60_c39_host_combined';pnr=$true},
        @{variant='quant';design='c1_ti60_c39_host_quant';pnr=$false},
        @{variant='operands';design='c1_ti60_c39_host_operands';pnr=$false},
        @{variant='window';design='c1_ti60_c39_host_window';pnr=$false}
    )
}
$dependency=Join-Path $caseRoot ('logs\c39_datapath_runs\'+$dependencyRun)
function Read-State([string]$Path){
    for($attempt=0;$attempt -lt 5;$attempt++){
        try{
            $value=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -ErrorAction Stop
            if(-not $value.run_id){throw 'incomplete state write'}
            return $value
        }catch{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 200}
    }
}
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'queue already exists'}
    foreach($job in $jobs){
        if(Test-Path -LiteralPath (Join-Path $caseRoot ("logs\efinity_resource_runs\"+$RunId+'_'+$job.variant))){throw 'resource run already exists'}
    }
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -Profile $Profile"
    $launch=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
    if($launch.ReturnValue -ne 0){throw 'detached queue launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$launch.ProcessId;status_path=$statusPath}|ConvertTo-Json
    exit 0
}
New-Item -ItemType Directory -Path $runLog -ErrorAction Stop|Out-Null
$self=Get-Process -Id $PID
$self.PriorityClass='BelowNormal';$self.ProcessorAffinity=[IntPtr]3
$workerStart=$self.StartTime.ToString('o');$workerInJob=$null
$state='waiting';$step='original_fallback';$message='waiting for original full operator regression'
$history=@();$pinned=$null;$childPid=$null;$childStart=$null;$exitCode=0
$watch=[Diagnostics.Stopwatch]::StartNew()
function Save-State{
    [ordered]@{run_id=$RunId;state=$state;step=$step;message=$message;exit_code=$exitCode;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;
        profile=$Profile;dependency_run=$dependencyRun;dependency_worker_start=$expectedWorkerStart;
        child_pid=$childPid;child_start=$childStart;results=$history;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        goal_complete_claim=$false;board_signoff=$false}|ConvertTo-Json -Depth 5|
        Set-Content -LiteralPath $statusPath -Encoding UTF8
}
function Wait-ExactGone([int]$ProcessId,[string]$Started){
    $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if(-not $process){return}
    try{
        if($process.StartTime.ToUniversalTime().Ticks -ne ([DateTime]::Parse($Started)).ToUniversalTime().Ticks){return}
        $handle=$process.Handle
        while(-not $process.WaitForExit(5000)){Save-State}
    }finally{$process.Dispose()}
}
try{
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class C39QueueJob { [DllImport("kernel32.dll",SetLastError=true)] public static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool r); }'
    $workerInJob=$false
    if(-not [C39QueueJob]::IsProcessInJob($self.Handle,[IntPtr]::Zero,[ref]$workerInJob) -or $workerInJob){throw 'queue not Job independent'}
    Save-State
    while($true){
        $dep=Read-State (Join-Path $dependency 'status.json')
        if($dep.worker_start -ne $expectedWorkerStart -or $dep.worker_pid -ne $expectedWorker){throw 'predecessor identity differs'}
        if($dep.state -eq 'complete'){break}
        if($dep.state -ne 'running'){throw ('predecessor did not pass: '+$dep.state)}
        $original=Get-Process -Id $dep.worker_pid -ErrorAction SilentlyContinue
        if(-not $original){throw 'predecessor disappeared without complete status'}
        try{if($original.StartTime.ToUniversalTime().Ticks -ne ([DateTime]::Parse($expectedWorkerStart)).ToUniversalTime().Ticks){throw 'predecessor PID reused'}}finally{$original.Dispose()}
        if($watch.Elapsed.TotalHours -ge 2){throw 'dependency wait limit; predecessor untouched'}
        Start-Sleep -Seconds 10;Save-State
    }
    Wait-ExactGone $dep.worker_pid $dep.worker_start
    Wait-ExactGone $dep.child_pid $dep.child_start
    # Progress heartbeats can separate ST0 from ST1 by many lines. Read this
    # bounded small log, not merely its last lines, to prove both PASS records.
    $dependencyLog=Join-Path $dependency 'stdout.log'
    if((Get-Item -LiteralPath $dependencyLog).Length -gt 262144){throw 'unexpected dependency log size'}
    $tail=Get-Content -LiteralPath $dependencyLog
    if($dep.exit_code -ne 0 -or $dep.child_in_windows_job -ne $false -or
        -not ($tail -contains 'C39_DATAPATH_PHASE_PASS phase=fallback actual_candidate_sources=1 temporary_removed=1 waves=0') -or
        @($tail|Where-Object {$_ -match '^C37_ACTUAL_RTL C37_OPERATOR_PASS '}).Count -ne 2){throw 'predecessor lacks both actual PASS records/cleanup'}
    if($Profile -in @('native_acceptance','onehot_acceptance')){
        $hostVariant=if($Profile -eq 'onehot_acceptance'){'onehot'}else{'native'}
        $variantHeader=if($hostVariant -eq 'onehot'){'C39_ONEHOT_VARIANT_BEGIN actual_shared_decode_unpack=1'}else{'C39_NATIVE_VARIANT_BEGIN actual_compact_RGB_DW_construction=1'}
        if($dep.variant -ne $hostVariant -or $tail[0] -ne $variantHeader){
            throw 'native acceptance depends on wrong actual source variant'
        }
        if($hostVariant -eq 'onehot'){
            $python='D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'
            $gateOutput=& $python -X utf8 -B (Join-Path $caseRoot 'golden\c39_onehot_operator_preflight.py') 2>&1
            $gateCode=$LASTEXITCODE
            $gateOutput|Set-Content -LiteralPath (Join-Path $runLog 'operator_preflight.log') -Encoding UTF8
            if($gateCode -ne 0){throw 'independent onehot full-operator gate failed'}
            $sourceOutput=& $python -X utf8 -B (Join-Path $caseRoot 'golden\c39_joint_cdc_projects.py') 2>&1
            $sourceCode=$LASTEXITCODE
            $sourceOutput|Set-Content -LiteralPath (Join-Path $runLog 'joint_cdc_source_preflight.log') -Encoding UTF8
            if($sourceCode -ne 0){throw 'joint CDC source gate failed'}
        }
        $step='joint_seam';$state='running';$message='actual candidate host seam with explicitly behavioral CPU/DDR';Save-State
        $seamOut=Join-Path $runLog 'joint_seam.stdout.log';$seamErr=Join-Path $runLog 'joint_seam.stderr.log'
        $python='D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'
        $script=Join-Path $caseRoot 'golden\run_c39_joint_seam_probe.py'
        $cpu=Join-Path $caseRoot 'efinity\c39_cpu_s2_generate_20260915a'
        $pinned=Start-Process -FilePath $python -ArgumentList "-X utf8 -B -u `"$script`" `"$cpu`" --host $hostVariant" -WorkingDirectory $caseRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $seamOut -RedirectStandardError $seamErr
        $childPid=$pinned.Id;$childStart=$pinned.StartTime.ToString('o');$handle=$pinned.Handle
        $jobBound=$false
        if(-not [C39QueueJob]::IsProcessInJob($handle,[IntPtr]::Zero,[ref]$jobBound) -or $jobBound){throw 'seam child is Job bound'}
        while(-not $pinned.WaitForExit(5000)){Save-State}
        $pinned.WaitForExit();$seamCode=$pinned.ExitCode;$pinned.Dispose();$pinned=$null
        $seamLines=Get-Content -LiteralPath $seamOut
        if($seamCode -ne 0 -or (Get-Item -LiteralPath $seamErr).Length -ne 0 -or
            @($seamLines|Where-Object {$_ -match '^C39_JOINT_SEAM_PASS checks=9 '}).Count -ne 1 -or
            @($seamLines|Where-Object {$_ -match '^C39_ACTUAL_WIRING_NEGATIVE_PASS '}).Count -ne 3 -or
            -not ($seamLines -contains 'C39_SEAM_CLEAN temporary_directory_removed=1 waves_written=0')){
            throw 'native seam lacks actual checks/negative controls/clean terminal evidence'
        }
        $history+=,[ordered]@{variant='joint_seam';state='complete';checks=9;actual_wiring_negative_controls=3;real_CPU_execution=$false;private_directory_removed=$true}
        $childPid=$null;$childStart=$null;Save-State
    }
    foreach($job in $jobs){
        $variant=$job.variant;$resourceRun=$RunId+'_'+$variant
        $step=$variant;$state='waiting';$message='waiting for external tools and 8 GiB free memory';Save-State
        while($true){
            $external=@(Get-Process -Name efx_map,efx_pnr,efx_sta,xsim,xsimk,vvp,ivl,xelab,xvlog -ErrorAction SilentlyContinue)
            $memory=[long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
            if($external.Count -eq 0 -and $memory -ge 8388608){break}
            Start-Sleep -Seconds 10;Save-State
        }
        $params=@{DesignName=$job.design;RunId=$resourceRun;ProjectInPlace=$true;TimeoutSeconds=1200;RunPnr=$job.pnr}
        if($job.cdc){$params.CdcAudit=$true}
        $launched=& (Join-Path $PSScriptRoot 'run_efinity_ti60_resource_map_detached.ps1') @params
        if($LASTEXITCODE -ne 0){throw 'resource worker launch failed'}
        $child=($launched -join "`n")|ConvertFrom-Json
        $childPid=[int]$child.worker_pid
        $pinned=Get-Process -Id $childPid -ErrorAction Stop
        $childStart=$pinned.StartTime.ToString('o');$nativeHandle=$pinned.Handle
        $jobBound=$false
        if(-not [C39QueueJob]::IsProcessInJob($nativeHandle,[IntPtr]::Zero,[ref]$jobBound) -or $jobBound){throw 'resource worker is Job bound'}
        $state='running';$message='original resource worker running; no overlapping heavy work';Save-State
        while(-not $pinned.WaitForExit(5000)){Save-State}
        $pinned.Dispose();$pinned=$null
        $resourceLog=Join-Path $caseRoot ('logs\efinity_resource_runs\'+$resourceRun)
        $terminal=Get-Content -LiteralPath (Join-Path $resourceLog 'status.json') -Raw|ConvertFrom-Json
        $summary=Get-Content -LiteralPath (Join-Path $resourceLog 'summary.json') -Raw|ConvertFrom-Json
        if($terminal.worker_start -ne $childStart -or $terminal.run_directory_present -ne $false -or
           (Test-Path -LiteralPath $terminal.run_directory) -or $terminal.state -notin @('complete','failed')){throw 'resource worker lacks clean terminal state'}
        $history+=,[ordered]@{variant=$variant;run_id=$resourceRun;state=$terminal.state;
            lut4=$summary.metrics.le;ff=$summary.metrics.registers;ram=$summary.metrics.ebr;dsp=$summary.metrics.dsp;
            pnr_requested=$job.pnr;pnr_exit_code=$summary.pnr_exit_code;
            xlr=$summary.pnr_resources.xlr_cells_used;setup_ns=$summary.timing.final_slack_ns;
            hold_ns=$summary.timing.final_hold_slack_ns;private_directory_removed=$true}
        $childPid=$null;$childStart=$null;Save-State
    }
    $state='complete';$step='done';$message='bounded experiment collected; inspect per-run success/timing, not goal signoff';Save-State
}catch{
    $state='failed';$message=$_.Exception.Message;$exitCode=1;Save-State
}finally{
    # A failed observer never terminates or cleans an original worker.
    if($pinned){$pinned.Dispose()}
    $self.Dispose()
}
exit $exitCode
