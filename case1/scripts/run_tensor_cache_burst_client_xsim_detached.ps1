param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$BeatFifo, [switch]$PackedWrites
)

# Detached, compact xsim runner for the optional tensor burst client seam.
# The worker is created through WMI, so Vivado/xsim is not attached to the
# Codex Windows job.  The private xsim directory is removed after every run;
# only small status/stdout tails remain under case1/logs.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = 'tensor_cache_burst_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    $runLog = Join-Path $logRoot "xsim_runs\tensor_cache_burst_client\$RunId"
    $statusPath = Join-Path $runLog 'status.json'
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $beatArg = if ($BeatFifo) { ' -BeatFifo' } else { '' }
    if ($PackedWrites) { $beatArg += ' -PackedWrites' }
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId$beatArg"
    $workerPid = $null
    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
        if ($result.ReturnValue -eq 0) { $workerPid = [int]$result.ProcessId }
    } catch { $result = $null }
    if ($null -eq $workerPid) {
        # Fail closed if breakaway is unavailable; never run xsim in the
        # caller's Job merely because WMI was denied by local policy.
        $launcher = Join-Path $PSScriptRoot 'start_detached_process.ps1'
        $launcherOutput = & $powerShell -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $launcher -CommandLine $commandLine `
            -CurrentDirectory $caseRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "detached fallback failed: $($launcherOutput -join ' ')"
        }
        $workerPid = [int](($launcherOutput | Select-Object -Last 1).ToString().Trim())
        if ($workerPid -le 0) { throw 'detached fallback returned invalid pid' }
    }
    [ordered]@{ run_id=$RunId; worker_pid=$workerPid;
        status_path=$statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_tensor_cache_burst_client_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\tensor_cache_burst_client\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_tensor_cache_burst_client_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status([string]$State,[string]$Step,[int]$Code,[string]$Message) {
    $obj=[ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$Code;
        message=$Message;process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        log_directory=$runLogRoot;run_directory=$runRoot}|ConvertTo-Json
    $obj|Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj|Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Save-Compact([string]$Source,[string]$Destination,[string]$Marker='') {
    $lines=@()
    if(Test-Path -LiteralPath $Source){
        if($Marker){
            $lines+=@(Select-String -LiteralPath $Source -Pattern ([regex]::Escape($Marker)) `
                -ErrorAction SilentlyContinue|ForEach-Object{$_.Line})
        }
        $lines+=@(Get-Content -LiteralPath $Source -Tail 120 -ErrorAction SilentlyContinue)
    }
    if($lines.Count -eq 0){$lines=@('(empty)')}
    $lines|Select-Object -Unique|Set-Content -LiteralPath $Destination -Encoding UTF8
}

function Invoke-Step([string]$Name,[string]$Tool,[string[]]$ToolArgs,[string]$Marker='') {
    $script:step = $Name
    Write-Status 'running' $Name 0 "starting $Name"
    $rawOut=Join-Path $runRoot "$Name.stdout.raw.log"
    $rawErr=Join-Path $runRoot "$Name.stderr.raw.log"
    $out=Join-Path $runLogRoot "$Name.stdout.log"
    $err=Join-Path $runLogRoot "$Name.stderr.log"
    try {
        $p=Start-Process -FilePath (Join-Path $vivadoBin $Tool) -ArgumentList $ToolArgs `
            -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
            -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr
        if($null -eq $p -or $p.ExitCode -ne 0){throw "$Name exit code $($p.ExitCode)"}
        $bad='(?i)(^|\s)(Fatal|Error):|\bFAIL\b|\$fatal'
        if(Select-String -LiteralPath $rawOut,$rawErr -Pattern $bad -Quiet `
            -ErrorAction SilentlyContinue){throw "$Name reported failure"}
        if($Marker){
            $hits=@(Select-String -LiteralPath $rawOut -Pattern ([regex]::Escape($Marker)) `
                -AllMatches -ErrorAction SilentlyContinue)
            $count=0
            foreach($h in $hits){if($h.Matches){$count+=$h.Matches.Count}else{$count++}}
            if($count -ne 1){throw "$Name marker missing or duplicated"}
        }
        if ($Name -eq 'xsim') {
            $configFence = @(Select-String -LiteralPath $rawOut `
                -Pattern '^C1_CACHE_CONFIG_RESPONSE_FENCE_PASS held_cycles=12 config_after_retire=1$')
            if ($configFence.Count -ne 1) {
                throw 'cache config response fence marker missing or duplicated'
            }
        }
    } finally {
        Save-Compact $rawOut $out $Marker
        Save-Compact $rawErr $err
    }
}

try {
    Write-Status 'running' 'setup' 0 'detached tensor burst client test started'
    $sources = Join-Path $runRoot 'xvlog_sources.f'
    @(
        (Join-Path $rtlRoot 'cnn\c1_window_line_cache_c8.sv'),
        (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
        (Join-Path $rtlRoot 'common\c1_row_banked_ram.sv'),
        (Join-Path $rtlRoot 'cnn\c1_column_line_cache_c8.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler_read_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_completion_adapter.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler_read_client_exact.sv'),
        (Join-Path $rtlRoot 'dma\c1_window_line_cache_c8_exact_burst_shell.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_bridge.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_write_burst_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_packing_bridge.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_ordered_write_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_axi128_write_mlp.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_window_cache_burst_axi_client.sv'),
        (Join-Path $simRoot 'tb_c1_tensor_window_cache_burst_axi_client.sv')
    ) | Set-Content -LiteralPath $sources -Encoding ASCII

    $xvlogArgs = @('-sv','-nolog','-f',$sources)
    if ($PackedWrites) { $xvlogArgs += @('-d','C1_TEST_PACKED_WRITES') }
    if ($BeatFifo) {
        $xvlogArgs += @('-d','C1_BURST_BEAT_FIFO')
    }
    Invoke-Step 'xvlog' 'xvlog.bat' $xvlogArgs
    Invoke-Step 'xelab' 'xelab.bat' @(
        'tb_c1_tensor_window_cache_burst_axi_client',
        '-s','tb_c1_tensor_window_cache_burst_axi_client_sim','-nolog'
    )
    $marker='C1_TENSOR_CACHE_BURST_AXI_CLIENT_PASS'
    Invoke-Step 'xsim' 'xsim.bat' @(
        'tb_c1_tensor_window_cache_burst_axi_client_sim','-runall','-nolog'
    ) $marker
    $watch.Stop()
    Write-Status 'complete' 'done' 0 $marker
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    if(Test-Path -LiteralPath $runRoot){
        $resolvedRun = (Resolve-Path -LiteralPath $runRoot).Path
        $resolvedSim = (Resolve-Path -LiteralPath $simRoot).Path
        if ((Split-Path -Parent $resolvedRun) -ne $resolvedSim -or
            (Split-Path -Leaf $resolvedRun) -notmatch '^xsim_tensor_cache_burst_client_[A-Za-z0-9_-]+$') {
            throw "refusing cleanup outside private simulation directory: $resolvedRun"
        }
        Remove-Item -LiteralPath $resolvedRun -Recurse -Force
    }
}
