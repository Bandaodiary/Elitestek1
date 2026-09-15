# C39: independent one-hot resource candidate, actual three-model host checks.
# Serial, WMI-detached, two CPUs, no waves; existing C35/C36 workers unchanged.
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='c39_onehot_trained_host_20260915a',
      [string]$QatRun='',[switch]$SkipNative,[string]$AfterRun='',
      [ValidateSet('legacy','camera30')][string]$CameraProfile='legacy')
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
if($AfterRun -and ($AfterRun -notmatch '^[A-Za-z0-9_-]+$' -or $AfterRun -eq $RunId)){throw 'invalid predecessor run'}
if($SkipNative -and $CameraProfile -ne 'legacy'){throw 'camera pressure profile requires a native phase'}
if(-not $QatRun){$QatRun=Join-Path $caseRoot 'outputs\c36_qat_b_starry_equalized_20260915a'}
$QatRun=(Resolve-Path -LiteralPath $QatRun).Path
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$runRoot=Join-Path $simRoot "c1_c39_onehot_trained_host_$RunId"
$runLog=Join-Path $caseRoot "logs\c39_onehot_trained_host_runs\$RunId"
if((Test-Path -LiteralPath $runRoot) -or (Test-Path -LiteralPath $runLog)){throw 'C39 run already exists'}
if(-not $Worker){
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $line="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -QatRun `"$QatRun`""
    if($SkipNative){$line+=' -SkipNative'}
    if($AfterRun){$line+=" -AfterRun $AfterRun"}
    $line+=" -CameraProfile $CameraProfile"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$line;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw 'WMI C39 launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$r.ProcessId;status_path=(Join-Path $runLog 'status.json');waits_for_original_C35=$false;after_run=$AfterRun}|ConvertTo-Json -Compress
    exit 0
}
New-Item -ItemType Directory -Path $runRoot,$runLog,(Join-Path $runRoot 'tmp')|Out-Null
$env:TEMP=Join-Path $runRoot 'tmp';$env:TMP=$env:TEMP
$python='D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'
$vivado='D:\vivado\vivado\Vivado\2023.1\bin'
$env:OMP_NUM_THREADS='2';$env:MKL_NUM_THREADS='2';$env:OPENBLAS_NUM_THREADS='2'
$watch=[Diagnostics.Stopwatch]::StartNew()
$workerStart=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$state='waiting';$step='admission';$message='checking C39 predecessor and single-worker admission';$exitCode=0
$workerInJob=$null;$workerBudget=$null;$budgetLease=$null;$budgetOwned=$false
$stepPid=$null;$stepStart=$null;$stepInJob=$null;$safeCleanup=$true;$memoryKiB=$null
$history=@();$anchor=$null;$predecessor=$null
function Save-State {
    [ordered]@{run_id=$RunId;state=$state;step=$step;message=$message;exit_code=$exitCode;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;
        step_pid=$stepPid;step_start=$stepStart;step_in_windows_job=$stepInJob;
        workload_budget=$workerBudget;free_memory_kib_before_launch=$memoryKiB;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);heartbeat=(Get-Date).ToString('o');
        run_directory=$runRoot;simulator_directory_present=(Test-Path -LiteralPath $runRoot);
        qat_run=$QatRun;skip_native=[bool]$SkipNative;camera_profile=$CameraProfile;completed_steps=$history;
        after_run=$AfterRun;predecessor=$predecessor;
        production_RTL_changed=$true;candidate='C39_ONEHOT';native_fps_claim=$false}|ConvertTo-Json -Depth 6|
        Set-Content -LiteralPath (Join-Path $runLog 'status.json') -Encoding UTF8
}
function Invoke-Step([string]$Name,[string]$Executable,[string[]]$Arguments,[string]$Directory,[int]$Limit) {
    $script:state='running';$script:step=$Name;$script:message="running $Name";Save-State
    $script:memoryKiB=[long](Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory
    if($memoryKiB -lt 8388608){throw "less than 8 GiB free before $Name"}
    $stdout=Join-Path $Directory "$Name.stdout.log";$stderr=Join-Path $Directory "$Name.stderr.log"
    $quoted=@($Arguments|ForEach-Object {if($_.Contains('"')){throw 'unexpected quote in argument'};'"'+$_+'"'})
    $p=Start-Process -FilePath $Executable -ArgumentList $quoted -WorkingDirectory $Directory -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        $handle=$p.Handle;$script:stepPid=$p.Id;$script:stepStart=$p.StartTime.ToString('o')
        $j=$false
        if(-not [C39TrainingJob]::IsProcessInJob($handle,[IntPtr]::Zero,[ref]$j)){throw 'child Job check failed'}
        $script:stepInJob=$j;if($j){throw 'child is in a Windows Job'};Save-State
        while(-not $p.WaitForExit(5000)) {
            Save-State
            if($timer.Elapsed.TotalSeconds -gt $Limit) {
                # Only this pinned, still-live owned step. Never the C35 predecessor.
                & taskkill.exe /PID $p.Id /T /F|Out-Null
                if(-not $p.WaitForExit(30000)){$script:safeCleanup=$false}
                throw "$Name exceeded its execution limit"
            }
        }
        $p.WaitForExit();$code=$p.ExitCode
        if((Get-Item -LiteralPath $stdout).Length -gt 1048576 -or (Get-Item -LiteralPath $stderr).Length -gt 262144){throw 'unexpected output size; retain private evidence'}
        $out=Get-Content -LiteralPath $stdout -Raw;$err=Get-Content -LiteralPath $stderr -Raw
        @($out -split '\r?\n'|Select-Object -Last 70)+@($err -split '\r?\n'|Select-Object -Last 25)|
            Set-Content -LiteralPath (Join-Path $runLog "$Name.tail.log") -Encoding UTF8
        $script:history += [ordered]@{name=$Name;pid=$p.Id;start=$script:stepStart;in_windows_job=$j;exit_code=$code;
            stdout_bytes=(Get-Item -LiteralPath $stdout).Length;stderr_bytes=(Get-Item -LiteralPath $stderr).Length;
            free_memory_kib_at_phase_admission=$memoryKiB;seconds=[math]::Round($timer.Elapsed.TotalSeconds,3)}
        if($Name -match '_xvlog$') {
            # xvlog emits per-file VRFC analysis records, not a Running header.
            @($out -split '\r?\n'|Where-Object {$_ -match '^INFO: \[VRFC 10-2263\] Analyzing SystemVerilog file '})|
                Set-Content -LiteralPath (Join-Path $runLog "$Name.sources.log") -Encoding UTF8
        }
        if($Name -eq 'host_matrix') {
            # Copy the actual streams, including a real zero-byte stderr file.
            # Piping $null from Get-Content does not create that evidence file.
            Copy-Item -LiteralPath $stdout -Destination (Join-Path $runLog 'host_matrix.result.log')
            Copy-Item -LiteralPath $stderr -Destination (Join-Path $runLog 'host_matrix.stderr.log')
            if($out -notmatch '(?m)^C39_ONEHOT_TRAINED_HOST_MATRIX_PASS '){throw 'missing real trained-host matrix result'}
        }
        if($Name -match '_xsim$') {
            @($out -split '\r?\n'|Where-Object {$_ -match '^C1_R2_FUSED_RGB2_HOST_SYSTEM_'})|
                Set-Content -LiteralPath (Join-Path $runLog "$Name.result.log") -Encoding UTF8
            # xsim prints its executed Tcl command. Do not substitute the
            # supervisor's intended arguments for this actual tool record.
            @($out -split '\r?\n'|Where-Object {$_ -match '^# xsim \{'})|
                Set-Content -LiteralPath (Join-Path $runLog "$Name.invocation.log") -Encoding UTF8
            if($out -notmatch '(?m)^C1_R2_FUSED_RGB2_HOST_SYSTEM_PASS ' -or ($out+$err) -match '(?im)FATAL|ERROR:'){throw 'xsim did not pass'}
        }
        if($null -eq $code -or $code -ne 0){throw "$Name failed with exit $code"}
        Save-State
    }finally{
        if(-not $p.WaitForExit(0)){$script:safeCleanup=$false}
        $p.Dispose()
    }
}
function Simulate-Xsim([string]$Name,[int]$Width,[int]$Height,[int]$NnTarget,[int]$Stalls) {
    $folder=Join-Path $runRoot $Name;New-Item -ItemType Directory -Path $folder|Out-Null
    Invoke-Step ($Name+'_vectors') $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\c39_onehot_trained_contract.py'),
        '--qat-run',$QatRun,'--output',$folder,'--width',"$Width",'--height',"$Height") $folder 300
    $meta=Get-Content -LiteralPath (Join-Path $folder 'metadata.json') -Raw|ConvertFrom-Json
    $meta|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $runLog ($Name+'.metadata.json')) -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $folder 'package\execution_plan.sv') -Destination (Join-Path $runLog ($Name+'.execution_plan.sv'))
    Copy-Item -LiteralPath (Join-Path $folder 'fusion_plan.sv') -Destination (Join-Path $runLog ($Name+'.fusion_plan.sv'))
    [xml]$project=Get-Content -LiteralPath (Join-Path $caseRoot 'efinity\c1_ti60_c39_host_onehot.xml') -Raw
    $sources=@($project.SelectNodes("//*[local-name()='design_file']")|Where-Object {(Split-Path -Leaf $_.name) -ne 'c1_ti60_c39_host_onehot.sv' -and
        (Split-Path -Leaf $_.name) -notin @('execution_plan.sv','row_fusion_plan.sv')}|
        ForEach-Object {if([IO.Path]::IsPathRooted($_.name)){$_.name}else{Join-Path (Join-Path $caseRoot 'efinity') $_.name}})
    $sources += (Join-Path $folder 'package\execution_plan.sv'),(Join-Path $folder 'fusion_plan.sv')
    if($sources.Count -ne 49){throw 'wrong C39 production source closure'}
    $sources|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $runLog ($Name+'.sources.json')) -Encoding UTF8
    $top='tb_c1_r2_fused_rgb2_host_system';$snapshot='c39_onehot_trained_'+$Name
    $testbench=Join-Path $caseRoot "sim\$top.sv";$frameDivisor=2
    if($Name -eq 'native' -and $CameraProfile -ne 'legacy') {
        $fixture=Join-Path $folder 'camera_fixture'
        Invoke-Step ($Name+'_camera_fixture') $python @('-X','utf8','-B','-u',
            (Join-Path $caseRoot 'golden\prepare_r2_camera_cadence.py'),'--profile',$CameraProfile,'--output-dir',$fixture) $folder 180
        $testbench=Join-Path $fixture "$top.sv"
        $cadence=Get-Content -LiteralPath (Join-Path $fixture 'cadence.json') -Raw|ConvertFrom-Json
        if($cadence.profile -ne $CameraProfile -or $cadence.production_RTL_changed -ne $false){throw 'wrong camera fixture'}
        $frameDivisor=$cadence.frame_divisor
        Copy-Item -LiteralPath $testbench -Destination (Join-Path $runLog ($Name+'.testbench.sv'))
        Copy-Item -LiteralPath (Join-Path $fixture 'cadence.json') -Destination (Join-Path $runLog ($Name+'.cadence.json'))
    }
    Invoke-Step ($Name+'_xvlog') (Join-Path $vivado 'xvlog.bat') (@('-sv')+$sources+
        (Join-Path $caseRoot 'sim\c1_r2_axi_memory_bfm.sv')+(Join-Path $caseRoot 'sim\c1_r2_axi_traffic_agent.sv')+
        $testbench) $folder 300
    $banks=if($Width -eq 640){524288}else{16384}
    $generic=@('-generic_top',"BANK_WORDS=$banks",'-generic_top',"WIDTH=$Width",'-generic_top',"HEIGHT=$Height",
        '-generic_top','MAX_CYCLES=120000000','-generic_top',"NN_TARGET=$NnTarget",'-generic_top',"STAGE_COUNT=$($meta.stage_count)",
        '-generic_top',"RGB_STAGE=$($meta.rgb_stage)",'-generic_top',"FUSED_DW_STAGE=$($meta.dw_stage)",'-generic_top',"FUSED_PW_STAGE=$($meta.pw_stage)",
        '-generic_top','MEMORY_DIV=2','-generic_top','COMMAND_LATENCY=20','-generic_top',"STALLS=$Stalls",
        '-generic_top','AW_WAIT_W=2','-generic_top',"FRAME_DIVISOR=$frameDivisor",'-generic_top','CLOCKS_NATIVE=1','-generic_top','CPU_START_NEGATIVE=0')
    $camera=$meta.sources[0]
    foreach($mapping in @(@('CAMERA_SW','width'),@('CAMERA_SH','height'),@('CAMERA_RX','roi_x'),@('CAMERA_RY','roi_y'),@('CAMERA_RW','roi_width'),@('CAMERA_RH','roi_height'))){
        $generic+=@('-generic_top',"$($mapping[0])=$($camera.($mapping[1]))")
    }
    Invoke-Step ($Name+'_xelab') (Join-Path $vivado 'xelab.bat') (@($top,'-s',$snapshot,'-mt','2')+$generic) $folder 600
    $plus=@('-testplusarg',"DIR=$($folder.Replace('\','/'))",'-testplusarg',"P=$($meta.parameter_words)",'-testplusarg',"I=$($meta.input_words)",
        '-testplusarg',"E=$($meta.expected_words)",'-testplusarg',"DW=$($meta.dw_packets)")
    for($i=0;$i -lt 2;$i++) {
        foreach($mapping in @(@('SW','width'),@('SH','height'),@('XS','xs'),@('YS','ys'),@('XP','xp'),@('YP','yp'))){
            $plus+=@('-testplusarg',"$($mapping[0])$i=$($meta.sources[$i].($mapping[1]))")
        }
    }
    Invoke-Step ($Name+'_xsim') (Join-Path $vivado 'xsim.bat') (@($snapshot,'-runall')+$plus) $folder 14400
    Invoke-Step ($Name+'_check') $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\check_c39_onehot_trained_pipeline.py'),
        '--run',$RunId,'--phase',$Name,'--allow-running') $folder 180
}
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C39TrainingJob {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool result);
}
'@
    $current=[Diagnostics.Process]::GetCurrentProcess();$j=$false
    if(-not [C39TrainingJob]::IsProcessInJob($current.Handle,[IntPtr]::Zero,[ref]$j)){throw 'worker Job check failed'}
    $workerInJob=$j;if($j){throw 'worker is bound to a Windows Job'}
    $current.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
    if($AfterRun) {
        $priorDirectory=Join-Path $caseRoot "logs\c39_onehot_trained_host_runs\$AfterRun"
        $priorStatus=Join-Path $priorDirectory 'status.json'
        $prior=Get-Content -LiteralPath $priorStatus -Raw|ConvertFrom-Json
        $priorPrivate=Join-Path $simRoot "c1_c39_onehot_trained_host_$AfterRun"
        if($prior.run_id -ne $AfterRun -or [IO.Path]::GetFullPath($prior.run_directory) -ne $priorPrivate -or $prior.worker_in_windows_job -ne $false){throw 'wrong predecessor identity or Job'}
        if($prior.skip_native -isnot [bool]){throw 'predecessor terminal phase is not explicit'}
        $priorPhase=if($prior.skip_native){'small'}else{'native'}
        $predecessor=[ordered]@{run=$AfterRun;worker_pid=$prior.worker_pid;worker_start=$prior.worker_start;
            actual_handle_waited=$false;strict_preflight_phase=$priorPhase;strict_native_preflight_required=($priorPhase -eq 'native')}
        $anchor=Get-Process -Id $prior.worker_pid -ErrorAction SilentlyContinue
        if($anchor -and $anchor.StartTime.ToUniversalTime().Ticks -ne ([DateTime]$prior.worker_start).ToUniversalTime().Ticks){
            # The original worker has exited; never wait on a reused PID.
            $anchor.Dispose();$anchor=$null;$predecessor.pid_reused=$true
        }
        if($anchor) {
            # PowerShell 7 may decode JSON dates as DateTime already; casting
            # preserves fractional ticks, whereas Parse(object) may stringify
            # with a seconds-only culture format. Windows PowerShell also works.
            $handle=$anchor.Handle;$predecessor.actual_handle_waited=$true
            $state='waiting';$step='predecessor';$message="waiting for actual worker exit: $AfterRun";Save-State
            while(-not $anchor.WaitForExit(5000)) {
                Save-State
                if($watch.Elapsed.TotalHours -gt 8){throw 'predecessor observation deadline; no process terminated'}
            }
            $anchor.Dispose();$anchor=$null
        }
        # Actual exit first, then terminal status and cleanup. Never infer a
        # dead simulator from an unchanged heartbeat or an observation timeout.
        $prior=Get-Content -LiteralPath $priorStatus -Raw|ConvertFrom-Json
        if($prior.skip_native -isnot [bool] -or ($(if($prior.skip_native){'small'}else{'native'})) -ne $priorPhase){throw 'predecessor phase changed during observation'}
        if($prior.state -ne 'complete' -or $prior.exit_code -ne 0 -or $prior.simulator_directory_present -ne $false -or (Test-Path -LiteralPath $priorPrivate)){
            throw 'predecessor did not complete and clean; independent review required'
        }
    }
    if(@(Get-Process -Name efx_sta,ivl -ErrorAction SilentlyContinue).Count){throw 'STA/compiler still active; no overlapping launch'}
    . (Join-Path $PSScriptRoot 'set_fpga_worker_budget.ps1')
    $memoryKiB=[long](Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory
    if($memoryKiB -lt 8388608){throw 'less than 8 GiB free before EDA; no launch'}
    Save-State
    Invoke-Step 'c39_onehot_operator_preflight' $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\c39_onehot_operator_preflight.py')) $runRoot 180
    Invoke-Step 'c39_onehot_source_preflight' $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\c39_onehot_trained_contract.py')) $runRoot 180
    Invoke-Step 'c36_native_preflight' $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\check_r2_trained_pipeline.py'),
        '--run','c36_mosaic_stable_camera30_20260915a','--phase','native') $runRoot 180
    if($AfterRun) {
        Invoke-Step ('predecessor_'+$priorPhase+'_preflight') $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\check_c39_onehot_trained_pipeline.py'),
            '--run',$AfterRun,'--phase',$priorPhase) $runRoot 180
    }
    $matrix=Join-Path $runRoot 'matrix';New-Item -ItemType Directory -Path $matrix|Out-Null
    Invoke-Step 'host_matrix' $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\run_c39_onehot_trained_host_probe.py'),
        '--qat-run',$QatRun,'--run-directory',$matrix) $matrix 1800
    Invoke-Step 'matrix_check' $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\check_c39_onehot_trained_pipeline.py'),
        '--run',$RunId,'--phase','matrix','--allow-running') $matrix 180
    Simulate-Xsim 'small' 8 8 2 1
    if(-not $SkipNative) {
        $memoryKiB=[long](Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory
        if($memoryKiB -lt 8388608){throw 'less than 8 GiB free before native xsim'}
        Simulate-Xsim 'native' 640 480 6 0
    }
    $state='complete';$step='done';$message='trained RTL matrix and requested xsim phases completed'
}catch{$state='failed';$step='error';$exitCode=1;$message=$_.Exception.Message}
finally {
    if($anchor){$anchor.Dispose()}
    try {
        $resolved=(Resolve-Path -LiteralPath $runRoot).Path
        if($resolved -ne $runRoot -or -not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
           (Split-Path -Leaf $resolved) -ne "c1_c39_onehot_trained_host_$RunId"){throw 'unsafe private cleanup path'}
        $peers=@(Get-Process -Name xsim,xsimk,xelab,xvlog,vvp,iverilog,ivl,efx_map,efx_pnr,efx_sta -ErrorAction SilentlyContinue)
        if($peers.Count -or -not $safeCleanup){throw 'tools still alive or exit unverified; private files retained'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }catch{$state='failed';$step='cleanup';$exitCode=1;$message=$_.Exception.Message}
    finally {
        Save-State
        if($budgetLease){if($budgetOwned){$budgetLease.ReleaseMutex()};$budgetLease.Dispose()}
    }
}
exit $exitCode
