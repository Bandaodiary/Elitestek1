param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$BeatMode,
    [switch]$PlaceRoute,
    [switch]$RelaxedDescriptor,
    [switch]$PipelinedAddress,
    [switch]$PipelinedDescriptorValidation,
    [switch]$NarrowDescriptorSizeCheck,
    [switch]$PipelinedDescriptorSizeArith,
    [switch]$FixedDescriptorSizeLimits,
    [switch]$PipelinedDescriptorPixelCount,
    [switch]$IterativeDescriptorPixelCount,
    [switch]$PreclampedTapCoords,
    [switch]$KeepDescriptorSizeOperands,
    [switch]$FastTensorAddressArithmetic,
    [switch]$PipelinedTensorPixelIndex,
    [switch]$RegisterAbortReset,
    [switch]$PipelinedDotTreeFull,
    [switch]$PipelinedDecoderValidation,
    [switch]$RegisterFatalTicket,
    [switch]$ReplicateAbortControl,
    [switch]$UseRuntimeCache
)

# WMI creates the worker outside the caller's Windows Job.  Vivado and any
# helper it starts therefore survive a Codex/desktop job interruption.  The
# worker uses an in-memory Vivado project and deletes its complete temporary
# runRoot after extracting bounded diagnostics.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
$runtimeCacheRoot = Join-Path $caseRoot '_vivado_rt_cache_tensor_burst_proxy'
$runtimeCacheLockPath = Join-Path $caseRoot '_vivado_rt_cache_tensor_burst_proxy.lock'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'RunId contains unsupported characters'
    }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId" + $(if ($BeatMode) { ' -BeatMode' } else { '' }) +
        $(if ($PlaceRoute) { ' -PlaceRoute' } else { '' }) +
        $(if ($RelaxedDescriptor) { ' -RelaxedDescriptor' } else { '' }) +
        $(if ($PipelinedAddress) { ' -PipelinedAddress' } else { '' }) +
        $(if ($PipelinedDescriptorValidation) { ' -PipelinedDescriptorValidation' } else { '' }) +
        $(if ($NarrowDescriptorSizeCheck) { ' -NarrowDescriptorSizeCheck' } else { '' }) +
        $(if ($PipelinedDescriptorSizeArith) { ' -PipelinedDescriptorSizeArith' } else { '' }) +
        $(if ($FixedDescriptorSizeLimits) { ' -FixedDescriptorSizeLimits' } else { '' }) +
        $(if ($PipelinedDescriptorPixelCount) { ' -PipelinedDescriptorPixelCount' } else { '' }) +
        $(if ($IterativeDescriptorPixelCount) { ' -IterativeDescriptorPixelCount' } else { '' }) +
        $(if ($PreclampedTapCoords) { ' -PreclampedTapCoords' } else { '' }) +
        $(if ($KeepDescriptorSizeOperands) { ' -KeepDescriptorSizeOperands' } else { '' }) +
        $(if ($FastTensorAddressArithmetic) { ' -FastTensorAddressArithmetic' } else { '' }) +
        $(if ($PipelinedTensorPixelIndex) { ' -PipelinedTensorPixelIndex' } else { '' }) +
        $(if ($RegisterAbortReset) { ' -RegisterAbortReset' } else { '' }) +
        $(if ($PipelinedDotTreeFull) { ' -PipelinedDotTreeFull' } else { '' }) +
        $(if ($PipelinedDecoderValidation) { ' -PipelinedDecoderValidation' } else { '' }) +
        $(if ($RegisterFatalTicket) { ' -RegisterFatalTicket' } else { '' }) +
        $(if ($ReplicateAbortControl) { ' -ReplicateAbortControl' } else { '' }) +
        $(if ($UseRuntimeCache) { ' -UseRuntimeCache' } else { '' })
    # Prefer WMI because it creates the worker outside the caller's Windows
    # Job.  Some managed desktops deny Win32_Process.Create, so fall back to
    # a tiny CreateProcess(CREATE_BREAKAWAY_FROM_JOB) helper.  The fallback
    # still leaves Vivado/xsim independent of this shell/job.
    $workerPid = $null
    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
        if ($result.ReturnValue -eq 0) { $workerPid = [int]$result.ProcessId }
    } catch {
        $result = $null
    }
    if ($null -eq $workerPid) {
        $launcher = Join-Path $PSScriptRoot 'start_detached_process.ps1'
        $launcherOutput = & $powerShell -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $launcher -CommandLine $commandLine `
            -CurrentDirectory $caseRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "detached process fallback failed: $($launcherOutput -join ' ')"
        }
        try { $workerPid = [int](($launcherOutput | Select-Object -Last 1).ToString().Trim()) }
        catch { throw "detached process fallback returned invalid pid: $($launcherOutput -join ' ')" }
    }
    [ordered]@{
        run_id = $RunId
        mode = if ($BeatMode) { 'beat' } else { 'logical' }
        implementation = if ($PlaceRoute) { 'place_route' } else { 'synthesis' }
        descriptor_validation = if ($RelaxedDescriptor) { 'relaxed' } else { 'strict' }
        pipelined_address = if ($PipelinedAddress) { 1 } else { 0 }
        pipelined_descriptor_validation = if ($PipelinedDescriptorValidation) { 1 } else { 0 }
        narrow_descriptor_size_check = if ($NarrowDescriptorSizeCheck) { 1 } else { 0 }
        pipelined_descriptor_size_arith = if ($PipelinedDescriptorSizeArith) { 1 } else { 0 }
        fixed_descriptor_size_limits = if ($FixedDescriptorSizeLimits) { 1 } else { 0 }
        pipelined_descriptor_pixel_count = if ($PipelinedDescriptorPixelCount) { 1 } else { 0 }
        iterative_descriptor_pixel_count = if ($IterativeDescriptorPixelCount) { 1 } else { 0 }
        preclamped_tap_coords = if ($PreclampedTapCoords) { 1 } else { 0 }
        keep_descriptor_size_operands = if ($KeepDescriptorSizeOperands) { 1 } else { 0 }
        fast_tensor_address_arith = if ($FastTensorAddressArithmetic) { 1 } else { 0 }
        pipelined_tensor_pixel_index = if ($PipelinedTensorPixelIndex) { 1 } else { 0 }
        register_abort_reset = if ($RegisterAbortReset) { 1 } else { 0 }
        pipelined_dot_tree_full = if ($PipelinedDotTreeFull) { 1 } else { 0 }
        pipelined_decoder_validation = if ($PipelinedDecoderValidation) { 1 } else { 0 }
        register_fatal_ticket = if ($RegisterFatalTicket) { 1 } else { 0 }
        replicate_abort_control = if ($ReplicateAbortControl) { 1 } else { 0 }
        use_runtime_cache = if ($UseRuntimeCache) { 1 } else { 0 }
        rsp_fifo_depth = if ($BeatMode) { 64 } else { 128 }
        worker_pid = $workerPid
        status_path = (Join-Path $logRoot "portable_soc_tensor_burst_proxy_runs\$RunId\status.json")
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

$modeName = if ($BeatMode) { 'beat' } else { 'logical' }
$implementationName = if ($PlaceRoute) { 'place_route' } else { 'synthesis' }
$descriptorValidationName = if ($RelaxedDescriptor) { 'relaxed' } else { 'strict' }
$pipelinedAddressEnabled = if ($PipelinedAddress) { 1 } else { 0 }
$pipelinedDescriptorValidationEnabled = if ($PipelinedDescriptorValidation) { 1 } else { 0 }
$narrowDescriptorSizeCheckEnabled = if ($NarrowDescriptorSizeCheck) { 1 } else { 0 }
$pipelinedDescriptorSizeArithEnabled = if ($PipelinedDescriptorSizeArith) { 1 } else { 0 }
$fixedDescriptorSizeLimitsEnabled = if ($FixedDescriptorSizeLimits) { 1 } else { 0 }
$pipelinedDescriptorPixelCountEnabled = if ($PipelinedDescriptorPixelCount) { 1 } else { 0 }
$iterativeDescriptorPixelCountEnabled = if ($IterativeDescriptorPixelCount) { 1 } else { 0 }
$preclampedTapCoordsEnabled = if ($PreclampedTapCoords) { 1 } else { 0 }
$keepDescriptorSizeOperandsEnabled = if ($KeepDescriptorSizeOperands) { 1 } else { 0 }
$fastTensorAddressArithEnabled = if ($FastTensorAddressArithmetic) { 1 } else { 0 }
$pipelinedTensorPixelIndexEnabled = if ($PipelinedTensorPixelIndex) { 1 } else { 0 }
$registerAbortResetEnabled = if ($RegisterAbortReset) { 1 } else { 0 }
$pipelinedDotTreeFullEnabled = if ($PipelinedDotTreeFull) { 1 } else { 0 }
$pipelinedDecoderValidationEnabled = if ($PipelinedDecoderValidation) { 1 } else { 0 }
$registerFatalTicketEnabled = if ($RegisterFatalTicket) { 1 } else { 0 }
$replicateAbortControlEnabled = if ($ReplicateAbortControl) { 1 } else { 0 }
$useRuntimeCacheEnabled = if ($UseRuntimeCache) { 1 } else { 0 }
$runRoot = Join-Path $simRoot "portable_soc_tensor_burst_proxy_run_$RunId"
$runLogRoot = Join-Path $logRoot "portable_soc_tensor_burst_proxy_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'portable_soc_tensor_burst_proxy_status.json'
$reportLogRoot = Join-Path $runLogRoot 'reports'
$summaryPath = Join-Path $runLogRoot 'summary.json'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$vivado = Join-Path $vivadoRoot 'bin\vivado.bat'
$vivadoRtScripts = Join-Path $vivadoRoot 'scripts\rt'
$tcl = Join-Path $PSScriptRoot 'synth_portable_soc_tensor_burst_proxy.tcl'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:currentStep = 'setup'

New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Set-StatusContent {
    param([string]$Path, [string]$Value)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $Value | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
            return
        } catch [IO.IOException] {
            if ($attempt -eq 19) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode, [string]$Message)
    $value = [ordered]@{
        run_id = $RunId
        mode = $modeName
        implementation = $implementationName
        descriptor_validation = $descriptorValidationName
        pipelined_address = $pipelinedAddressEnabled
        pipelined_descriptor_validation = $pipelinedDescriptorValidationEnabled
        narrow_descriptor_size_check = $narrowDescriptorSizeCheckEnabled
        pipelined_descriptor_size_arith = $pipelinedDescriptorSizeArithEnabled
        fixed_descriptor_size_limits = $fixedDescriptorSizeLimitsEnabled
        pipelined_descriptor_pixel_count = $pipelinedDescriptorPixelCountEnabled
        iterative_descriptor_pixel_count = $iterativeDescriptorPixelCountEnabled
        preclamped_tap_coords = $preclampedTapCoordsEnabled
        keep_descriptor_size_operands = $keepDescriptorSizeOperandsEnabled
        fast_tensor_address_arith = $fastTensorAddressArithEnabled
        pipelined_tensor_pixel_index = $pipelinedTensorPixelIndexEnabled
        register_abort_reset = $registerAbortResetEnabled
        pipelined_dot_tree_full = $pipelinedDotTreeFullEnabled
        pipelined_decoder_validation = $pipelinedDecoderValidationEnabled
        register_fatal_ticket = $registerFatalTicketEnabled
        replicate_abort_control = $replicateAbortControlEnabled
        use_runtime_cache = $useRuntimeCacheEnabled
        state = $State
        step = $Step
        exit_code = $ExitCode
        message = $Message
        process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot
        report_directory = $reportLogRoot
        summary_path = $summaryPath
        temporary_run_root = $runRoot
        runtime_cache_root = $runtimeCacheRoot
        rsp_fifo_depth = if ($BeatMode) { 64 } else { 128 }
    } | ConvertTo-Json
    Set-StatusContent $statusPath $value
    Set-StatusContent $latestStatusPath $value
}

function Save-CompactLog {
    param([string]$Source, [string]$Destination, [string]$Marker = '')
    $lines = @()
    if (Test-Path -LiteralPath $Source) {
        if ($Marker) {
            $lines += @(Select-String -LiteralPath $Source -Pattern ([regex]::Escape($Marker)) `
                -AllMatches -ErrorAction SilentlyContinue | ForEach-Object { $_.Line })
        }
        # Keep only a bounded tail; do not load a potentially large native log
        # into the PowerShell process.
        $lines += @(Get-Content -LiteralPath $Source -Tail 80 -ErrorAction SilentlyContinue)
    }
    if ($lines.Count -eq 0) { $lines = @('(empty)') }
    $lines | Select-Object -Unique | Set-Content -LiteralPath $Destination -Encoding UTF8
}

function Save-CompactReport {
    param([string]$Source, [string]$Destination)
    $lines = @()
    if (Test-Path -LiteralPath $Source) {
        # Utilization/timing reports place the useful totals in the middle;
        # select only compact summary rows and append a short tail.
        $patterns = @(
            'Timing Summary', 'WNS', 'TNS', 'WHS', 'THS',
            'Slice LUTs', 'Slice Registers', 'Block RAM Tile', 'DSPs',
            'URAM', 'CARRY', 'F7', 'F8', 'C1_PORTABLE_SOC_TENSOR_BURST')
        foreach ($pattern in $patterns) {
            $lines += @(Select-String -LiteralPath $Source -Pattern $pattern `
                -SimpleMatch -ErrorAction SilentlyContinue | ForEach-Object { $_.Line })
        }
        $lines += @(Get-Content -LiteralPath $Source -Tail 24 -ErrorAction SilentlyContinue)
    }
    if ($lines.Count -eq 0) { $lines = @('(empty)') }
    $lines | Select-Object -Unique | Select-Object -First 160 |
        Set-Content -LiteralPath $Destination -Encoding UTF8
}

function Get-UtilMetric {
    param([string]$Source, [string]$Label)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $null }
    $pattern = '^\|\s*' + [regex]::Escape($Label) + '\*?\s*\|\s*([0-9,]+(?:\.[0-9]+)?)\s*\|'
    $hit = Select-String -LiteralPath $Source -Pattern $pattern -AllMatches `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $hit -and $hit.Matches.Count -gt 0) {
        return [double](($hit.Matches[0].Groups[1].Value) -replace ',', '')
    }
    return $null
}

function Get-TimingMetric {
    param([string]$SummarySource, [string]$PathSource)
    $wnsValues = @()
    $tnsValues = @()
    if (Test-Path -LiteralPath $SummarySource -PathType Leaf) {
        # Match only actual clock-summary rows.  A generic "first numeric
        # line after the header" can accidentally consume a path-detail value
        # (which previously made a severely negative design look positive).
        $inClockTable = $false
        foreach ($line in @(Get-Content -LiteralPath $SummarySource -TotalCount 1200 `
                               -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*Clock\s+WNS\(ns\)\s+TNS\(ns\)') {
                $inClockTable = $true
                continue
            }
            if ($inClockTable) {
                $m = [regex]::Match($line, '^\s*[A-Za-z_][A-Za-z0-9_]*\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if ($m.Success) {
                    $wnsValues += [double]$m.Groups[1].Value
                    $tnsValues += [double]$m.Groups[2].Value
                    continue
                }
                # Once the table has started, a non-row separator/header after
                # at least one row closes it; later path-detail numbers are
                # not timing-summary metrics.
                if ($wnsValues.Count -gt 0 -and $line -match '^\s*$') { break }
            }
        }
    }
    if ($wnsValues.Count -gt 0) {
        $minWns = ($wnsValues | Measure-Object -Minimum).Minimum
        $sumTns = ($tnsValues | Measure-Object -Sum).Sum
        return [ordered]@{wns_ns=[double]$minWns; tns_ns=[double]$sumTns}
    }
    # Fall back to the first reported worst-path slack.  This keeps the
    # summary truthful even if Vivado emits an abbreviated clock table.
    if (Test-Path -LiteralPath $PathSource -PathType Leaf) {
        $hit = Select-String -LiteralPath $PathSource -Pattern '^\s*slack\s+([-+]?[0-9]+(?:\.[0-9]+)?)' `
            -AllMatches -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $hit -and $hit.Matches.Count -gt 0) {
            return [ordered]@{wns_ns=[double]$hit.Matches[0].Groups[1].Value; tns_ns=$null}
        }
    }
    return [ordered]@{wns_ns=$null; tns_ns=$null}
}

function Remove-RunRoot {
    if (-not (Test-Path -LiteralPath $runRoot)) {
        return [ordered]@{files=0; bytes=0}
    }
    $resolvedRun = (Resolve-Path -LiteralPath $runRoot).Path
    $resolvedSim = (Resolve-Path -LiteralPath $simRoot).Path
    if (-not $resolvedRun.StartsWith(
            $resolvedSim + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to remove path outside sim: $resolvedRun"
    }
    $files = @(Get-ChildItem -LiteralPath $resolvedRun -Recurse -File -ErrorAction SilentlyContinue)
    $bytes = [int64](($files | Measure-Object Length -Sum).Sum)
    # Vivado can release a last report handle a few milliseconds after the
    # batch process exits.  Retry a bounded number of times, then surface a
    # cleanup failure instead of claiming that a large run tree was removed.
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            Remove-Item -LiteralPath $resolvedRun -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $resolvedRun)) {
                return [ordered]@{files=$files.Count; bytes=$bytes}
            }
        } catch {
            if ($attempt -eq 19) { throw }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "runRoot cleanup did not remove $resolvedRun"
}

function Test-RuntimeCacheComplete {
    param([string]$Root)
    # A ready marker is written only after the complete tree has been copied,
    # hydrated and prewarmed.  Checking it before every run lets concurrent
    # workers reuse a stable cache instead of truncating files in place.
    $ready = Join-Path $Root '.c1_runtime_ready'
    if (-not (Test-Path -LiteralPath $ready -PathType Leaf)) { return $false }
    try {
        $readyText = Get-Content -LiteralPath $ready -Raw -ErrorAction Stop
        if ($readyText -notmatch '(?m)^version=2\s*$') { return $false }
    } catch {
        return $false
    }
    $sentinels = @(
        (Join-Path $Root 'scripts\rt\data\common.tcl'),
        (Join-Path $Root 'scripts\rt\data\lib_core.tcl'),
        (Join-Path $Root 'scripts\rt\data\unimacro\unimacro_verilog.tcl'),
        (Join-Path $Root 'scripts\rt\data\unimacro\unimacro_vhdl.tcl'),
        (Join-Path $Root 'scripts\rt\fpga_tcl\rtSynthParallelPrep.tcl'))
    foreach ($sentinel in $sentinels) {
        if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) { return $false }
        try {
            $item = Get-Item -LiteralPath $sentinel -ErrorAction Stop
            # ReparsePoint/Offline are available on the Windows PowerShell
            # .NET runtime used by the detached worker.  Do not reference the
            # newer RecallOn* enum members directly: they are absent on .NET
            # Framework and would make an otherwise complete cache fail here.
            $cloudFlags = [IO.FileAttributes]::ReparsePoint -bor
                          [IO.FileAttributes]::Offline
            if (($item.Length -le 0) -or (($item.Attributes -band $cloudFlags) -ne 0)) {
                return $false
            }
        } catch {
            return $false
        }
    }
    return $true
}

function Prewarm-RuntimeTcl {
    param([string]$Root, [byte[]]$Buffer)
    $rtRoot = Join-Path $Root 'scripts\rt'
    if (-not (Test-Path -LiteralPath $rtRoot -PathType Container)) {
        throw "Vivado runtime tree missing for prewarm: $rtRoot"
    }
    # Opening each Tcl file forces any cloud/on-demand backing file local before
    # Vivado's detached child starts.  Streams are closed per file so the cache
    # never accumulates handles while a long proxy run is active.
    Get-ChildItem -LiteralPath $rtRoot -Filter '*.tcl' -File -Recurse |
        ForEach-Object {
            $stream = $null
            try {
                $stream = [IO.File]::OpenRead($_.FullName)
                while ($stream.Read($Buffer, 0, $Buffer.Length) -gt 0) {}
            } finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
    # Keep the known helper sentinels explicit as well.  Some cloud providers
    # omit placeholder files from a wildcard enumeration even though a direct
    # open can hydrate them.
    $critical = @(
        (Join-Path $rtRoot 'data\common.tcl'),
        (Join-Path $rtRoot 'data\lib_core.tcl'),
        (Join-Path $rtRoot 'data\unimacro\unimacro_verilog.tcl'),
        (Join-Path $rtRoot 'data\unimacro\unimacro_vhdl.tcl'),
        (Join-Path $rtRoot 'fpga_tcl\rtSynthParallelPrep.tcl'))
    foreach ($path in $critical) {
        $stream = $null
        try {
            $stream = [IO.File]::OpenRead($path)
            while ($stream.Read($Buffer, 0, $Buffer.Length) -gt 0) {}
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
}

function Confirm-RuntimeCacheReadable {
    param(
        [string]$Root,
        [byte[]]$Buffer,
        [int]$Attempts = 20,
        [int]$DelayMilliseconds = 100
    )
    # A directory rename is atomic from the namespace perspective, but on
    # Windows/OneDrive-backed volumes a child file can take a short interval to
    # become readable by a newly-created Vivado process.  Re-open the complete
    # tree in a bounded loop before the worker proceeds to Vivado.  This is
    # deliberately a read-only gate: it never rewrites a published cache.
    $lastError = $null
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            if (Test-RuntimeCacheComplete $Root) {
                Prewarm-RuntimeTcl $Root $Buffer
                return
            }
        } catch {
            $lastError = $_.Exception
        }
        if ($attempt + 1 -lt $Attempts) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
    if ($lastError) {
        throw "Vivado runtime cache did not become readable: $Root ($($lastError.Message))"
    }
    throw "Vivado runtime cache did not become readable: $Root"
}

function Write-RuntimeReadyMarker {
    param([string]$Path, [string]$Source)
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Create,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $payload = [Text.Encoding]::ASCII.GetBytes("version=2`nsource=$Source`n")
        $stream.Write($payload, 0, $payload.Length)
        # Flush through the OS before publishing the containing directory.  The
        # boolean overload is supported by the .NET Framework FileStream used by
        # the detached Windows PowerShell worker.
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Set-NativeVivadoRuntime {
    # Use the installation tree for Vivado itself.  This is the safe default:
    # the runtime's unimacro scripts resolve additional files below the full
    # Vivado data/ tree, which is intentionally not duplicated in the small
    # case-local cache.
    $nativeRt = $vivadoRtScripts
    if (-not (Test-Path -LiteralPath $nativeRt -PathType Container)) {
        throw "Vivado native runtime tree missing: $nativeRt"
    }
    $env:XILINX_VIVADO = $vivadoRoot
    $env:RDI_APPROOT = $vivadoRoot
    Remove-Item -LiteralPath 'Env:RDI_PATCHROOT' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'Env:XILINX_PATH' -ErrorAction SilentlyContinue
    $env:RT_LIBPATH = Join-Path $nativeRt 'data'
    $env:SYNTH_COMMON = $env:RT_LIBPATH
    $env:RT_TCL_PATH = Join-Path $nativeRt 'base_tcl\tcl'
    # Avoid an inherited cache data root affecting retarget/unimacro fallback
    # lookups when BUILTIN_SYNTH is not set.
    $env:RDI_DATADIR = Join-Path $vivadoRoot 'data'
}

function Stage-VivadoRuntime {
    # Build a complete runtime tree privately, then publish it with one
    # directory rename.  A per-case lock serializes workers across detached
    # PowerShell processes; without it, one worker could truncate a sentinel
    # while another Vivado process was resolving the same path.
    $sourceRt = $vivadoRtScripts
    $buffer = New-Object byte[] 65536
    $lockStream = $null
    $buildRoot = $null
    $oldRoot = $null
    $stageRoot = $runtimeCacheRoot
    try {
        for ($attempt = 0; $attempt -lt 240; $attempt++) {
            try {
                $lockStream = [IO.File]::Open($runtimeCacheLockPath,
                    [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
                    [IO.FileShare]::None)
                break
            } catch [IO.IOException] {
                if ($attempt -eq 239) {
                    throw "timed out acquiring Vivado runtime cache lock: $runtimeCacheLockPath"
                }
                Start-Sleep -Milliseconds 250
            }
        }
        if ($null -eq $lockStream) {
            throw "failed to acquire Vivado runtime cache lock: $runtimeCacheLockPath"
        }

        if (-not (Test-RuntimeCacheComplete $runtimeCacheRoot)) {
            $buildRoot = Join-Path $caseRoot (
                '_vivado_rt_cache_tensor_burst_proxy.build_{0}_{1}' -f
                $PID, ([guid]::NewGuid().ToString('N')))
            $stageRoot = $buildRoot
            $stageRt = Join-Path $stageRoot 'scripts\rt'
            New-Item -ItemType Directory -Force -Path $stageRt | Out-Null

            foreach ($name in @('data', 'fpga_tcl', 'base_tcl')) {
                $source = Join-Path $sourceRt $name
                if (-not (Test-Path -LiteralPath $source -PathType Container)) {
                    throw "Vivado runtime source directory missing: $source"
                }
                Get-ChildItem -LiteralPath $source -File -Recurse | ForEach-Object {
                    $relative = $_.FullName.Substring($source.Length + 1)
                    $destination = Join-Path (Join-Path $stageRt $name) $relative
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                    $inputStream = [IO.File]::OpenRead($_.FullName)
                    $outputStream = [IO.File]::Open($destination, [IO.FileMode]::Create,
                        [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try {
                        $inputStream.CopyTo($outputStream)
                        $outputStream.Flush($true)
                    } finally {
                        $outputStream.Dispose()
                        $inputStream.Dispose()
                    }
                }
            }

            # Explicitly hydrate the small files most often exposed as cloud
            # placeholders.  These copies occur only in the private build tree,
            # never in the tree that a running Vivado process can observe.
            $criticalFiles = @(
                @{source=(Join-Path $sourceRt 'data\lib_core.tcl');
                  destination=(Join-Path $stageRt 'data\lib_core.tcl')},
                @{source=(Join-Path $sourceRt 'data\unimacro\unimacro_vhdl.tcl');
                  destination=(Join-Path $stageRt 'data\unimacro\unimacro_vhdl.tcl')},
                @{source=(Join-Path $sourceRt 'data\unimacro\unimacro_verilog.tcl');
                  destination=(Join-Path $stageRt 'data\unimacro\unimacro_verilog.tcl')})
            foreach ($critical in $criticalFiles) {
                if (-not (Test-Path -LiteralPath $critical.source -PathType Leaf)) {
                    throw "Vivado runtime source missing: $($critical.source)"
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $critical.destination) |
                    Out-Null
                $inputStream = [IO.File]::OpenRead($critical.source)
                $outputStream = [IO.File]::Open($critical.destination, [IO.FileMode]::Create,
                    [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $inputStream.CopyTo($outputStream)
                    $outputStream.Flush($true)
                } finally {
                    $outputStream.Dispose()
                    $inputStream.Dispose()
                }
                $criticalInfo = Get-Item -LiteralPath $critical.destination -ErrorAction Stop
                $criticalInfo.Attributes = [IO.FileAttributes]::Normal
                if ($criticalInfo.Length -le 0) {
                    throw "Vivado runtime staged file is empty: $($critical.destination)"
                }
            }

            Get-ChildItem -LiteralPath $stageRoot -Recurse -File |
                ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
            Prewarm-RuntimeTcl $stageRoot $buffer
            $readyPath = Join-Path $stageRoot '.c1_runtime_ready'
            Write-RuntimeReadyMarker $readyPath $sourceRt
            (Get-Item -LiteralPath $readyPath -ErrorAction Stop).Attributes =
                [IO.FileAttributes]::Normal
            if (-not (Test-RuntimeCacheComplete $stageRoot)) {
                throw "private Vivado runtime build failed completeness check: $stageRoot"
            }

            # Replace an incomplete prior cache only after the new tree is
            # complete.  Directory.Move stays on one volume and exposes the
            # published tree as a whole; all other workers hold the lock.
            if (Test-Path -LiteralPath $runtimeCacheRoot) {
                if (-not (Test-Path -LiteralPath $runtimeCacheRoot -PathType Container)) {
                    throw "Vivado runtime cache path is not a directory: $runtimeCacheRoot"
                }
                $oldRoot = Join-Path $caseRoot (
                    '_vivado_rt_cache_tensor_burst_proxy.old_{0}_{1}' -f
                    $PID, ([guid]::NewGuid().ToString('N')))
                [IO.Directory]::Move($runtimeCacheRoot, $oldRoot)
            }
            try {
                [IO.Directory]::Move($buildRoot, $runtimeCacheRoot)
                $buildRoot = $null
            } catch {
                if ($oldRoot -and (Test-Path -LiteralPath $oldRoot) -and
                    -not (Test-Path -LiteralPath $runtimeCacheRoot)) {
                    [IO.Directory]::Move($oldRoot, $runtimeCacheRoot)
                    $oldRoot = $null
                }
                throw
            }
            if ($oldRoot -and (Test-Path -LiteralPath $oldRoot)) {
                Remove-Item -LiteralPath $oldRoot -Recurse -Force -ErrorAction Stop
                $oldRoot = $null
            }
            $stageRoot = $runtimeCacheRoot
        }

        # Revalidate after either cache reuse or atomic publication.  Prewarm
        # reads are deliberately retained, but no file is rewritten on reuse.
        #
        # The cache is retained as a durable, independently inspectable copy,
        # but Vivado must use its native runtime tree.  The staged tree contains
        # scripts/rt only; unimacro_vhdl/verilog.tcl subsequently ask
        # rdi::get_data_dir for the full Vivado data/vhdl and data/verilog trees.
        # Exporting this partial tree through RDI_PATCHROOT therefore fails with
        # "couldn't read ... unimacro*.tcl" even when its sentinel files are
        # readable.  Keep the native fallback explicit and local to this worker
        # so inherited caller variables cannot accidentally re-enable the broken
        # override.
        if (-not (Test-RuntimeCacheComplete $runtimeCacheRoot)) {
            throw "Vivado runtime cache is incomplete after staging: $runtimeCacheRoot"
        }
        $stageRoot = $runtimeCacheRoot
        $stageRt = Join-Path $stageRoot 'scripts\rt'
        Confirm-RuntimeCacheReadable $stageRoot $buffer
        Set-NativeVivadoRuntime
    } finally {
        if ($buildRoot -and (Test-Path -LiteralPath $buildRoot)) {
            Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($oldRoot -and (Test-Path -LiteralPath $oldRoot)) {
            Remove-Item -LiteralPath $oldRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }
    }
}

try {
    Write-Status running setup 0 "detached tensor burst proxy synthesis started (mode=$modeName)"
    if (-not (Test-Path -LiteralPath $vivado)) { throw "Vivado not found: $vivado" }
    if (-not (Test-Path -LiteralPath $tcl)) { throw "Tcl script not found: $tcl" }

    if ($UseRuntimeCache) {
        $script:currentStep = 'runtime_stage'
        Write-Status running runtime_stage 0 'staging Vivado runtime into persistent case-local cache (opt-in)'
        Stage-VivadoRuntime
    } else {
        $script:currentStep = 'runtime_native'
        Write-Status running runtime_native 0 'using native Vivado runtime (runtime cache disabled by default)'
        Set-NativeVivadoRuntime
    }

    $script:currentStep = 'vivado'
    Write-Status running vivado 0 "running full portable SoC burst proxy ($modeName)"
    $rawOut = Join-Path $runRoot 'vivado.stdout.raw.log'
    $rawErr = Join-Path $runRoot 'vivado.stderr.raw.log'
    $compactOut = Join-Path $runLogRoot 'vivado.stdout.log'
    $compactErr = Join-Path $runLogRoot 'vivado.stderr.log'
    $vivadoArgs = @('-mode', 'batch', '-nojournal', '-nolog', '-source', $tcl, '-notrace', '-tclargs')
    $vivadoArgs += if ($BeatMode) { 'BEAT_MODE' } else { 'LOGICAL' }
    if ($PlaceRoute) { $vivadoArgs += 'PLACE_ROUTE' }
    if ($RelaxedDescriptor) { $vivadoArgs += 'RELAXED_DESCRIPTOR' }
    if ($PipelinedAddress) { $vivadoArgs += 'PIPELINED_ADDRESS' }
    if ($PipelinedDescriptorValidation) { $vivadoArgs += 'PIPELINED_DESCRIPTOR_VALIDATION' }
    if ($NarrowDescriptorSizeCheck) { $vivadoArgs += 'NARROW_DESCRIPTOR_SIZE_CHECK' }
    if ($PipelinedDescriptorSizeArith) { $vivadoArgs += 'PIPELINED_DESCRIPTOR_SIZE_ARITH' }
    if ($FixedDescriptorSizeLimits) { $vivadoArgs += 'FIXED_DESCRIPTOR_SIZE_LIMITS' }
    if ($PipelinedDescriptorPixelCount) { $vivadoArgs += 'PIPELINED_DESCRIPTOR_PIXEL_COUNT' }
    if ($IterativeDescriptorPixelCount) { $vivadoArgs += 'ITERATIVE_DESCRIPTOR_PIXEL_COUNT' }
    if ($PreclampedTapCoords) { $vivadoArgs += 'PRECLAMPED_TAP_COORDS' }
    if ($KeepDescriptorSizeOperands) { $vivadoArgs += 'KEEP_DESCRIPTOR_SIZE_OPERANDS' }
    if ($FastTensorAddressArithmetic) { $vivadoArgs += 'FAST_TENSOR_ADDRESS_ARITH' }
    if ($PipelinedTensorPixelIndex) { $vivadoArgs += 'PIPELINED_TENSOR_PIXEL_INDEX' }
    if ($RegisterAbortReset) { $vivadoArgs += 'REGISTER_ABORT_RESET' }
    if ($PipelinedDotTreeFull) { $vivadoArgs += 'PIPELINED_DOT_TREE_FULL' }
    if ($PipelinedDecoderValidation) { $vivadoArgs += 'PIPELINED_DECODER_VALIDATION' }
    if ($RegisterFatalTicket) { $vivadoArgs += 'REGISTER_FATAL_TICKET' }
    if ($ReplicateAbortControl) { $vivadoArgs += 'REPLICATE_ABORT_CONTROL' }
    $process = Start-Process -FilePath $vivado -ArgumentList $vivadoArgs `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr
    Save-CompactLog $rawOut $compactOut 'C1_PORTABLE_SOC_TENSOR_BURST_PROXY'
    Save-CompactLog $rawErr $compactErr
    if ($process.ExitCode -ne 0) { throw "Vivado failed with exit code $($process.ExitCode)" }

    $errorPattern = '(?im)^\s*(ERROR|FATAL):|\bFAIL(?:ED)?\b'
    if (Select-String -LiteralPath $rawOut -Pattern $errorPattern -Quiet -ErrorAction SilentlyContinue) {
        throw 'Vivado stdout contains ERROR/FATAL/FAIL diagnostics'
    }
    if (Select-String -LiteralPath $rawErr -Pattern $errorPattern -Quiet -ErrorAction SilentlyContinue) {
        throw 'Vivado stderr contains ERROR/FATAL/FAIL diagnostics'
    }
    $passMarker = 'C1_PORTABLE_SOC_TENSOR_BURST_PROXY_PASS'
    $finalMarker = 'C1_PORTABLE_SOC_TENSOR_BURST_PROXY_SYNTH_PASS'
    $passCount = @(Select-String -LiteralPath $rawOut -Pattern ([regex]::Escape($passMarker)) `
        -AllMatches -ErrorAction SilentlyContinue).Count
    $finalCount = @(Select-String -LiteralPath $rawOut -Pattern ([regex]::Escape($finalMarker)) `
        -AllMatches -ErrorAction SilentlyContinue).Count
    if ($passCount -ne 1) { throw "missing unique proxy PASS marker count=$passCount" }
    if ($finalCount -ne 1) { throw "missing unique final proxy PASS marker count=$finalCount" }

    New-Item -ItemType Directory -Force -Path $reportLogRoot | Out-Null
    $timingSuffix = if ($PlaceRoute) { 'placed' } else { 'synth' }
    foreach ($reportName in @(
        "tensor_burst_${modeName}_utilization_summary.rpt",
        "tensor_burst_${modeName}_utilization.rpt",
        "tensor_burst_${modeName}_${timingSuffix}_timing_summary.rpt",
        "tensor_burst_${modeName}_${timingSuffix}_timing.rpt")) {
        Save-CompactReport (Join-Path $runRoot "reports\$reportName") `
            (Join-Path $reportLogRoot $reportName)
    }
    $utilSummaryPath = Join-Path $runRoot "reports\tensor_burst_${modeName}_utilization_summary.rpt"
    $timingSummaryPath = Join-Path $runRoot "reports\tensor_burst_${modeName}_${timingSuffix}_timing_summary.rpt"
    $timingPathReport = Join-Path $runRoot "reports\tensor_burst_${modeName}_${timingSuffix}_timing.rpt"
    $timingMetrics = Get-TimingMetric $timingSummaryPath $timingPathReport
    $metrics = [ordered]@{
        part = 'xc7a200tsbg484-1'
        frame = '640x480'
        mode = $modeName
        implementation = $implementationName
        descriptor_validation = $descriptorValidationName
        pipelined_address = $pipelinedAddressEnabled
        pipelined_descriptor_validation = $pipelinedDescriptorValidationEnabled
        narrow_descriptor_size_check = $narrowDescriptorSizeCheckEnabled
        pipelined_descriptor_size_arith = $pipelinedDescriptorSizeArithEnabled
        fixed_descriptor_size_limits = $fixedDescriptorSizeLimitsEnabled
        pipelined_descriptor_pixel_count = $pipelinedDescriptorPixelCountEnabled
        iterative_descriptor_pixel_count = $iterativeDescriptorPixelCountEnabled
        keep_descriptor_size_operands = $keepDescriptorSizeOperandsEnabled
        fast_tensor_address_arith = $fastTensorAddressArithEnabled
        pipelined_tensor_pixel_index = $pipelinedTensorPixelIndexEnabled
        register_abort_reset = $registerAbortResetEnabled
        pipelined_dot_tree_full = $pipelinedDotTreeFullEnabled
        pipelined_decoder_validation = $pipelinedDecoderValidationEnabled
        register_fatal_ticket = $registerFatalTicketEnabled
        replicate_abort_control = $replicateAbortControlEnabled
        use_runtime_cache = $useRuntimeCacheEnabled
        beat_mode = if ($BeatMode) { 1 } else { 0 }
        rsp_fifo_depth = if ($BeatMode) { 64 } else { 128 }
        luts = Get-UtilMetric $utilSummaryPath 'Slice LUTs'
        registers = Get-UtilMetric $utilSummaryPath 'Slice Registers'
        bram_tiles = Get-UtilMetric $utilSummaryPath 'Block RAM Tile'
        dsps = Get-UtilMetric $utilSummaryPath 'DSPs'
        wns_ns = $timingMetrics.wns_ns
        tns_ns = $timingMetrics.tns_ns
        timing_met = ($null -ne $timingMetrics.wns_ns -and $timingMetrics.wns_ns -ge 0.0)
    }
    $metrics | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $cleanup = Remove-RunRoot
    $watch.Stop()
    $rspDepth = if ($BeatMode) { 64 } else { 128 }
    $beatFlag = if ($BeatMode) { 1 } else { 0 }
    $message = "C1_PORTABLE_SOC_TENSOR_BURST_PROXY_SYNTH_PASS mode=$modeName beat_mode=$beatFlag implementation=$implementationName descriptor_validation=$descriptorValidationName pipelined_address=$pipelinedAddressEnabled pipelined_tensor_pixel_index=$pipelinedTensorPixelIndexEnabled pipelined_descriptor_validation=$pipelinedDescriptorValidationEnabled pipelined_descriptor_size_arith=$pipelinedDescriptorSizeArithEnabled fixed_descriptor_size_limits=$fixedDescriptorSizeLimitsEnabled pipelined_descriptor_pixel_count=$pipelinedDescriptorPixelCountEnabled iterative_descriptor_pixel_count=$iterativeDescriptorPixelCountEnabled preclamped_tap_coords=$preclampedTapCoordsEnabled keep_descriptor_size_operands=$keepDescriptorSizeOperandsEnabled pipelined_dot_tree_full=$pipelinedDotTreeFullEnabled narrow_descriptor_size=$narrowDescriptorSizeCheckEnabled fast_tensor_address_arith=$fastTensorAddressArithEnabled register_abort_reset=$registerAbortResetEnabled register_fatal_ticket=$registerFatalTicketEnabled replicate_abort_control=$replicateAbortControlEnabled use_runtime_cache=$useRuntimeCacheEnabled runtime_env=native rsp_depth=$rspDepth display_fifo=0 cleaned_files=$($cleanup.files) cleaned_bytes=$($cleanup.bytes)"
    if ($metrics.timing_met) {
        Write-Status complete done 0 $message
    } else {
        Write-Status timing_failed done 2 ($message + "; timing_met=false; WNS=$($metrics.wns_ns) ns")
        exit 2
    }
} catch {
    $message = $_.Exception.Message
    try {
        $cleanup = Remove-RunRoot
        $message += "; cleaned_files=$($cleanup.files); cleaned_bytes=$($cleanup.bytes)"
    } catch {
        $message += "; cleanup_failed=$($_.Exception.Message)"
    }
    $watch.Stop()
    Write-Status failed $script:currentStep 1 $message
    exit 1
}
