[CmdletBinding()]
param(
    [string]$RunId='c40_100mhz_xsim_four_20260916b',
    [int]$IntervalSeconds=600,
    [int]$ExpectedWorkerPid=41956
)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$run=Join-Path $caseRoot "logs\c40_100mhz_xsim_runs\$RunId"
$statusPath=Join-Path $run 'status.json'
$samplesPath=Join-Path $run 'monitor.samples.v2.jsonl'
$donePath=Join-Path $run 'monitor.done.json'
if($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $IntervalSeconds -lt 60){throw 'invalid monitor parameters'}
if(-not (Test-Path -LiteralPath $run)){throw 'run directory missing'}
$missingCount=0
while($true){
    $status=$null
    if(Test-Path -LiteralPath $statusPath){
        try{$status=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json}catch{}
    }
    $worker=Get-Process -Id $ExpectedWorkerPid -ErrorAction SilentlyContinue
    $xsim=@(Get-Process xsim -ErrorAction SilentlyContinue|Select-Object Id,StartTime,CPU,WorkingSet64)
    if($worker){$missingCount=0}else{$missingCount++}
    $tail=@()
    $stdout=Join-Path $run 'xsim.stdout.log'
    if(Test-Path -LiteralPath $stdout){
        $tail=@(Get-Content -LiteralPath $stdout -Tail 80|Where-Object {
            $_ -match '^(C40_PROGRESS|C40_CLOCK_PASS|C1_R2_FUSED_RGB2_HOST_SYSTEM_(PROGRESS|CAMERA_RESULT|CAPTURE|STAGE|PASS))'
        }|Select-Object -Last 12|ForEach-Object {[string]$_})
    }
    $sample=[ordered]@{
        timestamp=(Get-Date).ToString('o');run_id=$RunId;
        state=if($status){$status.state}else{'status_unreadable'};
        step=if($status){$status.step}else{$null};elapsed_seconds=if($status){$status.elapsed_seconds}else{$null};
        worker_pid=$ExpectedWorkerPid;worker_alive=[bool]$worker;worker_missing_samples=$missingCount;
        xsim_processes=$xsim;key_tail=$tail
    }
    ($sample|ConvertTo-Json -Compress -Depth 5)|Add-Content -LiteralPath $samplesPath -Encoding UTF8
    $terminal=$status -and $status.state -in @('complete','failed')
    $lost=($missingCount -ge 2)
    if($terminal -or $lost){
        $result=[ordered]@{timestamp=(Get-Date).ToString('o');run_id=$RunId;
            terminal_state=if($terminal){$status.state}else{'worker_missing_without_terminal_status'};
            status=$status;last_key_tail=$tail}
        $result|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $donePath -Encoding UTF8
        $message="C40 100MHz xsim monitor finished: $($result.terminal_state). Return to Codex for evidence audit."
        & "$env:SystemRoot\System32\msg.exe" $env:USERNAME $message 2>$null
        break
    }
    Start-Sleep -Seconds $IntervalSeconds
}
