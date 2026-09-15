param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$BeatFifo,
    [switch]$TailFlush,
    [switch]$LongBurst,
    [switch]$MaxRow,
    [switch]$ReqPopRefill,
    [switch]$RspPopRefill
)

# Detached, self-cleaning xsim runner for the cache-refill burst shell.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "xsim_runs\cache_burst_shell\$RunId\status.json"
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd = "`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
           "-WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId" +
           $(if ($BeatFifo) { ' -BeatFifo' } else { '' }) +
           $(if ($TailFlush) { ' -TailFlush' } else { '' }) +
           $(if ($LongBurst) { ' -LongBurst' } else { '' }) +
           $(if ($MaxRow) { ' -MaxRow' } else { '' }) +
           $(if ($ReqPopRefill) { ' -ReqPopRefill' } else { '' }) +
           $(if ($RspPopRefill) { ' -RspPopRefill' } else { '' })
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine=$cmd; CurrentDirectory=$caseRoot }
    if ($r.ReturnValue -ne 0) { throw "WMI worker failed: $($r.ReturnValue)" }
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath} |
        ConvertTo-Json
    exit 0
}
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_cache_burst_shell_$RunId"
$runLog = Join-Path $logRoot "xsim_runs\cache_burst_shell\$RunId"
$status = Join-Path $runLog 'status.json'
$latest = Join-Path $logRoot 'xsim_runs\cache_burst_shell_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLog | Out-Null
function Set-Status([string]$State,[string]$Step,[int]$Code,[string]$Msg) {
    $v=[ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$Code;
        message=$Msg;process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        log_directory=$runLog;run_directory=$runRoot}|ConvertTo-Json
    $v|Set-Content -LiteralPath $status -Encoding UTF8
    $v|Set-Content -LiteralPath $latest -Encoding UTF8
}
function Save-CompactLog([string]$Source,[string]$Destination,[string]$Marker='') {
    # A max-row profile can print one line per AXI beat.  Keep the complete
    # stream private to runRoot and persist only marker lines plus a short
    # tail; finally{} removes the raw stream after the tool exits.
    $lines=@()
    if(Test-Path -LiteralPath $Source){
        if($Marker){
            $lines += @(Select-String -LiteralPath $Source -Pattern ([regex]::Escape($Marker)) -AllMatches -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Line })
        }
        $lines += @(Get-Content -LiteralPath $Source -Tail 80 -ErrorAction SilentlyContinue)
    }
    if($lines.Count -eq 0){$lines=@('(empty)')}
    $lines | Select-Object -Unique | Set-Content -LiteralPath $Destination -Encoding UTF8
}
function Run-Step([string]$Name,[string]$Tool,[string[]]$ToolArgs,[string]$Marker='') {
    Set-Status 'running' $Name 0 "starting $Name"
    $rawO=Join-Path $runRoot "$Name.stdout.raw.log"; $rawE=Join-Path $runRoot "$Name.stderr.raw.log"
    $o=Join-Path $runLog "$Name.stdout.log"; $e=Join-Path $runLog "$Name.stderr.log"
    try {
        $sp=@{FilePath=$Tool;ArgumentList=$ToolArgs;WorkingDirectory=$runRoot;
            WindowStyle='Hidden';Wait=$true;PassThru=$true;
            RedirectStandardOutput=$rawO;RedirectStandardError=$rawE}
        $p=Start-Process @sp
        if($p.ExitCode -ne 0){throw "$Name exit code $($p.ExitCode)"}
        $bad='(?i)(^|\s)(Fatal|Error):|\bFAIL\b|\$fatal'
        if(Select-String -LiteralPath $rawE -Pattern '\S' -Quiet -ErrorAction SilentlyContinue){
            $tail=((Get-Content -LiteralPath $rawE -Tail 12 -ErrorAction SilentlyContinue) -join ' ')
            throw "$Name reported stderr: $tail"
        }
        if(Select-String -LiteralPath $rawO -Pattern $bad -Quiet -ErrorAction SilentlyContinue){
            $tail=((Get-Content -LiteralPath $rawO -Tail 12 -ErrorAction SilentlyContinue) -join ' ')
            throw "$Name reported failure: $tail"
        }
        if($Marker){
            $n=0
            foreach($hit in @(Select-String -LiteralPath $rawO -Pattern ([regex]::Escape($Marker)) -AllMatches -ErrorAction SilentlyContinue)){
                if($hit.Matches){$n += $hit.Matches.Count}else{$n++}
            }
            if($n -ne 1){throw "$Name missing marker $Marker"}
        }
    } finally {
        Save-CompactLog $rawO $o $Marker
        Save-CompactLog $rawE $e
    }
}
try {
    Set-Status 'running' 'setup' 0 'cache burst shell worker started'
    $defines = @()
    if ($BeatFifo) { $defines += @('-d', 'C1_CACHE_BEAT_FIFO_TB') }
    if ($TailFlush) { $defines += @('-d', 'C1_CACHE_TAIL_FLUSH_TB') }
    if ($LongBurst) { $defines += @('-d', 'C1_CACHE_LONG_BURST_TB') }
    if ($MaxRow) { $defines += @('-d', 'C1_CACHE_MAXROW_TB') }
    if ($ReqPopRefill) { $defines += @('-d', 'C1_CACHE_REQ_POP_REFILL_TB') }
    if ($RspPopRefill) { $defines += @('-d', 'C1_CACHE_RSP_POP_REFILL_TB') }
    $xvlogArgs = @('-sv', '-nolog') + $defines + @(
        (Join-Path $rtlRoot 'cnn\c1_window_line_cache_c8.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_window_line_cache_c8_burst_shell.sv'),
        (Join-Path $simRoot 'tb_c1_window_line_cache_c8_burst_shell.sv'))
    Run-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    Run-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_window_line_cache_c8_burst_shell','-s',
        'tb_c1_window_line_cache_c8_burst_shell_sim','-nolog')
    $marker = if ($MaxRow) {
        'C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_MAXROW_PASS'
    } else {
        'C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS'
    }
    Run-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_window_line_cache_c8_burst_shell_sim','-runall','-nolog') `
        $marker
    $watch.Stop(); Set-Status 'complete' 'done' 0 $marker
} catch {
    $watch.Stop(); Set-Status 'failed' 'worker' 1 $_.Exception.Message; exit 1
} finally {
    if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
