[CmdletBinding()]
param([switch]$Worker,[string]$RunId='c40_production_20260916a')
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$queueLog=Join-Path $caseRoot "logs\c40_production_queue\$RunId"
if(-not $Worker){
    if(Test-Path -LiteralPath $queueLog){throw 'run already exists'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $line="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$line;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw 'WMI stage worker launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$r.ProcessId;status_path=(Join-Path $queueLog 'status.json')}|ConvertTo-Json -Compress
    exit 0
}
New-Item -ItemType Directory -Path $queueLog | Out-Null
$python='D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'
$ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$start=(Get-Date).ToString('o');$stage='preflight';$completed=@()
function State([string]$Value,[string]$Message=''){
    [ordered]@{run_id=$RunId;state=$Value;step=$stage;worker_pid=$PID;worker_start=$start;
        updated=(Get-Date).ToString('o');completed=$completed;message=$Message}|
        ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $queueLog 'status.json') -Encoding UTF8
}
try{
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class C40ProductionJob {[DllImport("kernel32.dll",SetLastError=true)] public static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool result);}
'@
    $inJob=$false
    if(-not [C40ProductionJob]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$inJob) -or $inJob){throw 'queue inherited Windows Job'}
    if(Get-Process xsim,xsimk,xelab,xvlog,vvp,efx_map,efx_pnr -ErrorAction SilentlyContinue){throw 'another EDA task is active'}
    State 'running'
    & $python -B (Join-Path $caseRoot 'golden\c40_production_project.py') 1> (Join-Path $queueLog 'project.log') 2>&1
    if($LASTEXITCODE -ne 0){throw 'project preflight failed'}
    $stage='production_regression';State 'running'
    & $python -X utf8 -B -u (Join-Path $caseRoot 'golden\run_c40_production_regression.py') --run-id $RunId 1> (Join-Path $queueLog 'regression.log') 2>&1
    if($LASTEXITCODE -ne 0){throw 'production regression failed'}
    $completed += $stage
    $stage='efinity_map_pnr_sta';State 'running'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $caseRoot 'scripts\run_efinity_ti60_resource_map_detached.ps1') -Worker -RunId "${RunId}_pnr" -DesignName c1_ti60_c40_host_100 -ProjectInPlace -RunPnr -TimingAudit -TimeoutSeconds 3600 -ScratchRoot (Join-Path $caseRoot 'sim\efinity_scratch') 1> (Join-Path $queueLog 'efinity.log') 2>&1
    if($LASTEXITCODE -ne 0){throw 'Efinity map/PNR/STA failed'}
    $completed += $stage
    $stage='native_six_frame_xsim';State 'running'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $caseRoot 'scripts\run_c40_100mhz_xsim_detached.ps1') -Worker -RunId "${RunId}_native" -RegressionRun $RunId 1> (Join-Path $queueLog 'native.log') 2>&1
    if($LASTEXITCODE -ne 0){throw 'native six-frame xsim failed'}
    $completed += $stage
    $stage='awaiting_evidence_audit';State 'complete'
}catch{
    State 'failed' $_.Exception.Message
    $_|Out-String|Set-Content -LiteralPath (Join-Path $queueLog 'failure.log') -Encoding UTF8
    exit 1
}
