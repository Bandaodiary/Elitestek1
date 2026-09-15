param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$RepeatAbort,
    [switch]$MixedMaintenance,
    [switch]$ColumnCache,
    [switch]$ColumnOwner,
    [switch]$ReadOnLookup,
    [switch]$BeatFifo,
    [switch]$EpochExhaust,
    [switch]$RefillRequestHandoff,
    [ValidateSet(1,2,3)][int]$RefillSkidDepth=2
)

# Detached, compact xsim runner for the real line-cache/exact-reader seam.
# The WMI-launched worker is outside the current Windows job; its private
# xsim tree is removed in finally and only a marker/tail log is retained.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
if($ColumnOwner -and -not $ColumnCache){throw 'ColumnOwner requires ColumnCache'}
if($ReadOnLookup -and -not $ColumnCache){throw 'ReadOnLookup requires ColumnCache'}
if($RefillRequestHandoff -and -not $ColumnCache){throw 'RefillRequestHandoff requires ColumnCache'}
if($ColumnCache -and ($RepeatAbort -or $MixedMaintenance)) {
    throw 'ColumnCache bench already covers both maintenance kinds; do not combine scalar-only flags'
}
if(-not $ColumnCache -and ($BeatFifo -or $EpochExhaust -or $RefillSkidDepth -ne 2)) {
    throw 'BeatFifo/RefillSkidDepth are column-bench options in this runner'
}

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = 'line_cache_exact_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    $runLog = Join-Path $logRoot "xsim_runs\window_line_cache_c8_exact\$RunId"
    $statusPath = Join-Path $runLog 'status.json'
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId -RefillSkidDepth $RefillSkidDepth" +
        $(if($RepeatAbort){' -RepeatAbort'}else{''}) + $(if($MixedMaintenance){' -MixedMaintenance'}else{''}) +
        $(if($ColumnCache){' -ColumnCache'}else{''}) + $(if($BeatFifo){' -BeatFifo'}else{''}) +
        $(if($EpochExhaust){' -EpochExhaust'}else{''}) + $(if($ColumnOwner){' -ColumnOwner'}else{''}) +
        $(if($ReadOnLookup){' -ReadOnLookup'}else{''}) +
        $(if($RefillRequestHandoff){' -RefillRequestHandoff'}else{''})
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{run_id=$RunId;worker_pid=[int]$result.ProcessId;status_path=$statusPath} |
        ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_window_line_cache_c8_exact_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\window_line_cache_c8_exact\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_window_line_cache_c8_exact_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status([string]$State,[string]$Step,[int]$Code,[string]$Message) {
    $obj=[ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$Code;
        message=$Message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        log_directory=$runLogRoot;run_directory=$runRoot}|ConvertTo-Json
    $obj|Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj|Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}
function Save-Compact([string]$Source,[string]$Destination,[string]$Marker='') {
    $lines=@()
    if(Test-Path -LiteralPath $Source){
        if($Marker){$lines+=@(Select-String -LiteralPath $Source -Pattern ([regex]::Escape($Marker)) -ErrorAction SilentlyContinue|ForEach-Object{$_.Line})}
        $lines+=@(Get-Content -LiteralPath $Source -Tail 120 -ErrorAction SilentlyContinue)
    }
    if($lines.Count -eq 0){$lines=@('(empty)')}
    $lines|Select-Object -Unique|Set-Content -LiteralPath $Destination -Encoding UTF8
}
function Invoke-Step([string]$Name,[string]$Tool,[string[]]$ToolArgs,[string]$Marker='') {
    Write-Status 'running' $Name 0 "starting $Name"
    $rawOut=Join-Path $runRoot "$Name.stdout.raw.log"; $rawErr=Join-Path $runRoot "$Name.stderr.raw.log"
    $out=Join-Path $runLogRoot "$Name.stdout.log"; $err=Join-Path $runLogRoot "$Name.stderr.log"
    try{
        $p=Start-Process -FilePath $Tool -ArgumentList $ToolArgs -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr
        if($null -eq $p -or $p.ExitCode -ne 0){throw "$Name exit code $($p.ExitCode)"}
        $bad='(?i)(^|\s)(Fatal|Error):|\bFAIL\b|\$fatal'
        if(Select-String -LiteralPath $rawOut,$rawErr -Pattern $bad -Quiet -ErrorAction SilentlyContinue){throw "$Name reported failure"}
        if($Marker){$hits=@(Select-String -LiteralPath $rawOut -Pattern ([regex]::Escape($Marker)) -AllMatches -ErrorAction SilentlyContinue);$count=0;foreach($h in $hits){if($h.Matches){$count+=$h.Matches.Count}else{$count++}};if($count -ne 1){throw "$Name marker missing or duplicated"}}
    }finally{Save-Compact $rawOut $out $Marker;Save-Compact $rawErr $err}
}

try {
    Write-Status 'running' 'setup' 0 'detached line-cache exact worker started'
    $tbTop=if($ColumnCache){'tb_c1_column_cache_exact_axi'}else{'tb_c1_window_line_cache_c8_exact_burst_shell'}
    $sources=Join-Path $runRoot 'xvlog_sources.f'
    @(
        (Join-Path $rtlRoot 'cnn\c1_window_line_cache_c8.sv'),
        (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
        (Join-Path $rtlRoot 'common\c1_row_banked_ram.sv'),
        (Join-Path $rtlRoot 'cnn\c1_column_line_cache_c8.sv'),
        (Join-Path $rtlRoot 'dma\c1_column_transaction_owner.sv'),
        (Join-Path $rtlRoot 'dma\c1_column_cache_owned_exact_burst_shell.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler_read_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_completion_adapter.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler_read_client_exact.sv'),
        (Join-Path $rtlRoot 'dma\c1_window_line_cache_c8_exact_burst_shell.sv'),
        (Join-Path $simRoot "$tbTop.sv")
    )|Set-Content -LiteralPath $sources -Encoding ASCII
    $compileArgs=@('-sv','-nolog','-f',$sources)
    if($RepeatAbort){$compileArgs+=@('-d','C1_EXACT_REPEAT_ABORT')}
    if($MixedMaintenance){$compileArgs+=@('-d','C1_EXACT_MIXED_MAINTENANCE')}
    if($BeatFifo){$compileArgs+=@('-d','C1_COLUMN_BEAT_FIFO')}
    if($ColumnOwner){$compileArgs+=@('-d','C1_COLUMN_OWNER')}
    if($RefillRequestHandoff){$compileArgs+=@('-d','C1_COLUMN_REFILL_HANDOFF')}
    if($ReadOnLookup){$compileArgs+=@('-d','C1_COLUMN_READ_ON_LOOKUP')}
    if($EpochExhaust){$compileArgs+=@('-d','C1_COLUMN_EPOCH_EXHAUST')}
    if($RefillSkidDepth -eq 1){$compileArgs+=@('-d','C1_COLUMN_SKID_1')}
    if($RefillSkidDepth -eq 3){$compileArgs+=@('-d','C1_COLUMN_SKID_3')}
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') $compileArgs
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @($tbTop,'-s',"${tbTop}_sim",'-nolog')
    $marker=if($EpochExhaust){'C1_COLUMN_AXI_EPOCH_EXHAUST_PASS'}elseif($ColumnCache){'C1_COLUMN_CACHE_EXACT_AXI_PASS'}else{'C1_WINDOW_LINE_CACHE_C8_EXACT_BURST_SHELL_PASS'}
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @("${tbTop}_sim",'-runall','-nolog') $marker
    if($ColumnCache){
        $handoffValue=[int][bool]$RefillRequestHandoff
        foreach($pattern in @("^C1_COLUMN_AXI_HANDOFF_CONFIG enabled=$handoffValue window=32$",
                              "^C1_COLUMN_AXI_HANDOFF_PASS enabled=$handoffValue handoffs=\d+ adjacent=\d+ credit_peak=\d+ reserved_credit=1$")){
            if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $pattern).Count -ne 1){
                throw 'missing/duplicate actual column handoff mode or coverage witness'
            }
        }
    }
    if($ColumnCache) {
        $lookupValue=if($ReadOnLookup){1}else{0}
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern "^C1_COLUMN_AXI_LOOKUP_CONFIG enabled=$lookupValue$").Count -ne 1){
            throw 'Missing unique actual column lookup option'
        }
        $ownerValue=if($ColumnOwner){1}else{0}
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern "^C1_COLUMN_AXI_OWNER_CONFIG owner=$ownerValue$").Count -ne 1){
            throw 'Missing unique column owner configuration evidence'
        }
    }
    if($EpochExhaust) {
        $exhaustMarker='C1_COLUMN_AXI_EPOCH_EXHAUST_PASS epoch=3 rejected_rows=3 words=99 no_new_axi=1 config_cannot_clear=1'
        $recoveryMarker='C1_COLUMN_AXI_EPOCH_RECOVERY_PASS drained_reset=1 fresh_axi=1 golden_column=1'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^'+[regex]::Escape($recoveryMarker)+'$')).Count -ne 1){
            throw 'Missing unique drained epoch reset recovery evidence'
        }
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^'+[regex]::Escape($exhaustMarker)+'$')).Count -ne 1){
            throw 'Missing unique epoch exhaustion exact-drain evidence'
        }
    } elseif($ColumnCache) {
        $required=@('C1_COLUMN_AXI_RRESP_PASS response=2 exact_count=1 reconfigured=1',
                    'C1_COLUMN_AXI_RRESP_PASS response=3 exact_count=1 reconfigured=1')
        foreach($phase in 0..3){foreach($kind in 1..3){
            $required+="C1_COLUMN_AXI_CANCEL_PASS phase=$phase kind=$kind exact_count=1 restart=1"
        }}
        foreach($evidence in $required){
            if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^'+[regex]::Escape($evidence)+'$')).Count -ne 1){
                throw "Missing unique column integration evidence: $evidence"
            }
        }
        $bf=if($BeatFifo){1}else{0}
        $cfgMarker="C1_COLUMN_CACHE_EXACT_AXI_PASS beat_fifo=$bf skid=$RefillSkidDepth "
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^'+[regex]::Escape($cfgMarker))).Count -ne 1){
            throw 'Column integration parameter mismatch'
        }
    } else {
    $modeValue=if($RepeatAbort){1}else{0}
    $modeMarker="C1_EXACT_SHELL_REPEATED_MAINTENANCE_PASS abort=$modeValue pulses=2 ar_hold=12 completions=1 retry_correct=1"
    if($MixedMaintenance){$modeMarker="C1_EXACT_SHELL_MIXED_MAINTENANCE_PASS first_abort=$modeValue abort_done=1 flush_done=1 reconfigured=1"}
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^'+[regex]::Escape($modeMarker)+'$')).Count -ne 1){
        throw 'Missing unique repeated-maintenance mode evidence'
    }
    $overlapMarker="C1_EXACT_SHELL_DONE_OVERLAP_PASS abort=$modeValue requests=2 completions=2"
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^'+[regex]::Escape($overlapMarker)+'$')).Count -ne 1){
        throw 'Missing unique done/request overlap evidence'
    }
    $joinMarker="C1_EXACT_SHELL_JOIN_OVERLAP_PASS abort=$modeValue pending_requests=2 completions=1"
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^'+[regex]::Escape($joinMarker)+'$')).Count -ne 1){
        throw 'Missing unique child-ACK join/request overlap evidence'
    }
    }
    $watch.Stop();Write-Status 'complete' 'done' 0 $marker
}catch{
    $watch.Stop();Write-Status 'failed' 'worker' 1 $_.Exception.Message;exit 1
}finally{
    if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
