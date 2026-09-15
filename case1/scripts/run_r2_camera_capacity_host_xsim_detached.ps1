<## WMI-detached C29 graph simulation. Only bounded logs survive; vectors,
snapshot and optional simulator-created databases are private and removed.
MemoryDiv=2 grants at most one aggregate read/write 128b service per 2 clocks.
##>
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='', [int]$FrameWidth=12,[int]$FrameHeight=12,
      [ValidateSet('microstyle24','drop_res1')][string]$Profile='microstyle24',[int]$MemoryDiv=2,[int]$CommandLatency=20,[int]$Stalls=0,[int]$AwWaitW=0,[int]$NnTarget=6,[int]$TimeoutSeconds=600)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -eq ''){$RunId=[guid]::NewGuid().ToString('N')}
if($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $FrameWidth -lt 4 -or $FrameWidth -gt 640 -or $FrameWidth%4 -ne 0 -or $FrameHeight -lt 4 -or $FrameHeight -gt 480 -or $FrameHeight%4 -ne 0 -or $MemoryDiv -lt 0 -or $CommandLatency -lt 0 -or $TimeoutSeconds -lt 1){throw 'invalid run/configuration'}
if($Stalls -notin @(0,1) -or $AwWaitW -notin @(0,1,2)){throw 'invalid AXI wait profile'}
if($NnTarget -lt 2 -or $NnTarget -gt 6){throw 'NnTarget must be 2..6'}
if(($FrameWidth -gt 32 -or $FrameHeight -gt 32) -and ($FrameWidth -ne 640 -or $FrameHeight -ne 480)){throw 'supported shapes: small functional or native 640x480'}
$runLog=Join-Path $caseRoot "logs\r2_camera_capacity_host_xsim_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'RunId already exists'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId -FrameWidth $FrameWidth -FrameHeight $FrameHeight -MemoryDiv $MemoryDiv -CommandLatency $CommandLatency -Stalls $Stalls -AwWaitW $AwWaitW -NnTarget $NnTarget -TimeoutSeconds $TimeoutSeconds -Profile $Profile"
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
$runRoot=Join-Path $simRoot "c1_r2_camera_capacity_host_xsim_$RunId"
if(Test-Path -LiteralPath $runRoot){throw 'private directory already exists'}
New-Item -ItemType Directory -Path $runRoot,$runLog|Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew()
$vivado='D:\vivado\vivado\Vivado\2023.1\bin'
$python='D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
$env:TEMP=Join-Path $runRoot 'tmp';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Path $env:TEMP|Out-Null
$workerInJob=$null
$runState='running';$runStep='prepare';$runExit=0;$runMessage='detached C29 graph simulation'
function Save-State {
    [ordered]@{run_id=$RunId;state=$runState;step=$runStep;exit_code=$runExit;message=$runMessage;worker_pid=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);run_directory=$runRoot;width=$FrameWidth;height=$FrameHeight;memory_div=$MemoryDiv;command_latency=$CommandLatency;
        camera_backpressure_allowed=$false;actual_roi=$true;native_timing=($FrameWidth -eq 640 -and $FrameHeight -eq 480);performance_claim=$false;stalls=$Stalls;aw_wait_w=$AwWaitW;nn_target=$NnTarget;profile=$Profile;simulator_directory_present=(Test-Path -LiteralPath $runRoot);worker_in_windows_job=$workerInJob}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
}
function Invoke-Step([string]$Name,[string]$Executable,[string[]]$Arguments) {
    $script:runStep=$Name;Save-State
    $stdout=Join-Path $runRoot "$Name.stdout.log";$stderr=Join-Path $runRoot "$Name.stderr.log"
    # Vivado .bat argument forwarding treats unquoted '=' as a separator.
    # Preserve generic_top and testplusarg NAME=VALUE as single tokens.
    $quotedArguments=@($Arguments|ForEach-Object {if($_.Contains('"')){throw 'unexpected quote in step argument'};'"'+$_+'"'})
    $p=Start-Process -FilePath $Executable -ArgumentList $quotedArguments -WorkingDirectory $runRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    try {
        # Pin the native handle before asynchronous exit. Without this,
        # Windows PowerShell can expose a null ExitCode after WaitForExit.
        $stepHandle=$p.Handle
        if(-not $p.WaitForExit($TimeoutSeconds*1000)) {
            # Exact still-live child handle owned by this step; kill its tree
            # before deleting the private directory. Never kill by tool name.
            & taskkill.exe /PID $p.Id /T /F | Out-Null
            throw "$Name exceeded execution limit"
        }
        # Future runs also wait for redirected output callbacks. The timed
        # process wait alone can race the last PASS/PLAN line on readback.
        $p.WaitForExit()
        $stepExit=$p.ExitCode
        $tail=@(Get-Content -LiteralPath $stdout -Tail 70 -ErrorAction SilentlyContinue)+@(Get-Content -LiteralPath $stderr -Tail 30 -ErrorAction SilentlyContinue)
        $tail|Set-Content -LiteralPath (Join-Path $runLog "$Name.tail.log") -Encoding UTF8
        if($null -eq $stepExit -or $stepExit -ne 0 -or ($tail -join "`n") -match '(?im)FATAL|ERROR:|RuntimeError|Traceback'){throw "$Name failed (exit=$stepExit)"}
        if($Name -eq 'xsim') {
            $markers=@(Get-Content -LiteralPath $stdout | Where-Object {$_ -match '^C1_R2_CAMERA_CAPACITY_HOST_SYSTEM_'})
            $markers|Set-Content -LiteralPath (Join-Path $runLog 'result.log') -Encoding UTF8
            if(@($markers|Where-Object {$_ -match '^C1_R2_CAMERA_CAPACITY_HOST_SYSTEM_PASS '}).Count -ne 1){throw 'missing graph pass marker'}
        }
    } finally {$p.Dispose()}
}
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C29JobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C29JobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'Cannot verify Windows Job isolation'}
    $workerInJob=$jobValue
    if($workerInJob){throw 'Worker is in a Windows Job; refusing to launch Vivado'}
    Save-State
    Invoke-Step 'vectors' $python @('-B','-u',(Join-Path $caseRoot 'golden\generate_r2_camera_host_xsim_vectors.py'),'--output',$runRoot,'--width',"$FrameWidth",'--height',"$FrameHeight",'--profile',$Profile)
    $meta=Get-Content -LiteralPath (Join-Path $runRoot 'metadata.json') -Raw|ConvertFrom-Json
    $meta|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runLog 'metadata.json') -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $runRoot 'package\manifest.json') -Destination (Join-Path $runLog 'plan_manifest.json')
    Copy-Item -LiteralPath (Join-Path $runRoot 'package\execution_plan.sv') -Destination (Join-Path $runLog 'execution_plan.sv')
    [xml]$project=Get-Content -LiteralPath (Join-Path $caseRoot 'efinity\c1_ti60_r2_camera_capacity96.xml') -Raw
    $sources=@($project.SelectNodes("//*[local-name()='design_file']")|Where-Object {$_.name -ne 'c1_ti60_r2_camera_capacity96.sv' -and (Split-Path -Leaf $_.name) -ne 'execution_plan.sv'}|ForEach-Object {Join-Path (Join-Path $caseRoot 'efinity') $_.name})
    $sources += (Join-Path $runRoot 'package\execution_plan.sv')
    $top='tb_c1_r2_camera_capacity_host_system';$bankWords=if($FrameWidth*$FrameHeight -gt 8192){524288}else{16384}
    $cycleLimit=[math]::Max(60000000,($NnTarget+2)*15000000)
    Invoke-Step 'xvlog' (Join-Path $vivado 'xvlog.bat') (@('-sv')+$sources+(Join-Path $caseRoot 'sim\c1_r2_axi_memory_bfm.sv')+(Join-Path $caseRoot 'sim\c1_r2_axi_traffic_agent.sv')+(Join-Path $caseRoot "sim\$top.sv"))
    $camera=$meta.sources[0]
    $cameraGenerics=@()
    foreach($mapping in @(@('CAMERA_SW','width'),@('CAMERA_SH','height'),@('CAMERA_RX','roi_x'),@('CAMERA_RY','roi_y'),@('CAMERA_RW','roi_width'),@('CAMERA_RH','roi_height'))){
        $cameraGenerics += @('-generic_top',"$($mapping[0])=$($camera.($mapping[1]))")
    }
    Invoke-Step 'xelab' (Join-Path $vivado 'xelab.bat') (@($top,'-s','r2_camera_capacity_host_sim','-generic_top',"BANK_WORDS=$bankWords",'-generic_top',"WIDTH=$FrameWidth",'-generic_top',"HEIGHT=$FrameHeight",'-generic_top',"MAX_CYCLES=$cycleLimit",'-generic_top',"NN_TARGET=$NnTarget",'-generic_top',"STAGE_COUNT=$($meta.stage_count)",'-generic_top',"RGB_STAGE=$($meta.rgb_stage)",'-generic_top',"MEMORY_DIV=$MemoryDiv",'-generic_top',"COMMAND_LATENCY=$CommandLatency",'-generic_top',"STALLS=$Stalls",'-generic_top',"AW_WAIT_W=$AwWaitW",'-mt','2')+$cameraGenerics)
    $vectorsPath=$runRoot.Replace('\','/')
    $sourceArgs=@()
    for($i=0;$i -lt 2;$i++){
        $source=$meta.sources[$i]
        foreach($mapping in @(@('SW','width'),@('SH','height'),@('XS','xs'),@('YS','ys'),@('XP','xp'),@('YP','yp'))){
            $sourceArgs += @('-testplusarg',"$($mapping[0])$i=$($source.($mapping[1]))")
        }
    }
    Invoke-Step 'xsim' (Join-Path $vivado 'xsim.bat') (@('r2_camera_capacity_host_sim','-runall','-testplusarg',"DIR=$vectorsPath",'-testplusarg',"P=$($meta.parameter_words)",'-testplusarg',"I=$($meta.input_words)",'-testplusarg',"E=$($meta.expected_words)")+$sourceArgs)
    $runState='complete';$runStep='done';$runMessage='graph simulation passed'
} catch {$runState='failed';$runStep='error';$runExit=1;$runMessage=$_.Exception.Message}
finally {
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne "c1_r2_camera_capacity_host_xsim_$RunId"){throw 'unsafe cleanup target'}
    try {
        for($cleanupAttempt=0;$cleanupAttempt -lt 6;$cleanupAttempt++) {
            try {
                if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
                break
            } catch {
                if($cleanupAttempt -eq 5){throw}
                Start-Sleep -Milliseconds 500
            }
        }
    } catch {
        $runState='failed';$runStep='cleanup';$runExit=1;$runMessage='Private cleanup failed: '+$_.Exception.Message
    } finally {Save-State}
}
exit $runExit
