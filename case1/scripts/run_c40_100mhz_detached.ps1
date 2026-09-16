param([switch]$Worker,[string]$RunId='c40_100mhz_smoke_20260916a',[ValidateSet('smoke','cpu','full','full_four','matrix','native','capture','capture_full')][string]$Phase='smoke',[string]$PrerequisiteRun='')
$ErrorActionPreference='Stop'
if($RunId -notmatch '^[A-Za-z0-9_]+$'){throw 'Invalid run ID'}
if($PrerequisiteRun -and $PrerequisiteRun -notmatch '^[A-Za-z0-9_]+$'){throw 'Invalid prerequisite ID'}
if($Phase -eq 'full_four' -and -not $PrerequisiteRun){throw 'Four-row full flow requires full capture evidence'}
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$log=Join-Path $caseRoot "logs/c40_100mhz_runs/$RunId"
if(Test-Path -LiteralPath $log){throw 'Run already exists; inspect its original status'}
if(-not $Worker){
    $shell="$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe"
    $line="`"$shell`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -Phase $Phase"
    if($PrerequisiteRun){$line+=" -PrerequisiteRun $PrerequisiteRun"}
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$line;CurrentDirectory=$caseRoot}
    if($r.ReturnValue){throw 'Detached WMI launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$r.ProcessId;status_path="$log/status.json"}|ConvertTo-Json -Compress
    exit 0
}
New-Item -ItemType Directory -Path $log | Out-Null
$self=Get-Process -Id $PID
$self.ProcessorAffinity=[IntPtr]3;$self.PriorityClass='BelowNormal'
$workerStart=$self.StartTime.ToString('o');$state='waiting';$message='Waiting for EDA and memory admission';$code=$null;$child=$null
$workerInJob=$null;$childInJob=$null;$childStart=$null
function Save-State {
    [ordered]@{run_id=$RunId;state=$state;message=$message;exit_code=$code;
        worker_pid=$PID;worker_start=$workerStart;worker_in_windows_job=$workerInJob;
        child_pid=$(if($child){$child.Id}else{$null});child_start=$childStart;child_in_windows_job=$childInJob;
        phase=$Phase;actual_CPU_IP=($Phase -eq 'cpu' -and $state -eq 'complete');native_fps_measured=$false;heartbeat=(Get-Date).ToString('o')}|
        ConvertTo-Json|Set-Content -LiteralPath "$log/status.json" -Encoding UTF8
}
try {
    Add-Type 'using System; using System.Runtime.InteropServices; public class C40Job { [DllImport("kernel32.dll")] public static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool r); }'
    $workerInJob=$false
    if(-not [C40Job]::IsProcessInJob($self.Handle,[IntPtr]::Zero,[ref]$workerInJob) -or $workerInJob){throw 'Worker is in a Windows Job'}
    if($PrerequisiteRun){
        $priorPath=Join-Path $caseRoot "logs/c40_100mhz_runs/$PrerequisiteRun/status.json"
        while($true){
            $prior=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json
            if($prior.state -eq 'complete' -and $prior.exit_code -eq 0 -and $prior.phase -eq 'capture_full'){break}
            if($prior.state -notin @('waiting','running')){throw 'Required full capture did not pass'}
            $priorProcess=Get-Process -Id $prior.worker_pid -ErrorAction SilentlyContinue
            if(-not $priorProcess -or $priorProcess.StartTime.ToString('o') -ne $prior.worker_start){throw 'Prerequisite worker is no longer live'}
            $message='Waiting for live full capture prerequisite';Save-State;Start-Sleep -Seconds 10
        }
    }
    while($true){
        $peers=@(Get-Process -Name efx_map,efx_pnr,efx_sta,xsim,xsimk,xelab,xvlog,vvp,ivl,vsim,vsimk -ErrorAction SilentlyContinue)
        $free=[long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
        Save-State
        if(-not $peers.Count -and $free -ge 8388608){break}
        Start-Sleep -Seconds 10
    }
    $python='D:/miniconda/miniconda/envs/SWPC_ENV/python.exe'
    $env:OMP_NUM_THREADS='2';$env:MKL_NUM_THREADS='2';$env:OPENBLAS_NUM_THREADS='2';$env:PYTHONDONTWRITEBYTECODE='1'
    $probe=if($Phase -in @('capture','capture_full')){'run_c40_capture_diagnostic.py'}elseif($Phase -eq 'cpu'){'run_c40_sapphire_boot.py'}elseif($Phase -in @('full','full_four','matrix','native')){'run_c40_iverilog_pipeline.py'}else{'run_c40_100mhz_smoke.py'}
    $arguments="-X utf8 -B -u `"$caseRoot/golden/$probe`" --log-dir `"$log`""
    if($Phase -in @('full','matrix','native')){$arguments+=" --scope $Phase"}
    if($Phase -eq 'capture_full'){$arguments+=' --full-frames'}
    if($Phase -eq 'full_four'){$arguments+=" --scope full --four-rows --capture-evidence $PrerequisiteRun"}
    $child=Start-Process -FilePath $python -ArgumentList $arguments -WorkingDirectory $caseRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput "$log/stdout.log" -RedirectStandardError "$log/stderr.log"
    $childStart=$child.StartTime.ToString('o');$childInJob=$false
    if(-not [C40Job]::IsProcessInJob($child.Handle,[IntPtr]::Zero,[ref]$childInJob) -or $childInJob){throw 'Child is in a Windows Job'}
    $state='running';$message="Running 100MHz $Phase verification";Save-State
    while(-not $child.WaitForExit(5000)){Save-State}
    $child.WaitForExit();$code=$child.ExitCode
    $marker=if($Phase -in @('capture','capture_full')){'C40_CAPTURE_DIAGNOSTIC_DONE temporary_removed=1 actual_CPU_IP=0'}elseif($Phase -eq 'cpu'){'C40_SAPPHIRE_BOOT_PASS temporary_removed=1 actual_CPU_IP=1'}elseif($Phase -eq 'full_four'){'C40_ICARUS_PIPELINE_PASS scope=full temporary_removed=1 actual_CPU_IP=0'}elseif($Phase -in @('full','matrix','native')){"C40_ICARUS_PIPELINE_PASS scope=$Phase temporary_removed=1 actual_CPU_IP=0"}else{'C40_100MHZ_SMOKE_PASS temporary_removed=1 actual_CPU_IP=0'}
    if($code -ne 0 -or (Get-Content "$log/stdout.log" -Tail 1) -ne $marker){throw 'Verification failed; see retained small logs'}
    $state='complete';$message="100MHz $Phase verification passed; full joint throughput still unmeasured";Save-State
}catch{
    $state=if($child -and -not $child.HasExited){'observation_failed_child_live'}else{'failed'}
    $message=$_.Exception.Message;Save-State;exit 1
}finally{if($child){$child.Dispose()};$self.Dispose()}
