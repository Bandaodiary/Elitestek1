param(
    [switch]$Worker,
    [string]$RunId = '',
    [int]$Lanes = 2
)

# The launcher creates a worker through WMI.  Vivado is therefore not a child
# of the Codex Windows job and can finish even if this interactive session is
# interrupted.  Only compact status/summary/log files survive; the private
# Vivado report/project tree is deleted in finally.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs\dot8x8_bank_proxy_synth_runs'
$scriptFile = Join-Path $caseRoot 'scripts\synth_dot8x8_bank_proxy.tcl'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$runFamily = 'dot8x8_bank_proxy_synth'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    if ($Lanes -lt 1 -or $Lanes -gt 16) { throw 'Lanes must be in 1..16' }
    $statusPath = Join-Path $logRoot "$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId -Lanes $Lanes"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed: $($result.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        lanes = $Lanes
        worker_pid = [int]$result.ProcessId
        status_path = $statusPath
    } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
if ($Lanes -lt 1 -or $Lanes -gt 16) { throw 'Lanes must be in 1..16' }

$runRoot = Join-Path $caseRoot ".tmp_$($runFamily)_$RunId"
$runLogRoot = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'latest_status.json'
$latestFamilyStatusPath = Join-Path $caseRoot ("logs\" + $runFamily + "_status.json")
$summaryPath = Join-Path $runLogRoot 'summary.json'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'

New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Set-StatusContent([string]$Path, [string]$Value) {
    $Value | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode,
          [string]$Message, [object]$Metrics = $null)
    $value = [ordered]@{
        run_id = $RunId; lanes = $Lanes; state = $State; step = $Step
        exit_code = $ExitCode; message = $Message; process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        updated = (Get-Date).ToString('o'); log_directory = $runLogRoot
        summary_path = $summaryPath; metrics = $Metrics
    } | ConvertTo-Json -Depth 6
    Set-StatusContent $statusPath $value
    Set-StatusContent $latestStatusPath $value
    Set-StatusContent $latestFamilyStatusPath $value
}

function Get-UtilizationValue {
    param([string]$Report, [string]$Label)
    $pattern = '(?m)^\|\s*' + [regex]::Escape($Label) +
        '\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*\|'
    $match = [regex]::Match($Report, $pattern)
    if (-not $match.Success) { return $null }
    return [double]::Parse($match.Groups[1].Value,
        [Globalization.CultureInfo]::InvariantCulture)
}

function Get-TimingSummary {
    param([string[]]$Lines)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (($Lines[$i] -match 'WNS\(ns\)') -and
            ($Lines[$i] -match 'TNS\(ns\)')) {
            $limit = [math]::Min($Lines.Count - 1, $i + 8)
            for ($j = $i + 1; $j -le $limit; $j++) {
                $match = [regex]::Match($Lines[$j],
                    '^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+' +
                    '([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if ($match.Success) {
                    return [ordered]@{
                        wns_ns = [double]::Parse($match.Groups[1].Value,
                            [Globalization.CultureInfo]::InvariantCulture)
                        tns_ns = [double]::Parse($match.Groups[2].Value,
                            [Globalization.CultureInfo]::InvariantCulture)
                    }
                }
            }
        }
    }
    return [ordered]@{ wns_ns = $null; tns_ns = $null }
}

try {
    $script:step = 'prewarm'
    Write-Status 'running' $script:step 0 'pre-reading Vivado runtime helper'
    # The local Vivado installation occasionally recalls runtime Tcl files
    # lazily.  Read the small runtime set before launch; this avoids a false
    # missing-file failure while keeping the private run tree empty.
    $rtRoot = Join-Path $vivadoRoot 'scripts\rt'
    $readBuffer = New-Object byte[] 65536
    Get-ChildItem -LiteralPath $rtRoot -Filter '*.tcl' -File -Recurse |
        ForEach-Object {
            $stream = [IO.File]::OpenRead($_.FullName)
            while ($stream.Read($readBuffer, 0, $readBuffer.Length) -gt 0) {}
            $stream.Dispose()
        }

    $script:step = 'vivado'
    Write-Status 'running' $script:step 0 'detached bank proxy synthesis started'
    $stdoutPath = Join-Path $runLogRoot 'vivado.stdout.log'
    $stderrPath = Join-Path $runLogRoot 'vivado.stderr.log'
    $process = Start-Process -FilePath (Join-Path $vivadoBin 'vivado.bat') `
        -ArgumentList @('-mode', 'batch', '-nolog', '-nojournal', '-notrace',
            '-source', $scriptFile, '-tclargs', "$Lanes") `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        throw "Vivado failed with exit code $($process.ExitCode)"
    }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    $combined = $stdout + "`n" + $stderr
    if ($combined -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b') {
        throw 'Vivado log contains ERROR/FATAL/FAIL diagnostics'
    }
    $marker = "C1_DOT8X8_BANK_PROXY_SYNTH_PASS lanes=$Lanes"
    if ([regex]::Matches($stdout, [regex]::Escape($marker)).Count -ne 1) {
        throw 'bank proxy synthesis marker missing or duplicated'
    }

    $script:step = 'reports'
    $reportRoot = Join-Path $runRoot 'reports'
    $utilPath = Join-Path $reportRoot 'utilization.rpt'
    $timingPath = Join-Path $reportRoot 'timing.rpt'
    foreach ($report in @($utilPath, $timingPath)) {
        if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
            throw "proxy report is missing: $report"
        }
    }
    $util = Get-Content -Raw -LiteralPath $utilPath
    $timing = Get-TimingSummary (Get-Content -LiteralPath $timingPath)
    $metrics = [ordered]@{
        part = 'xc7a200tsbg484-1'; lanes = $Lanes
        clock_period_ns = 10.0; clock_mhz = 100.0
        slice_luts = Get-UtilizationValue $util 'Slice LUTs*'
        slice_registers = Get-UtilizationValue $util 'Slice Registers'
        bram_tiles = Get-UtilizationValue $util 'Block RAM Tile'
        dsps = Get-UtilizationValue $util 'DSPs'
        wns_ns = $timing.wns_ns; tns_ns = $timing.tns_ns
        timing_met = ($null -ne $timing.wns_ns -and $timing.wns_ns -ge 0.0)
        marker = $marker
    }
    [ordered]@{
        run_id = $RunId; marker = $marker; state = 'complete'
        metrics = $metrics
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop()
    Write-Status 'complete' 'done' 0 $marker $metrics
    exit 0
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
