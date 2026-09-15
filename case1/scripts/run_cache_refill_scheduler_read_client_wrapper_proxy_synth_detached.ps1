param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Run the wrapper-only synthesis in a WMI-created worker, so Vivado is not
# attached to the interactive Windows job.  All generated Vivado files live
# below a private run directory and are removed in finally; only compact
# marker/log/status/summary files remain under case1/logs.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs\cache_refill_scheduler_read_client_wrapper_proxy_synth_runs'
$tcl = Join-Path $caseRoot 'scripts\synth_cache_refill_scheduler_read_client_wrapper_proxy.tcl'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$vivado = Join-Path $vivadoRoot 'bin\vivado.bat'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    $statusPath = Join-Path $logRoot "$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed: $($result.ReturnValue)"
    }
    [ordered]@{ run_id = $RunId; worker_pid = [int]$result.ProcessId;
                status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $caseRoot "sim\.tmp_cache_refill_scheduler_read_client_wrapper_proxy_synth_$RunId"
$runLog = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLog 'status.json'
$summaryPath = Join-Path $runLog 'summary.json'
$latestPath = Join-Path $logRoot 'latest_status.json'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot, $runLog | Out-Null

function Write-Status([string]$State, [string]$Step, [int]$ExitCode,
                       [string]$Message, [object]$Metrics = $null) {
    $obj = [ordered]@{
        run_id = $RunId; state = $State; step = $Step; exit_code = $ExitCode
        message = $Message; process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        log_directory = $runLog; summary_path = $summaryPath; metrics = $Metrics
    }
    $json = $obj | ConvertTo-Json -Depth 8
    $json | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $json | Set-Content -LiteralPath $latestPath -Encoding UTF8
}

function Save-CompactLog([string]$RawPath, [string]$CompactPath,
                          [string]$Marker = '') {
    $lines = @()
    if (Test-Path -LiteralPath $RawPath) {
        if ($Marker) {
            $lines += @(Select-String -LiteralPath $RawPath -Pattern $Marker |
                        ForEach-Object { $_.Line })
        }
        $lines += @(Get-Content -LiteralPath $RawPath -Tail 120)
    }
    if ($lines.Count -eq 0) { $lines = @('(empty)') }
    $lines | Select-Object -Unique |
        Set-Content -LiteralPath $CompactPath -Encoding UTF8
}

function Read-UtilMetric([string]$Text, [string]$Label) {
    $pattern = '(?m)^\|\s*' + [regex]::Escape($Label) +
               '\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*\|'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
        return [double]::Parse($match.Groups[1].Value,
                               [Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

function Read-Timing([string]$Text) {
    $lines = $Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'WNS\(ns\)' -and $lines[$i] -match 'TNS\(ns\)') {
            for ($j = $i + 1; $j -lt [math]::Min($i + 12, $lines.Count); $j++) {
                $m = [regex]::Match($lines[$j],
                    '^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+' +
                    '([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if ($m.Success) {
                    return [ordered]@{
                        wns_ns = [double]$m.Groups[1].Value
                        tns_ns = [double]$m.Groups[2].Value
                    }
                }
            }
        }
    }
    return [ordered]@{ wns_ns = $null; tns_ns = $null }
}

try {
    Write-Status 'running' 'vivado' 0 'detached wrapper proxy synthesis started'

    # Read the small Vivado Tcl runtime once before launching the batch
    # process.  This avoids a lazy-file race seen with WMI workers while
    # keeping the actual synthesis detached from this PowerShell job.
    $buffer = New-Object byte[] 65536
    $runtimeRoot = Join-Path $vivadoRoot 'scripts\rt'
    if (Test-Path -LiteralPath $runtimeRoot) {
        Get-ChildItem -LiteralPath $runtimeRoot -Filter '*.tcl' -File -Recurse |
            ForEach-Object {
                $stream = [IO.File]::OpenRead($_.FullName)
                try { while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) {} }
                finally { $stream.Dispose() }
            }
    }

    $script:step = 'vivado'
    $rawOut = Join-Path $runRoot 'vivado.raw.stdout.log'
    $rawErr = Join-Path $runRoot 'vivado.raw.stderr.log'
    $compactOut = Join-Path $runLog 'vivado.stdout.log'
    $compactErr = Join-Path $runLog 'vivado.stderr.log'
    $p = Start-Process -FilePath $vivado -ArgumentList @(
        '-mode', 'batch', '-nolog', '-nojournal', '-notrace', '-source', $tcl
    ) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr
    $marker = 'C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_WRAPPER_PROXY_SYNTH_PASS'
    Save-CompactLog $rawOut $compactOut $marker
    Save-CompactLog $rawErr $compactErr
    if ($null -eq $p -or $p.ExitCode -ne 0) {
        throw "Vivado exit code $($p.ExitCode)"
    }
    $stdout = Get-Content -Raw -LiteralPath $rawOut
    $stderr = Get-Content -Raw -LiteralPath $rawErr
    if ($stdout -match '(?im)^\s*(ERROR|FATAL):' -or
        $stderr -match '(?im)^\s*(ERROR|FATAL):') {
        throw 'Vivado reported an error'
    }
    if ([regex]::Matches($stdout, [regex]::Escape($marker)).Count -ne 1) {
        throw 'synthesis marker missing or duplicated'
    }

    $utilPath = Join-Path $runRoot 'reports\utilization.rpt'
    $timingPath = Join-Path $runRoot 'reports\timing.rpt'
    $util = Get-Content -Raw -LiteralPath $utilPath
    $timing = Read-Timing (Get-Content -Raw -LiteralPath $timingPath)
    $metrics = [ordered]@{
        part = 'xc7a200tsbg484-1'; clock_mhz = 100.0
        cmd_fifo_depth = 8; epoch_width = 4
        sched_max_outstanding = 16; emit_drain_words = 1
        reader_req_fifo_depth = 32; reader_burst_beats = 16
        reader_max_outstanding = 4; reader_rsp_fifo_depth = 128
        luts = Read-UtilMetric $util 'Slice LUTs*'
        registers = Read-UtilMetric $util 'Slice Registers'
        bram_tiles = Read-UtilMetric $util 'Block RAM Tile'
        dsps = Read-UtilMetric $util 'DSPs'
        wns_ns = $timing.wns_ns; tns_ns = $timing.tns_ns
        timing_met = ($null -ne $timing.wns_ns -and $timing.wns_ns -ge 0.0)
        marker = $marker
    }
    [ordered]@{ run_id = $RunId; marker = $marker; state = 'complete';
                metrics = $metrics } |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop()
    Write-Status 'complete' 'done' 0 $marker $metrics
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
