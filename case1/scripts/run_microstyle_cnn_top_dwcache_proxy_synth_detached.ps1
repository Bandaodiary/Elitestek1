param(
    [switch]$Worker,
    [string]$RunId = '',
    [int]$CacheDwWeightTiles = 1,
    [int]$PipelinedDotTree = 0,
    [int]$PipelinedDotTreeFull = 0,
    [int]$PipelinedDescriptorReplay = 0,
    [int]$PrevalidateDescriptorReplay = 0,
    [int]$MacPrefetchOverlap = 0,
    [int]$PackedAffineCache = 0
)

# WMI-detached Artix-7 proxy synthesis for c1_r1_microstyle_cnn_top.  The
# worker is created outside the caller's Windows Job, and the private Vivado
# project/report tree is removed in finally.  Only compact JSON status and
# summary files remain under case1/logs.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs\r1_microstyle_cnn_dwcache_proxy_synth_runs'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$vivado = Join-Path $vivadoRoot 'bin\vivado.bat'
$vivadoRt = Join-Path $vivadoRoot 'scripts\rt'
$tcl = Join-Path $PSScriptRoot 'synth_microstyle_cnn_top_dwcache_proxy.tcl'

if ($CacheDwWeightTiles -lt 0 -or $CacheDwWeightTiles -gt 1) {
    throw 'CacheDwWeightTiles must be 0 or 1'
}
foreach ($v in @($PipelinedDotTree,$PipelinedDotTreeFull,
                 $PipelinedDescriptorReplay,$PrevalidateDescriptorReplay,
                 $MacPrefetchOverlap,$PackedAffineCache)) {
    if ($v -lt 0 -or $v -gt 1) { throw 'pipeline/validation generics must be 0 or 1' }
}

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $logRoot "$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId -CacheDwWeightTiles $CacheDwWeightTiles " +
        "-PipelinedDotTree $PipelinedDotTree " +
        "-PipelinedDotTreeFull $PipelinedDotTreeFull " +
        "-PipelinedDescriptorReplay $PipelinedDescriptorReplay " +
        "-PrevalidateDescriptorReplay $PrevalidateDescriptorReplay " +
        "-MacPrefetchOverlap $MacPrefetchOverlap " +
        "-PackedAffineCache $PackedAffineCache"
    $workerPid = $null
    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
        if ($result.ReturnValue -ne 0) { throw 'Win32_Process.Create failed' }
        $workerPid = [int]$result.ProcessId
    } catch {
        $helper = Join-Path $caseRoot 'scripts\start_detached_process.ps1'
        if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
            throw 'detached process helper is missing'
        }
        $workerPid = [int](& powershell.exe -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $helper -CommandLine $commandLine `
            -CurrentDirectory $caseRoot)
    }
    [ordered]@{ run_id = $RunId; worker_pid = $workerPid;
                status_path = (Join-Path $logRoot "$RunId\status.json") } |
        ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $caseRoot "sim\.tmp_r1_microstyle_cnn_dwcache_proxy_$RunId"
$runLogRoot = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLogRoot 'status.json'
$summaryPath = Join-Path $runLogRoot 'summary.json'
$latestStatusPath = Join-Path $logRoot 'latest_status.json'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
$stdout = $null
$stderr = $null
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status {
    param([string]$State,[string]$Step,[int]$Code,[string]$Message,
          [object]$Metrics = $null)
    $obj = [ordered]@{
        run_id = $RunId; state = $State; step = $Step; exit_code = $Code
        message = $Message; process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds,3)
        log_directory = $runLogRoot; summary_path = $summaryPath
        metrics = $Metrics
    } | ConvertTo-Json -Depth 8
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Get-Metric {
    param([string]$Text,[string]$Label)
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
            for ($j = $i + 1; $j -lt [math]::Min($i + 14,$lines.Count); $j++) {
                $m = [regex]::Match($lines[$j], '^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if ($m.Success) {
                    return [ordered]@{ wns_ns=[double]$m.Groups[1].Value;
                                       tns_ns=[double]$m.Groups[2].Value }
                }
            }
        }
    }
    return [ordered]@{ wns_ns=$null; tns_ns=$null }
}

try {
    # Pre-read the small runtime Tcl tree.  This avoids a known lazy-open race
    # in the local Vivado helper without retaining any of those files in the
    # run directory.
    Write-Status 'running' 'prewarm' 0 'pre-reading Vivado runtime Tcl files'
    $buf = New-Object byte[] 65536
    if (Test-Path -LiteralPath $vivadoRt) {
        Get-ChildItem -LiteralPath $vivadoRt -Filter '*.tcl' -File -Recurse |
            ForEach-Object {
                $s = [IO.File]::OpenRead($_.FullName)
                try { while ($s.Read($buf,0,$buf.Length) -gt 0) {} }
                finally { $s.Dispose() }
            }
    }

    $script:step = 'vivado'
    Write-Status 'running' 'vivado' 0 'detached MicroStyle DW-cache proxy synthesis started'
    $stdout = Join-Path $runRoot 'vivado.stdout.log'
    $stderr = Join-Path $runRoot 'vivado.stderr.log'
    $tclArgs = @(
        'CACHE_DW_WEIGHT_TILES=' + $CacheDwWeightTiles,
        'PIPELINED_DOT_TREE=' + $PipelinedDotTree,
        'PIPELINED_DOT_TREE_FULL=' + $PipelinedDotTreeFull,
        'PIPELINED_DESCRIPTOR_REPLAY=' + $PipelinedDescriptorReplay,
        'PREVALIDATE_DESCRIPTOR_REPLAY=' + $PrevalidateDescriptorReplay,
        'MAC_PREFETCH_OVERLAP=' + $MacPrefetchOverlap,
        'PACKED_AFFINE_CACHE=' + $PackedAffineCache
    )
    $args = @('-mode','batch','-nolog','-nojournal','-notrace','-source',$tcl,
              '-tclargs') + $tclArgs
    $proc = Start-Process -FilePath $vivado -ArgumentList $args `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($null -eq $proc -or $proc.ExitCode -ne 0) {
        throw "Vivado failed with exit code $($proc.ExitCode)"
    }
    $out = if (Test-Path -LiteralPath $stdout) { Get-Content -Raw -LiteralPath $stdout } else { '' }
    $err = if (Test-Path -LiteralPath $stderr) { Get-Content -Raw -LiteralPath $stderr } else { '' }
    $all = $out + "`n" + $err
    $markerRegex = '(?m)^C1_R1_MICROSTYLE_CNN_TOP_DWCACHE_PROXY_SYNTH_PASS\s+.*$'
    $matches = [regex]::Matches($out,$markerRegex)
    if ($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened') {
        throw 'Vivado reported synthesis failure'
    }
    if ($matches.Count -ne 1) { throw 'proxy synthesis marker missing or duplicated' }
    $marker = $matches[0].Value.Trim()
    $utilPath = Join-Path $runRoot 'reports\utilization.rpt'
    $timingPath = Join-Path $runRoot 'reports\timing.rpt'
    if (-not (Test-Path -LiteralPath $utilPath) -or
        -not (Test-Path -LiteralPath $timingPath)) {
        throw 'Vivado reports were not generated'
    }
    $util = Get-Content -Raw -LiteralPath $utilPath
    $timing = Get-Timing (Get-Content -Raw -LiteralPath $timingPath)
    $metrics = [ordered]@{
        part = 'xc7a200tsbg484-1'; clock_mhz = 100
        cache_dw_weight_tiles = $CacheDwWeightTiles
        pipelined_dot_tree = $PipelinedDotTree
        pipelined_dot_tree_full = $PipelinedDotTreeFull
        pipelined_descriptor_replay = $PipelinedDescriptorReplay
        prevalidate_descriptor_replay = $PrevalidateDescriptorReplay
        mac_prefetch_overlap = $MacPrefetchOverlap
        packed_affine_cache = $PackedAffineCache
        luts = Get-Metric $util 'Slice LUTs*'
        registers = Get-Metric $util 'Slice Registers'
        bram_tiles = Get-Metric $util 'Block RAM Tile'
        dsps = Get-Metric $util 'DSPs'
        wns_ns = $timing.wns_ns; tns_ns = $timing.tns_ns
        timing_met = ($null -ne $timing.wns_ns -and $timing.wns_ns -ge 0.0)
        marker = $marker
    }
    [ordered]@{ run_id=$RunId; state='complete'; marker=$marker;
                metrics=$metrics } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop()
    Write-Status 'complete' 'done' 0 $marker $metrics
} catch {
    $watch.Stop()
    # Keep only a bounded diagnostic tail; the full Vivado files live only in
    # the private runRoot and are removed below.  This makes setup/Tcl errors
    # debuggable without retaining a multi-megabyte synthesis transcript.
    $diag = [System.Collections.Generic.List[string]]::new()
    $diag.Add($_.Exception.Message)
    foreach ($logFile in @($stdout,$stderr)) {
        if ($logFile -and (Test-Path -LiteralPath $logFile)) {
            $diag.Add("--- $([IO.Path]::GetFileName($logFile)) tail ---")
            foreach ($line in (Get-Content -LiteralPath $logFile -Tail 80)) {
                $diag.Add([string]$line)
            }
        }
    }
    $diagText = ($diag -join "`r`n")
    if ($diagText.Length -gt 8192) {
        $diagText = $diagText.Substring($diagText.Length - 8192)
    }
    $diagText | Set-Content -LiteralPath (Join-Path $runLogRoot 'failure_tail.log') -Encoding UTF8
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
