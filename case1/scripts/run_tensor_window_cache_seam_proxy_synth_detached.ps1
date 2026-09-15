param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Detached Vivado proxy synthesis for c1_tensor_window_cache_seam.  Runtime
# Tcl is staged in the workspace before the Win32_Process worker starts
# Vivado, avoiding dependencies on cloud-placeholder installation files.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
$runFamily = 'tensor_window_cache_seam_proxy_synth'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'RunId contains unsupported characters'
    }
    $statusPath = Join-Path $logRoot "$($runFamily)_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$result.ProcessId
        status_path = $statusPath
    } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

$runRoot = Join-Path $simRoot "$($runFamily)_$RunId"
$runLogRoot = Join-Path $logRoot "$($runFamily)_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot "$($runFamily)_status.json"
$resultPath = Join-Path $runLogRoot 'result.json'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$vivadoBin = Join-Path $vivadoRoot 'bin'
$script:currentStep = 'setup'
$script:watch = [Diagnostics.Stopwatch]::StartNew()
$script:metrics = $null

New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Set-StatusContent {
    param([string]$Path,[string]$Value)
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $Value | Set-Content -LiteralPath $Path -Encoding UTF8 `
                -ErrorAction Stop
            return
        } catch [IO.IOException] {
            if ($i -eq 19) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Write-Status {
    param(
        [string]$State,
        [string]$Step,
        [int]$ExitCode,
        [string]$Message,
        [object]$Metrics = $null
    )
    $status = [ordered]@{
        run_id = $RunId
        state = $State
        step = $Step
        exit_code = $ExitCode
        message = $Message
        process_id = $PID
        elapsed_seconds = [math]::Round($script:watch.Elapsed.TotalSeconds,3)
        updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot
        run_directory = $runRoot
        result_path = $resultPath
        metrics = $Metrics
    } | ConvertTo-Json -Depth 5
    Set-StatusContent $statusPath $status
    Set-StatusContent $latestStatusPath $status
}

function Get-UtilizationValue {
    param([string]$Report,[string]$Label)
    $pattern = '(?m)^\|\s*' + [regex]::Escape($Label) +
        '\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*\|'
    $match = [regex]::Match($Report,$pattern)
    if (-not $match.Success) {
        throw "Could not parse utilization row '$Label'"
    }
    return [double]::Parse(
        $match.Groups[1].Value,
        [Globalization.CultureInfo]::InvariantCulture)
}

function Get-TimingSummary {
    param([string[]]$Lines)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (($Lines[$i] -match 'WNS\(ns\)') -and
            ($Lines[$i] -match 'TNS\(ns\)')) {
            $limit = [math]::Min($Lines.Count - 1,$i + 6)
            for ($j = $i + 1; $j -le $limit; $j++) {
                $match = [regex]::Match(
                    $Lines[$j],
                    '^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+' +
                    '([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if ($match.Success) {
                    return [ordered]@{
                        wns_ns = [double]::Parse(
                            $match.Groups[1].Value,
                            [Globalization.CultureInfo]::InvariantCulture)
                        tns_ns = [double]::Parse(
                            $match.Groups[2].Value,
                            [Globalization.CultureInfo]::InvariantCulture)
                    }
                }
            }
        }
    }
    throw 'Could not parse WNS/TNS from timing report'
}

try {
    Write-Status 'running' 'setup' 0 `
        'preparing detached tensor window-cache seam proxy synthesis'

    $script:currentStep = 'stage_vivado_runtime'
    $env:XILINX_VIVADO = $vivadoRoot
    $env:RDI_APPROOT = $vivadoRoot
    $env:RDI_PATCHROOT = Join-Path $caseRoot '.vivado_rt'
    $env:XILINX_PATH = $env:RDI_PATCHROOT
    $sourceRt = Join-Path $vivadoRoot 'scripts\rt'
    $stageRt = Join-Path $env:RDI_PATCHROOT 'scripts\rt'
    foreach ($name in @('data','fpga_tcl','base_tcl')) {
        $source = Join-Path $sourceRt $name
        $destination = Join-Path $stageRt $name
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $destination `
            -Recurse -Force
    }
    $stageSentinels = @(
        (Join-Path $stageRt 'data\unimacro\unimacro_verilog.tcl'),
        (Join-Path $stageRt 'data\unimacro\unimacro_vhdl.tcl')
    )
    foreach ($sentinel in $stageSentinels) {
        if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
            throw "Vivado runtime stage sentinel is missing: $sentinel"
        }
    }
    Get-ChildItem -LiteralPath $env:RDI_PATCHROOT -Recurse -File |
        ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
    $env:RT_LIBPATH = Join-Path $stageRt 'data'
    $env:SYNTH_COMMON = $env:RT_LIBPATH
    $env:RT_TCL_PATH = Join-Path $stageRt 'base_tcl\tcl'

    $script:currentStep = 'vivado'
    Write-Status 'running' 'vivado' 0 `
        'running combined seam plus three-row cache synthesis at 100 MHz'
    $stdoutPath = Join-Path $runLogRoot 'vivado.stdout.log'
    $stderrPath = Join-Path $runLogRoot 'vivado.stderr.log'
    $tclPath = Join-Path $caseRoot `
        'scripts\synth_tensor_window_cache_seam_proxy.tcl'
    $process = Start-Process -FilePath (Join-Path $vivadoBin 'vivado.bat') `
        -ArgumentList @('-mode','batch','-nojournal','-nolog','-notrace',
            '-source',$tclPath) `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        throw "Vivado failed with exit code $($process.ExitCode)"
    }

    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    if (($stdout + "`n" + $stderr) -match
        '(?im)^\s*(FATAL|ERROR):|\bFAIL\b|cannot be opened') {
        throw 'Vivado reported Fatal/Error/FAIL'
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw 'Vivado wrote diagnostics to stderr'
    }
    $marker = 'C1_TENSOR_WINDOW_CACHE_SEAM_PROXY_SYNTH_PASS'
    if ([regex]::Matches($stdout,$marker).Count -ne 1) {
        throw 'proxy synthesis marker missing or duplicated'
    }

    $script:currentStep = 'reports'
    $reportRoot = Join-Path $runRoot 'reports'
    $utilizationPath = Join-Path $reportRoot 'utilization.rpt'
    $hierarchicalPath = Join-Path $reportRoot `
        'utilization_hierarchical.rpt'
    $timingPath = Join-Path $reportRoot 'timing.rpt'
    foreach ($report in @($utilizationPath,$hierarchicalPath,$timingPath)) {
        if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
            throw "proxy synthesis report is missing: $report"
        }
    }
    $utilization = Get-Content -Raw -LiteralPath $utilizationPath
    $timing = Get-TimingSummary (Get-Content -LiteralPath $timingPath)
    $metrics = [ordered]@{
        part = 'xc7a200tsbg484-1'
        clock_period_ns = 10.0
        clock_mhz = 100.0
        data_w = 64
        line_rows = 3
        max_row_words = 1280
        max_groups = 8
        slice_luts = [int](Get-UtilizationValue $utilization 'Slice LUTs*')
        slice_registers = [int](
            Get-UtilizationValue $utilization 'Slice Registers')
        bram_tiles = [double](
            Get-UtilizationValue $utilization 'Block RAM Tile')
        dsps = [int](Get-UtilizationValue $utilization 'DSPs')
        wns_ns = [double]$timing.wns_ns
        tns_ns = [double]$timing.tns_ns
        timing_met = ([double]$timing.wns_ns -ge 0.0)
        utilization_report = $utilizationPath
        hierarchical_utilization_report = $hierarchicalPath
        timing_report = $timingPath
    }
    $script:metrics = $metrics
    $resultState = $(if ($metrics.timing_met) {
        'complete'
    } else {
        'timing_failed'
    })
    [ordered]@{
        run_id = $RunId
        marker = $marker
        state = $resultState
        metrics = $metrics
    } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $resultPath -Encoding UTF8

    $script:watch.Stop()
    if ($metrics.timing_met) {
        Write-Status 'complete' 'done' 0 $marker $metrics
        exit 0
    }
    Write-Status 'timing_failed' 'done' 2 `
        "$marker; 100 MHz proxy WNS=$($metrics.wns_ns) ns" $metrics
    exit 2
} catch {
    $script:watch.Stop()
    Write-Status 'failed' $script:currentStep 1 $_.Exception.Message `
        $script:metrics
    exit 1
}
