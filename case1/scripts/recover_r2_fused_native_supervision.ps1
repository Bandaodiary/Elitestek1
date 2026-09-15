# C35 recovery of lost supervision, NEVER restart/terminate the live simulator.
[CmdletBinding()]
param([switch]$Worker)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$run='c35_fused_native_sixframe_20260915_a'
$folder=Join-Path $caseRoot "logs\r2_fused_rgb2_host_xsim_runs\$run"
$statusPath=Join-Path $folder 'status.json'
$recoveryPath=Join-Path $folder 'supervision_recovery.json'
$s=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$expected=Join-Path $simRoot "c1_r2_fused_rgb2_host_xsim_$run"
if($s.run_id -ne $run -or [IO.Path]::GetFullPath($s.run_directory) -ne $expected -or
   $s.worker_pid -ne 35892 -or $s.step_pid -ne 21688 -or $s.state -ne 'running' -or $s.step -ne 'xsim'){
    throw 'unexpected original simulation identity/state'
}
function Check-OldWorkerAbsent {
    $old=Get-Process -Id $s.worker_pid -ErrorAction SilentlyContinue
    if($old){try{
        if($old.StartTime.ToUniversalTime().Ticks -eq ([DateTime]::Parse($s.worker_start)).ToUniversalTime().Ticks){
            throw 'original worker is still alive; do not interfere'
        }
    }finally{$old.Dispose()}}
}
Check-OldWorkerAbsent
if(-not $Worker){
    if(Test-Path -LiteralPath $recoveryPath){throw 'recovery already registered'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw 'WMI recovery launch failed'}
    [ordered]@{run_id=$run;recovery_pid=$r.ProcessId;recovery_path=$recoveryPath;restarts_simulation=$false;terminates_simulation=$false}|ConvertTo-Json -Compress
    exit 0
}
if(Test-Path -LiteralPath $recoveryPath){throw 'recovery already initialized'}
$env:TEMP=Join-Path $expected 'tmp';$env:TMP=$env:TEMP
$watch=[Diagnostics.Stopwatch]::StartNew();$start=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$inJob=$null;$state='preparing';$message='pinning original live simulator tree';$handles=@();$inventory=@()
$cmdExit=$null;$kernelExit=$null;$changedStatus=$false
function Save-Recovery {
    [ordered]@{run_id=$run;state=$state;message=$message;recovery_pid=$PID;recovery_start=$start;
        recovery_in_windows_job=$inJob;original_worker_pid=$s.worker_pid;original_worker_missing=$true;
        tracked_processes=$inventory;cmd_exit_code=$cmdExit;kernel_exit_code=$kernelExit;
        changed_original_status=$changedStatus;restarted_simulation=$false;terminated_simulation=$false;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3)}|ConvertTo-Json -Depth 5|
        Set-Content -LiteralPath $recoveryPath -Encoding UTF8
}
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C35RecoveryJob {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool result);
}
'@
    $current=[Diagnostics.Process]::GetCurrentProcess();$job=$false
    if(-not [C35RecoveryJob]::IsProcessInJob($current.Handle,[IntPtr]::Zero,[ref]$job)){throw 'cannot verify recovery Job'}
    $inJob=$job;if($inJob){throw 'recovery is bound to a Windows Job'}
    $current.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
    [long]$allowed=$current.ProcessorAffinity.ToInt64();[long]$mask=0;$count=0
    for($bit=0;$bit -lt 63 -and $count -lt 2;$bit++){
        [long]$candidate=[long]1 -shl $bit
        if($allowed -band $candidate){$mask=$mask -bor $candidate;$count++}
    }
    if(-not $count){throw 'no available CPU'};$current.ProcessorAffinity=[IntPtr]$mask
    $tree=@(Get-CimInstance Win32_Process -Filter 'ProcessId=21688 OR ProcessId=40416 OR ProcessId=29412')
    $specs=@(@(21688,35892,'cmd'),@(40416,21688,'xsim'),@(29412,40416,'xsimk'))
    foreach($spec in $specs){
        $meta=@($tree|Where-Object {$_.ProcessId -eq $spec[0]})
        if($meta.Count -ne 1 -or $meta[0].ParentProcessId -ne $spec[1] -or $meta[0].Name -ne ($spec[2]+'.exe')){throw 'original live tree changed; no cleanup'}
        $p=Get-Process -Id $spec[0] -ErrorAction Stop;$handle=$p.Handle
        if($p.ProcessName -ne $spec[2]){throw 'process identity changed'}
        if($spec[0] -eq 21688 -and $p.StartTime.ToUniversalTime().Ticks -ne ([DateTime]::Parse($s.step_start)).ToUniversalTime().Ticks){throw 'original step PID reused'}
        $handles+=$p;$inventory+=[ordered]@{pid=$p.Id;name=$p.ProcessName;start=$p.StartTime.ToString('o');parent=$spec[1]}
    }
    $state='waiting';$message='original cmd/xsim/xsimk handles pinned; no simulator restart';Save-Recovery
    foreach($p in $handles){
        while(-not $p.WaitForExit(5000)){
            if($watch.Elapsed.TotalHours -ge 8){throw 'observation deadline; live simulation and directory left intact'}
        }
    }
    $cmdExit=$handles[0].ExitCode;$kernelExit=$handles[2].ExitCode
    Check-OldWorkerAbsent
    $outPath=Join-Path $expected 'xsim.stdout.log';$errPath=Join-Path $expected 'xsim.stderr.log'
    if((Get-Item -LiteralPath $outPath).Length -gt 1048576 -or (Get-Item -LiteralPath $errPath).Length -gt 131072){throw 'unexpected log size; preserve private evidence'}
    $out=Get-Content -LiteralPath $outPath -Raw;$err=Get-Content -LiteralPath $errPath -Raw
    $lines=@($out -split '\r?\n');$errors=@($err -split '\r?\n')
    @($lines|Select-Object -Last 70)+@($errors|Select-Object -Last 30)|Set-Content -LiteralPath (Join-Path $folder 'xsim.tail.log') -Encoding UTF8
    @($lines|Where-Object {$_ -match '^Running: .*xsim.exe '})|Set-Content -LiteralPath (Join-Path $folder 'xsim.invocation.log') -Encoding UTF8
    $markers=@($lines|Where-Object {$_ -match '^C1_R2_FUSED_RGB2_HOST_SYSTEM_'})
    $markers|Set-Content -LiteralPath (Join-Path $folder 'result.log') -Encoding UTF8
    $passed=($null -ne $cmdExit -and $cmdExit -eq 0 -and $null -ne $kernelExit -and $kernelExit -eq 0 -and
        @($markers|Where-Object {$_ -match '^C1_R2_FUSED_RGB2_HOST_SYSTEM_PASS '}).Count -eq 1 -and
        ($out+$err) -notmatch '(?im)FATAL|ERROR:|RuntimeError|Traceback')
    # Delete only the exact private simulator directory after all pinned
    # native handles are signaled. Never kill any process or clear by glob.
    $resolved=(Resolve-Path -LiteralPath $expected).Path
    if($resolved -ne $expected -or -not $resolved.StartsWith($simRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe cleanup target'}
    if(@($handles|Where-Object {-not $_.WaitForExit(0)}).Count){throw 'pinned process alive; no cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
    $s.state=if($passed){'complete'}else{'failed'};$s.step=if($passed){'done'}else{'error'}
    $s.exit_code=if($passed){0}else{1};$s.message='original simulation completed; supervision recovered without restart'
    $s.elapsed_seconds=[math]::Round(([DateTime]::UtcNow-([DateTime]::Parse($s.worker_start)).ToUniversalTime()).TotalSeconds,3)
    $s.simulator_directory_present=Test-Path -LiteralPath $expected
    $s|Add-Member -NotePropertyName completion_recovered -NotePropertyValue $true
    $s|Add-Member -NotePropertyName recovery_pid -NotePropertyValue $PID
    $s|Add-Member -NotePropertyName recovery_start -NotePropertyValue $start
    $s|Add-Member -NotePropertyName recovery_in_windows_job -NotePropertyValue $inJob
    $s|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $statusPath -Encoding UTF8
    $changedStatus=$true;$state='complete';$message='actual simulator exits recorded; compact evidence retained; private directory removed'
}catch{$state='failed';$message=$_.Exception.Message}
finally{Save-Recovery;foreach($p in $handles){$p.Dispose()}}
if($state -ne 'complete'){exit 1}
