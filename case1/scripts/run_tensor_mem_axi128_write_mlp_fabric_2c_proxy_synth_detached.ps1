param(
    [switch]$Worker,
    [string]$RunId = ''
)

# WMI-detached Vivado proxy synthesis for the optional two-client write seam.
# Only compact reports are retained; the private Vivado project is removed in
# finally to avoid leaving a large .Xil/project tree in the workspace.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptRoot = Join-Path $caseRoot 'scripts'
$logRoot = Join-Path $caseRoot 'logs\tensor_write_mlp_fabric_2c_proxy_synth_runs'
$scriptFile = Join-Path $scriptRoot 'synth_tensor_mem_axi128_write_mlp_fabric_2c.tcl'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$vivadoBin = Join-Path $vivadoRoot 'bin'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
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
$runRoot = Join-Path $caseRoot "sim\.tmp_tensor_write_mlp_fabric_2c_synth_$RunId"
$runLogRoot = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLogRoot 'status.json'
$summaryPath = Join-Path $runLogRoot 'summary.json'
$latestStatusPath = Join-Path $logRoot 'latest_status.json'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:currentStep = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode,
          [string]$Message, [object]$Metrics = $null)
    $obj = [ordered]@{
        run_id = $RunId; state = $State; step = $Step; exit_code = $ExitCode
        message = $Message; process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        log_directory = $runLogRoot; summary_path = $summaryPath
        metrics = $Metrics
    } | ConvertTo-Json -Depth 8
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Get-Metric {
    param([string]$Text, [string]$Label)
    $m = [regex]::Match($Text, '(?m)^\|\s*' + [regex]::Escape($Label) +
        '\s*\|\s*([0-9,]+(?:\.[0-9]+)?)\s*\|')
    if ($m.Success) { return [double](($m.Groups[1].Value) -replace ',','') }
    return $null
}

function Get-Timing {
    param([string]$Text)
    $lines = $Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'WNS\(ns\)' -and $lines[$i] -match 'TNS\(ns\)') {
            for ($j = $i + 1; $j -lt [math]::Min($i + 12, $lines.Count); $j++) {
                $m = [regex]::Match($lines[$j], '^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if ($m.Success) {
                    return [ordered]@{ wns_ns = [double]$m.Groups[1].Value;
                                       tns_ns = [double]$m.Groups[2].Value }
                }
            }
        }
    }
    return [ordered]@{ wns_ns = $null; tns_ns = $null }
}

try {
    Write-Status 'running' 'vivado' 0 'detached two-client write seam proxy synthesis started'
    # Vivado's detached helper can lazily open a runtime Tcl file after the
    # parent process has changed directory.  Touch the small runtime scripts
    # first, matching the proven proxy runners, so this worker does not fail
    # intermittently with "couldn't read .../scripts/rt/...".
    $buf = New-Object byte[] 65536
    $rtRoot = Join-Path $vivadoRoot 'scripts\rt'
    if (Test-Path -LiteralPath $rtRoot) {
        Get-ChildItem -LiteralPath $rtRoot -Filter '*.tcl' -File -Recurse |
            ForEach-Object {
                $stream = [IO.File]::OpenRead($_.FullName)
                try { while ($stream.Read($buf, 0, $buf.Length) -gt 0) {} }
                finally { $stream.Dispose() }
            }
    }
    $out = Join-Path $runLogRoot 'vivado.stdout.log'
    $err = Join-Path $runLogRoot 'vivado.stderr.log'
    $args = @('-mode','batch','-nolog','-nojournal','-notrace','-source',$scriptFile)
    $proc = Start-Process -FilePath (Join-Path $vivadoBin 'vivado.bat') `
        -ArgumentList $args -WorkingDirectory $runRoot -WindowStyle Hidden -Wait `
        -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if ($null -eq $proc -or $proc.ExitCode -ne 0) {
        throw "Vivado failed with exit code $($proc.ExitCode)"
    }
    $stdout = if (Test-Path -LiteralPath $out) { Get-Content -Raw -LiteralPath $out } else { '' }
    $stderr = if (Test-Path -LiteralPath $err) { Get-Content -Raw -LiteralPath $err } else { '' }
    $all = $stdout + "`n" + $stderr
    $marker = 'C1_TENSOR_MEM_AXI128_WRITE_MLP_FABRIC_2C_PROXY_SYNTH_PASS'
    if ($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened') {
        throw 'Vivado reported synthesis failure'
    }
    if ([regex]::Matches($stdout, [regex]::Escape($marker)).Count -ne 1) {
        throw 'proxy synthesis marker missing or duplicated'
    }
    $utilPath = Join-Path $runRoot 'reports\utilization.rpt'
    $timingPath = Join-Path $runRoot 'reports\timing.rpt'
    if (-not (Test-Path -LiteralPath $utilPath) -or
        -not (Test-Path -LiteralPath $timingPath)) {
        throw 'Vivado reports were not generated'
    }
    $util = Get-Content -Raw -LiteralPath $utilPath
    $timing = Get-Timing (Get-Content -Raw -LiteralPath $timingPath)
    $metrics = [ordered]@{
        part = 'xc7a200tsbg484-1'; clock_mhz = 100.0
        max_outstanding = 4; max_beats = 16
        adapter_rsp_fifo_depth = 4; fabric_fifo_depth = 6
        luts = Get-Metric $util 'Slice LUTs*'
        registers = Get-Metric $util 'Slice Registers'
        bram_tiles = Get-Metric $util 'Block RAM Tile'
        dsps = Get-Metric $util 'DSPs'
        wns_ns = $timing.wns_ns; tns_ns = $timing.tns_ns
        timing_met = ($null -ne $timing.wns_ns -and $timing.wns_ns -ge 0.0)
        marker = $marker
    }
    [ordered]@{ run_id = $RunId; state = 'complete'; marker = $marker;
                metrics = $metrics } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop()
    Write-Status 'complete' 'done' 0 $marker $metrics
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:currentStep 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
