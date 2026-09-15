<## C23 WMI-detached banked Resize test. No waves; private files removed. ##>
[CmdletBinding()]
param([switch]$Worker,[string]$RunId='', [ValidateSet(0,1)][int]$RegisterAbortReset=1,[int]$TimeoutSeconds=180)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -eq ''){$RunId=[guid]::NewGuid().ToString('N')}
if($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $TimeoutSeconds -lt 1){throw 'invalid run/configuration'}
$runLog=Join-Path $caseRoot "logs\r2_resize_xsim_runs\$RunId"
$statusPath=Join-Path $runLog 'status.json'
if(-not $Worker){
    if(Test-Path -LiteralPath $runLog){throw 'RunId already exists'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $command="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId -RegisterAbortReset $RegisterAbortReset -TimeoutSeconds $TimeoutSeconds"
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
$runRoot=Join-Path $simRoot "c1_r2_resize_xsim_$RunId"
if(Test-Path -LiteralPath $runRoot){throw 'private directory already exists'}
New-Item -ItemType Directory -Path $runRoot,$runLog|Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew()
$vivado='D:\vivado\vivado\Vivado\2023.1\bin'
$env:TEMP=Join-Path $runRoot 'tmp';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Path $env:TEMP|Out-Null
$workerInJob=$null
$runState='running';$runStep='prepare';$runExit=0;$runMessage='detached C23 Resize simulation'
function Save-State {
    [ordered]@{run_id=$RunId;state=$runState;step=$runStep;exit_code=$runExit;message=$runMessage;worker_pid=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);run_directory=$runRoot;registered_abort_reset=$RegisterAbortReset;
        simulator_directory_present=(Test-Path -LiteralPath $runRoot);worker_in_windows_job=$workerInJob}|ConvertTo-Json|Set-Content -LiteralPath $statusPath -Encoding UTF8
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
            $markers=@(Get-Content -LiteralPath $stdout | Where-Object {$_ -match '^C1_(R2_RESIZE_PIPELINE_|RESIZE_)'})
            $markers|Set-Content -LiteralPath (Join-Path $runLog 'result.log') -Encoding UTF8
            if(@($markers|Where-Object {$_ -match '^C1_R2_RESIZE_PIPELINE_PASS '}).Count -ne 1){throw 'missing Resize pass marker'}
        }
    } finally {$p.Dispose()}
}
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C23ResizeJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue=$false
    if(-not [C23ResizeJobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)){throw 'Cannot verify Windows Job isolation'}
    $workerInJob=$jobValue
    if($workerInJob){throw 'Worker is in a Windows Job; refusing to launch Vivado'}
    Save-State
    $python='D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe'
    Invoke-Step 'vectors' $python @('-B','-u',(Join-Path $caseRoot 'golden/run_r2_resize_probe.py'),'--vectors-only',$runRoot)
    $top='tb_c1_r2_resize_pipeline'
    $sources=@('rtl/common/c1_ram_sdp_read_first.sv','rtl/video/r1_resize_request_q16.sv',
        'rtl/video/r1_bilinear_interp_rgb888.sv','rtl/video/c1_r1_resize_system.sv',
        'rtl/r2/c1_r2_resize_pair_ram.sv','rtl/r2/c1_r2_resize_line_sampler.sv',
        'rtl/r2/c1_r2_resize_pipeline.sv','sim/tb_c1_r2_resize_pipeline.sv')|ForEach-Object {Join-Path $caseRoot $_}
    $options=@('-sv')
    if($RegisterAbortReset -eq 1){$options+=@('-d','C1_REGISTER_ABORT_RESET')}
    Invoke-Step 'xvlog' (Join-Path $vivado 'xvlog.bat') ($options+$sources)
    Invoke-Step 'xelab' (Join-Path $vivado 'xelab.bat') @($top,'-s','r2_resize_sim','-mt','2')
    Invoke-Step 'xsim' (Join-Path $vivado 'xsim.bat') @('r2_resize_sim','-runall')
    $runState='complete';$runStep='done';$runMessage='Resize simulation passed'
} catch {$runState='failed';$runStep='error';$runExit=1;$runMessage=$_.Exception.Message}
finally {
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if(-not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne "c1_r2_resize_xsim_$RunId"){throw 'unsafe cleanup target'}
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
