# Three-model native-format validation, admitted only after original acceptance work.
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='c39_model_queue_20260915a',
      [ValidateSet('native','onehot')][string]$Profile='native',
      [ValidatePattern('^[a-z][a-z0-9]{0,15}$')][string]$Attempt='a')
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid queue identifier'}
$runLog=Join-Path $caseRoot "logs\c39_model_queue_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
$dependencyRun='c39_native_acceptance_20260915a';$depPid=38200
$depStart='2026-09-15T19:14:56.5919989+08:00'
$requiredVariants=@('joint_seam','window','joint_s2_native');$jointVariant='joint_s2_native'
$modelLogPrefix='logs\c39_trained_host_runs\'
$pipelineScript='run_c39_trained_pipeline_detached.ps1'
$checkerScript='golden\check_c39_trained_pipeline.py'
$terminalMarker='C39_TRAINED_PIPELINE_PHASE_PASS '
$jobs=@(
    @{run='c39_native_starry_matrix_20260915a';model='c36_qat_b_starry_equalized_20260915a';small=$true},
    @{run='c39_native_mosaic_matrix_20260915a';model='c36_qat_b_mosaic_equalized_20260915a';small=$true},
    @{run='c39_native_stable_camera30_20260915a';model='c36_qat_b_mosaic_stable_20260915a';small=$false}
)
if($Profile -eq 'onehot'){
    $dependencyRun='c39_onehot_acceptance_20260915a';$depPid=21096
    $depStart='2026-09-15T20:05:08.1490064+08:00'
    $requiredVariants=@('joint_seam','joint_s2_onehot_cdc');$jointVariant='joint_s2_onehot_cdc'
    $modelLogPrefix='logs\c39_onehot_trained_host_runs\'
    $pipelineScript='run_c39_onehot_trained_pipeline_detached.ps1'
    $checkerScript='golden\check_c39_onehot_trained_pipeline.py'
    $terminalMarker='C39_ONEHOT_TRAINED_PIPELINE_PHASE_PASS '
    foreach($job in $jobs){$job.run=$job.run.Replace('c39_native_','c39_onehot_')}
}
foreach($job in $jobs){$job.run=$job.run -replace '_20260915a$', ('_20260915'+$Attempt)}
$dependency=Join-Path $caseRoot ('logs\c39_resource_queue_runs\'+$dependencyRun)
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
        if(Test-Path -LiteralPath (Join-Path $caseRoot ($modelLogPrefix+$job.run))){throw 'model run already exists'}
    }
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -Profile $Profile -Attempt $Attempt"
    $launch=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=$caseRoot}
    if($launch.ReturnValue -ne 0){throw 'WMI model queue launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$launch.ProcessId;status_path=$statusPath}|ConvertTo-Json
    exit 0
}
New-Item -ItemType Directory -Path $runLog -ErrorAction Stop|Out-Null
$self=Get-Process -Id $PID;$self.PriorityClass='BelowNormal';$self.ProcessorAffinity=[IntPtr]3
$workerStart=$self.StartTime.ToString('o');$inJob=$null;$state='waiting';$step='acceptance_queue'
$message='waiting for original operator/interface/window/joint-resource checks';$exitCode=0
$history=@();$pinned=$null;$childPid=$null;$childStart=$null;$afterRun=''
$watch=[Diagnostics.Stopwatch]::StartNew()
function Save-State{
    [ordered]@{run_id=$RunId;state=$state;step=$step;message=$message;exit_code=$exitCode;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$inJob;
        child_pid=$childPid;child_start=$childStart;models=$history;
        profile=$Profile;attempt=$Attempt;dependency_run=$dependencyRun;dependency_pid=$depPid;dependency_start=$depStart;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        goal_complete_claim=$false;board_signoff=$false}|ConvertTo-Json -Depth 5|
        Set-Content -LiteralPath $statusPath -Encoding UTF8
}
function Wait-Original([int]$ProcessId,[string]$Started){
    $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if(-not $process){return}
    try{
        if($process.StartTime.ToUniversalTime().Ticks -ne ([DateTime]$Started).ToUniversalTime().Ticks){return}
        $handle=$process.Handle
        while(-not $process.WaitForExit(5000)){Save-State}
    }finally{$process.Dispose()}
}
try{
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class C39ModelQueueJob { [DllImport("kernel32.dll",SetLastError=true)] public static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool r); }'
    $inJob=$false
    if(-not [C39ModelQueueJob]::IsProcessInJob($self.Handle,[IntPtr]::Zero,[ref]$inJob) -or $inJob){throw 'model queue is Job bound'}
    Save-State
    while($true){
        $dep=Read-State (Join-Path $dependency 'status.json')
        if($dep.worker_pid -ne $depPid -or $dep.worker_start -ne $depStart){throw 'wrong acceptance predecessor'}
        if($dep.state -eq 'complete'){break}
        if($dep.state -eq 'failed'){throw ('acceptance predecessor failed: '+$dep.message)}
        $original=Get-Process -Id $depPid -ErrorAction SilentlyContinue
        if(-not $original){throw 'acceptance worker disappeared without terminal evidence'}
        try{if($original.StartTime.ToUniversalTime().Ticks -ne ([DateTime]$depStart).ToUniversalTime().Ticks){throw 'acceptance PID was reused before terminal evidence'}}finally{$original.Dispose()}
        if($watch.Elapsed.TotalHours -gt 4){throw 'dependency observation deadline; no predecessor stopped'}
        Start-Sleep -Seconds 10;Save-State
    }
    Wait-Original $depPid $depStart
    foreach($variant in $requiredVariants){
        $rows=@($dep.results|Where-Object {$_.variant -eq $variant})
        if($rows.Count -ne 1 -or $rows[0].state -ne 'complete' -or $rows[0].private_directory_removed -ne $true){throw ('acceptance result not complete/clean: '+$variant)}
    }
    $joint=@($dep.results|Where-Object {$_.variant -eq $jointVariant})[0]
    if($joint.pnr_exit_code -ne 0 -or $null -eq $joint.setup_ns -or $null -eq $joint.hold_ns -or
       $joint.setup_ns -lt 0 -or $joint.hold_ns -lt 0){throw 'joint timing requires review before long-model queue'}
    if($Profile -eq 'onehot'){
        $jointLog=Join-Path $caseRoot ('logs\efinity_resource_runs\'+$joint.run_id)
        $staLog=Join-Path $jointLog 'cdc_sta.stdout.log'
        if(-not(Test-Path -LiteralPath $staLog) -or (Get-Item -LiteralPath $staLog).Length -gt 2MB){throw 'joint mapped-pin audit unavailable'}
        $sta=Get-Content -LiteralPath $staLog
        foreach($required in @('C27_MATCH tag_source=32 expected=32','C27_MATCH tag_destination=32 expected=32',
            'C27_MATCH tag_lsb_present=2 expected=2','C27_AUDIT_PASS')){
            if(@($sta|Where-Object {$_ -ceq $required}).Count -ne 1){throw ('missing mapped joint CDC audit: '+$required)}
        }
        # This qualifies only the bounded host CDC/resource experiment.
        # Actual CPU/JTAG/DDR PHY/reset/board execution remains unverified.
    }
    foreach($job in $jobs){
        $step=$job.run;$state='waiting';$message='waiting for clear tools and at least 8 GiB free';Save-State
        while($true){
            $peers=@(Get-Process -Name efx_map,efx_pnr,efx_sta,xsim,xsimk,xelab,xvlog,vvp,ivl -ErrorAction SilentlyContinue)
            $free=[long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
            if(-not $peers.Count -and $free -ge 8388608){break}
            Start-Sleep -Seconds 10;Save-State
        }
        $params=@{RunId=$job.run;QatRun=(Join-Path $caseRoot ('outputs\'+$job.model));SkipNative=$job.small;CameraProfile=$(if($job.small){'legacy'}else{'camera30'})}
        if($afterRun){$params.AfterRun=$afterRun}
        $output=& (Join-Path $PSScriptRoot $pipelineScript) @params
        if($LASTEXITCODE -ne 0){throw 'model worker launch failed'}
        $launched=($output -join "`n")|ConvertFrom-Json
        $childPid=[int]$launched.worker_pid;$pinned=Get-Process -Id $childPid -ErrorAction Stop
        $childStart=$pinned.StartTime.ToString('o');$handle=$pinned.Handle
        $bound=$false
        if(-not [C39ModelQueueJob]::IsProcessInJob($handle,[IntPtr]::Zero,[ref]$bound) -or $bound){throw 'model child is Job bound'}
        $state='running';$message='original model pipeline executing; no overlapping EDA';Save-State
        while(-not $pinned.WaitForExit(5000)){Save-State}
        $pinned.Dispose();$pinned=$null
        $modelLog=Join-Path $caseRoot ($modelLogPrefix+$job.run)
        $result=Read-State (Join-Path $modelLog 'status.json')
        if($result.worker_start -ne $childStart -or $result.state -ne 'complete' -or $result.exit_code -ne 0 -or
            $result.simulator_directory_present -ne $false -or (Test-Path -LiteralPath $result.run_directory)){
            throw ('model pipeline incomplete or not cleaned: '+$job.run)
        }
        $phase=if($job.small){'small'}else{'native'}
        $stdout=Join-Path $runLog ($job.run+'.check.stdout.log');$stderr=Join-Path $runLog ($job.run+'.check.stderr.log')
        $checker=Join-Path $caseRoot $checkerScript
        $python='D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'
        $pinned=Start-Process -FilePath $python -ArgumentList "-X utf8 -B -u `"$checker`" --run $($job.run) --phase $phase" -WorkingDirectory $caseRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $childPid=$pinned.Id;$childStart=$pinned.StartTime.ToString('o');$handle=$pinned.Handle
        $pinned.ProcessorAffinity=[IntPtr]3;$pinned.PriorityClass='BelowNormal'
        $bound=$false
        if(-not [C39ModelQueueJob]::IsProcessInJob($handle,[IntPtr]::Zero,[ref]$bound) -or $bound){throw 'terminal checker is Job bound'}
        while(-not $pinned.WaitForExit(5000)){Save-State}
        $pinned.WaitForExit();$code=$pinned.ExitCode;$pinned.Dispose();$pinned=$null
        if($code -ne 0 -or (Get-Item -LiteralPath $stderr).Length -ne 0){throw 'independent terminal model check failed'}
        $marker=$terminalMarker
        $lines=@(Get-Content -LiteralPath $stdout|Where-Object {$_.StartsWith($marker)})
        if($lines.Count -ne 1){throw 'missing independent terminal payload'}
        $verified=$lines[0].Substring($marker.Length)|ConvertFrom-Json
        if($verified.run -ne $job.run -or $verified.phase -ne $phase -or $verified.entire_pipeline_complete -ne $true -or
            $verified.temporary_removed -ne $true -or $verified.phase_only -ne $false){throw 'terminal payload is not complete-phase proof'}
        $history+=,[ordered]@{run=$job.run;model=$job.model;phase=$phase;state='complete';independent_check_pass=$true;temporary_removed=$true}
        $afterRun=$job.run;$childPid=$null;$childStart=$null;Save-State
    }
    $state='complete';$step='done';$message='three model pipelines independently verified; goal completion requires separate full audit';Save-State
}catch{$state='failed';$message=$_.Exception.Message;$exitCode=1;Save-State}
finally{if($pinned){$pinned.Dispose()};$self.Dispose()}
exit $exitCode
