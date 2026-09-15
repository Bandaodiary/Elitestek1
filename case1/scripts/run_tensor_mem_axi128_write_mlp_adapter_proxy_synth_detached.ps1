param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Detached Vivado proxy synthesis for the logical-write MLP adapter.  Only
# compact reports are retained and the private project tree is removed.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptRoot = Join-Path $caseRoot 'scripts'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "tensor_write_mlp_adapter_synth_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{ run_id = $RunId; worker_pid = [int]$result.ProcessId;
                status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $caseRoot "sim\.tmp_tensor_write_mlp_adapter_synth_$RunId"
$runLogRoot = Join-Path $logRoot "tensor_write_mlp_adapter_synth_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'tensor_write_mlp_adapter_synth_status.json'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$vivado = Join-Path $vivadoRoot 'bin\vivado.bat'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:currentStep = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode, [string]$Message)
    $obj = [ordered]@{ run_id = $RunId; state = $State; step = $Step;
        exit_code = $ExitCode; message = $Message; process_id = $PID;
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3);
        log_directory = $runLogRoot; run_directory = $runRoot } | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

try {
    Write-Status 'running' 'synthesis' 0 'detached logical-write MLP adapter proxy synthesis started'
    $out = Join-Path $runLogRoot 'vivado.stdout.log'
    $err = Join-Path $runLogRoot 'vivado.stderr.log'
    $args = @('-mode','batch','-nolog','-nojournal','-notrace','-source',
              (Join-Path $scriptRoot 'synth_tensor_mem_axi128_write_mlp_adapter_proxy.tcl'))
    $proc = Start-Process -FilePath $vivado -ArgumentList $args -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if ($null -eq $proc -or $proc.ExitCode -ne 0) { throw "vivado failed with exit code $($proc.ExitCode)" }
    $all = (Get-Content -Raw -LiteralPath $out) + "`n" + (Get-Content -Raw -LiteralPath $err)
    if ($all -notmatch 'C1_TENSOR_MEM_AXI128_WRITE_MLP_ADAPTER_PROXY_SYNTH_PASS') {
        throw 'Vivado did not emit adapter synthesis PASS marker'
    }
    $reportDir = Join-Path $runRoot 'reports'
    $util = Join-Path $reportDir 'utilization.rpt'
    $timing = Join-Path $reportDir 'timing.rpt'
    $summary = [ordered]@{ run_id = $RunId; part = 'xc7a200tsbg484-1';
        max_outstanding = 4; max_beats = 16; rsp_fifo_depth = 4; tag_width = 16 }
    function Get-Metric([string]$text, [string]$label) {
        $m = [regex]::Match($text, '(?m)^\|\s*' + [regex]::Escape($label) +
            '\s*\|\s*([0-9,]+(?:\.[0-9]+)?)\s*\|')
        if ($m.Success) { return [double](($m.Groups[1].Value) -replace ',','') }
        return $null
    }
    if (Test-Path -LiteralPath $util) {
        $u = Get-Content -Raw -LiteralPath $util
        $summary.luts = Get-Metric $u 'Slice LUTs*'
        if ($null -eq $summary.luts) { $summary.luts = Get-Metric $u 'CLB LUTs' }
        $summary.registers = Get-Metric $u 'Slice Registers'
        if ($null -eq $summary.registers) { $summary.registers = Get-Metric $u 'CLB Registers' }
        $summary.bram_tiles = Get-Metric $u 'Block RAM Tile'
        $summary.dsps = Get-Metric $u 'DSPs'
    }
    if (Test-Path -LiteralPath $timing) {
        $t = Get-Content -Raw -LiteralPath $timing
        $lines = $t -split "`r?`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'WNS\(ns\)' -and $lines[$i] -match 'TNS\(ns\)') {
                for ($j = $i + 1; $j -lt [math]::Min($i + 10, $lines.Count); $j++) {
                    $m = [regex]::Match($lines[$j], '^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                    if ($m.Success) { $summary.wns_ns = [double]$m.Groups[1].Value; $summary.tns_ns = [double]$m.Groups[2].Value; break }
                }
                if ($summary.Contains('wns_ns')) { break }
            }
        }
        $summary.timing_met = ($summary.Contains('wns_ns') -and $summary.wns_ns -ge 0.0)
    }
    $critical = Join-Path $reportDir 'critical.rpt'
    if (Test-Path -LiteralPath $critical) {
        Get-Content -LiteralPath $critical -TotalCount 120 |
            Set-Content -LiteralPath (Join-Path $runLogRoot 'critical_excerpt.rpt') -Encoding UTF8
    }
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runLogRoot 'summary.json') -Encoding UTF8
    $watch.Stop()
    Write-Status 'complete' 'done' 0 'C1_TENSOR_MEM_AXI128_WRITE_MLP_ADAPTER_PROXY_SYNTH_PASS'
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:currentStep 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
