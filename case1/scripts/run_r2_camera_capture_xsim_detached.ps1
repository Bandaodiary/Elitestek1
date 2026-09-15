<## WMI-detached C25 camera/Resize/Capture simulation, without CNN. Only bounded logs survive; vectors,
snapshot and optional simulator-created databases are private and removed.
MemoryDiv=2 grants at most one aggregate read/write 128b service per 2 clocks.
##>
[CmdletBinding()]
param([switch]$Worker,[switch]$Native,[switch]$ExpectOverflow,[string]$RunId='', [int]$FifoDepth=0,
      [int]$Stalls=0,[int]$TimeoutSeconds=1200)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -eq ''){$RunId=[guid]::NewGuid().ToString('N')}
if($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $TimeoutSeconds -lt 1 -or $Stalls -notin @(0,1)){throw 'invalid run/configuration'}
if($FifoDepth -eq 0){$FifoDepth=if($Native){1024}else{64}}
if($FifoDepth -lt 2 -or $FifoDepth -gt 8192 -or ($FifoDepth -band ($FifoDepth-1)) -ne 0){throw 'invalid FIFO depth'}
$runLog=Join-Path $caseRoot "logs\r2_camera_capture_xsim_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'RunId already exists'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $nativeFlag=if($Native){' -Native'}else{''}
    if($ExpectOverflow){$nativeFlag+=' -ExpectOverflow'}
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId -FifoDepth $FifoDepth -Stalls $Stalls -TimeoutSeconds $TimeoutSeconds$nativeFlag"
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
$runRoot=Join-Path $simRoot "c1_r2_camera_capture_xsim_$RunId"
if(Test-Path -LiteralPath $runRoot){throw 'private directory already exists'}
New-Item -ItemType Directory -Path $runRoot,$runLog|Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew()
$vivado='D:\vivado\vivado\Vivado\2023.1\bin'
$python='D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
$env:TEMP=Join-Path $runRoot 'tmp';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Path $env:TEMP|Out-Null
$workerInJob=$null
$runState='running';$runStep='prepare';$runExit=0;$runMessage='detached C25 camera/Resize/Capture simulation'
function Save-State {
    [ordered]@{run_id=$RunId;state=$runState;step=$runStep;exit_code=$runExit;message=$runMessage;worker_pid=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);run_directory=$runRoot;
        native_shape=[bool]$Native;expected_overflow=[bool]$ExpectOverflow;fifo_depth=$FifoDepth;stalls=$Stalls;source_backpressure_allowed=$false;
        cnn_performance_claim=$false;simulator_directory_present=(Test-Path -LiteralPath $runRoot);worker_in_windows_job=$workerInJob}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
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
        $stepExit=$p.ExitCode
        $tail=@(Get-Content -LiteralPath $stdout -Tail 70 -ErrorAction SilentlyContinue)+@(Get-Content -LiteralPath $stderr -Tail 30 -ErrorAction SilentlyContinue)
        $tail|Set-Content -LiteralPath (Join-Path $runLog "$Name.tail.log") -Encoding UTF8
        if($null -eq $stepExit -or $stepExit -ne 0 -or ($tail -join "`n") -match '(?im)FATAL|ERROR:|RuntimeError|Traceback'){throw "$Name failed (exit=$stepExit)"}
        if($Name -eq 'xsim') {
            $markers=@(Get-Content -LiteralPath $stdout | Where-Object {$_ -match '^C1_R2_CAMERA_CAPTURE_|^C1_R2_CAMERA_SOURCE_PROFILE '})
            $markers|Set-Content -LiteralPath (Join-Path $runLog 'result.log') -Encoding UTF8
            if(@($markers|Where-Object {$_ -match '^C1_R2_CAMERA_CAPTURE_PASS '}).Count -ne 1){throw 'missing capture pass marker'}
        }
    } finally {$p.Dispose()}
}
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C25JobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C25JobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'Cannot verify Windows Job isolation'}
    $workerInJob=$jobValue
    if($workerInJob){throw 'Worker is in a Windows Job; refusing to launch Vivado'}
    Save-State
    $vectorArgs=@('-B','-u',(Join-Path $caseRoot 'golden\run_r2_camera_capture_probe.py'),'--vectors-only',$runRoot,'--fifo',"$FifoDepth")
    if($Native){$vectorArgs += '--native'}
    if($ExpectOverflow){$vectorArgs += '--expect-overflow'}
    Invoke-Step 'vectors' $python $vectorArgs
    $meta=Get-Content -LiteralPath (Join-Path $runRoot 'metadata.json') -Raw|ConvertFrom-Json
    $meta|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runLog 'metadata.json') -Encoding UTF8
    [xml]$project=Get-Content -LiteralPath (Join-Path $caseRoot 'efinity\c1_ti60_r2_camera_capture.xml') -Raw
    $sources=@($project.SelectNodes("//*[local-name()='design_file']")|Where-Object {$_.name -ne 'c1_ti60_r2_camera_capture.sv'}|ForEach-Object {Join-Path (Join-Path $caseRoot 'efinity') $_.name})
    $top='tb_c1_r2_camera_capture'
    Invoke-Step 'xvlog' (Join-Path $vivado 'xvlog.bat') (@('-sv')+$sources+(Join-Path $caseRoot 'sim\c1_r2_axi_memory_bfm.sv')+(Join-Path $caseRoot "sim\$top.sv"))
    $genericArgs=@()
    foreach($property in $meta.parameters.PSObject.Properties){$genericArgs+=@('-generic_top',"$($property.Name)=$($property.Value)")}
    $genericArgs+=@('-generic_top',"STALLS=$Stalls")
    Invoke-Step 'xelab' (Join-Path $vivado 'xelab.bat') (@($top,'-s','r2_camera_capture_sim','-mt','2')+$genericArgs)
    $vectorsPath=$runRoot.Replace('\','/')
    $plusArgs=@()
    foreach($property in $meta.plusargs.PSObject.Properties){$plusArgs+=@('-testplusarg',"$($property.Name)=$($property.Value)")}
    Invoke-Step 'xsim' (Join-Path $vivado 'xsim.bat') (@('r2_camera_capture_sim','-runall','-testplusarg',"DIR=$vectorsPath")+$plusArgs)
    $runState='complete';$runStep='done';$runMessage='camera/Resize/Capture simulation passed; CNN not included'
} catch {$runState='failed';$runStep='error';$runExit=1;$runMessage=$_.Exception.Message}
finally {
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne "c1_r2_camera_capture_xsim_$RunId"){throw 'unsafe cleanup target'}
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
