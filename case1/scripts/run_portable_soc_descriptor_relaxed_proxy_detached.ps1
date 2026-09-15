param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$PipelinedAddress,
    [switch]$FastAddress,
    [switch]$PipelinedStartConfig,
    [switch]$PipelinedDotTree,
    [switch]$PipelinedDotTreeFull,
    [switch]$PipelinedDescriptorReplay,
    [switch]$PrevalidateDescriptorReplay,
    [switch]$ReplicateAbortControl,
      [switch]$TableResponseFifo,
      [switch]$DisableParallelHelper,
      [switch]$UnifiedOutputFifo,
      [switch]$UnifiedOutputSkid,
      [switch]$FabricReadResponseSkid,
      [switch]$RegisterFatalTicket
)

# WMI keeps this long Vivado synthesis outside the caller's Windows Job.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs'
if (-not $Worker) {
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    if ($PipelinedAddress) { $commandLine += ' -PipelinedAddress' }
    if ($FastAddress) { $commandLine += ' -FastAddress' }
    if ($PipelinedStartConfig) { $commandLine += ' -PipelinedStartConfig' }
    if ($PipelinedDotTree) { $commandLine += ' -PipelinedDotTree' }
    if ($PipelinedDotTreeFull) { $commandLine += ' -PipelinedDotTreeFull' }
    if ($PipelinedDescriptorReplay) { $commandLine += ' -PipelinedDescriptorReplay' }
    if ($PrevalidateDescriptorReplay) { $commandLine += ' -PrevalidateDescriptorReplay' }
    if ($ReplicateAbortControl) { $commandLine += ' -ReplicateAbortControl' }
    if ($TableResponseFifo) { $commandLine += ' -TableResponseFifo' }
    if ($DisableParallelHelper) { $commandLine += ' -DisableParallelHelper' }
    if ($UnifiedOutputFifo) { $commandLine += ' -UnifiedOutputFifo' }
    if ($UnifiedOutputSkid) { $commandLine += ' -UnifiedOutputSkid' }
    if ($FabricReadResponseSkid) { $commandLine += ' -FabricReadResponseSkid' }
    if ($RegisterFatalTicket) { $commandLine += ' -RegisterFatalTicket' }
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed with return value $($result.ReturnValue)" }
    [ordered]@{run_id=$RunId;worker_pid=[int]$result.ProcessId;
        status_path=(Join-Path $logRoot "portable_soc_descriptor_relaxed_runs\$RunId\status.json")} |
        ConvertTo-Json
    return
}
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
$runRoot = Join-Path $caseRoot "sim\portable_soc_descriptor_relaxed_run_$RunId"
$runLogRoot = Join-Path $logRoot "portable_soc_descriptor_relaxed_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'portable_soc_descriptor_relaxed_status.json'
$reportLogRoot = Join-Path $runLogRoot 'reports'
$runtimeCacheRoot = Join-Path $caseRoot '_vivado_rt_cache'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$vivado = Join-Path $vivadoRoot 'bin\vivado.bat'
$vivadoRtScripts = Join-Path $vivadoRoot 'scripts\rt'
$tcl = Join-Path $PSScriptRoot 'synth_portable_soc_descriptor_relaxed_proxy.tcl'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null
function Set-StatusContent([string]$Path,[string]$Value) {
    for($i=0;$i -lt 20;$i++){try{$Value|Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop;return}catch [IO.IOException]{if($i -eq 19){throw};Start-Sleep -Milliseconds 25}}
}
function Write-Status([string]$State,[string]$Step,[int]$ExitCode,[string]$Message) {
    $v=[ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$ExitCode;message=$Message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);updated=(Get-Date).ToString('o');log_directory=$runLogRoot;report_directory=$reportLogRoot}|ConvertTo-Json
    Set-StatusContent $statusPath $v;Set-StatusContent $latestStatusPath $v
}
function Remove-RunRoot {
    if (-not (Test-Path -LiteralPath $runRoot)) {
        return [ordered]@{files=0;bytes=0}
    }
    $resolvedRun = (Resolve-Path -LiteralPath $runRoot).Path
    $resolvedSim = (Resolve-Path -LiteralPath (Join-Path $caseRoot 'sim')).Path
    if (-not $resolvedRun.StartsWith(
            $resolvedSim + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to remove synthesis path outside sim: $resolvedRun"
    }
    $runFiles = @(Get-ChildItem -LiteralPath $resolvedRun -Recurse -File)
    $runBytes = [int64](($runFiles | Measure-Object Length -Sum).Sum)
    Remove-Item -LiteralPath $resolvedRun -Recurse -Force
    return [ordered]@{files=$runFiles.Count;bytes=$runBytes}
}
function Remove-RuntimeCache {
    if (-not (Test-Path -LiteralPath $runtimeCacheRoot)) {
        return [ordered]@{files=0;bytes=0}
    }
    $resolvedCache = (Resolve-Path -LiteralPath $runtimeCacheRoot).Path
    if (-not $resolvedCache.StartsWith(
            $caseRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to remove runtime cache outside case root: $resolvedCache"
    }
    $cacheFiles = @(Get-ChildItem -LiteralPath $resolvedCache -Recurse -File)
    $cacheBytes = [int64](($cacheFiles | Measure-Object Length -Sum).Sum)
    Remove-Item -LiteralPath $resolvedCache -Recurse -Force
    return [ordered]@{files=$cacheFiles.Count;bytes=$cacheBytes}
}
try {
    # Stage the small Vivado runtime tree into the workspace before launching
    # the detached helper.  Some files in the local installation are
    # on-demand/cloud placeholders; the helper can fail to open them even
    # when the parent process can.  A local Normal-attribute copy keeps this
    # synthesis run independent of that file-provider state.
    $env:XILINX_VIVADO = $vivadoRoot
    $env:RDI_APPROOT = $vivadoRoot
    # Use a short, non-hidden cache so an early Vivado runtime-provider failure
    # can retry without copying/hydrating about 45 MiB again.  Successful runs
    # remove the cache after preserving the reports.
    $env:RDI_PATCHROOT = $runtimeCacheRoot
    $env:XILINX_PATH = $env:RDI_PATCHROOT
    $sourceRt = Join-Path $vivadoRoot 'scripts\rt'
    $stageRt = Join-Path $env:RDI_PATCHROOT 'scripts\rt'
    $buf = New-Object byte[] 65536
    # The Vivado installation exposes several runtime files as cloud/on-demand
    # placeholders.  Copying and then pre-reading the disposable stage forces
    # them local before the detached helper starts.
    $stageSentinels = @(
        (Join-Path $stageRt 'data\common.tcl'),
        (Join-Path $stageRt 'data\unimacro\unimacro_verilog.tcl'),
        (Join-Path $stageRt 'fpga_tcl\rtSynthParallelPrep.tcl'))
    $stageComplete = $true
    foreach ($sentinel in $stageSentinels) {
        if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
            $stageComplete = $false
            break
        }
    }
    if (-not $stageComplete) {
        foreach ($name in @('data','fpga_tcl','base_tcl')) {
            $source = Join-Path $sourceRt $name
            $destination = Join-Path $stageRt $name
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
            Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
        }
    }
    foreach ($sentinel in $stageSentinels) {
        if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
            throw "Vivado runtime stage sentinel is missing: $sentinel"
        }
        # Force the on-demand provider to materialize the file before the
        # detached Vivado helper is launched.
        $s = [IO.File]::OpenRead($sentinel)
        while ($s.Read($buf, 0, $buf.Length) -gt 0) {}
        $s.Dispose()
    }
    Get-ChildItem -LiteralPath $env:RDI_PATCHROOT -Recurse -File |
        ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
    $env:RT_LIBPATH = Join-Path $stageRt 'data'
    $env:SYNTH_COMMON = $env:RT_LIBPATH
    $env:RT_TCL_PATH = Join-Path $stageRt 'base_tcl\tcl'
    $vivadoRtScripts = $stageRt
    Write-Status running prewarm 0 'pre-reading Vivado runtime Tcl files'
    Get-ChildItem -LiteralPath $vivadoRtScripts -Filter '*.tcl' -File -Recurse | ForEach-Object {$s=[IO.File]::OpenRead($_.FullName);while($s.Read($buf,0,$buf.Length)-gt 0){};$s.Dispose()}
    $s=[IO.File]::OpenRead((Join-Path $vivadoRtScripts 'fpga_tcl\rtSynthParallelPrep.tcl'));while($s.Read($buf,0,$buf.Length)-gt 0){};$s.Dispose()
    Write-Status running vivado 0 'detached relaxed descriptor proxy synthesis started'
    $out=Join-Path $runLogRoot 'vivado.stdout.log';$err=Join-Path $runLogRoot 'vivado.stderr.log'
    $vivadoArgs=@('-mode','batch','-nojournal','-nolog','-source',$tcl,'-notrace')
    $tclArgs=@()
    if ($PipelinedAddress) { $tclArgs += 'PIPELINED_ADDRESS' }
    if ($FastAddress) { $tclArgs += 'FAST_ADDRESS' }
    if ($PipelinedStartConfig) { $tclArgs += 'PIPELINED_START_CONFIG' }
    if ($PipelinedDotTree) { $tclArgs += 'PIPELINED_DOT_TREE' }
    if ($PipelinedDotTreeFull) { $tclArgs += 'PIPELINED_DOT_TREE_FULL' }
    if ($PipelinedDescriptorReplay) { $tclArgs += 'PIPELINED_DESCRIPTOR_REPLAY' }
    if ($PrevalidateDescriptorReplay) { $tclArgs += 'PREVALIDATE_DESCRIPTOR_REPLAY' }
    if ($ReplicateAbortControl) { $tclArgs += 'REPLICATE_ABORT_CONTROL' }
    if ($TableResponseFifo) { $tclArgs += 'TABLE_RESPONSE_FIFO' }
    if ($DisableParallelHelper) { $tclArgs += 'DISABLE_PARALLEL_HELPER' }
    if ($UnifiedOutputFifo) { $tclArgs += 'UNIFIED_OUTPUT_FIFO' }
    if ($UnifiedOutputSkid) { $tclArgs += 'UNIFIED_OUTPUT_SKID' }
    if ($FabricReadResponseSkid) { $tclArgs += 'FABRIC_READ_RESPONSE_SKID' }
    if ($RegisterFatalTicket) { $tclArgs += 'REGISTER_FATAL_TICKET' }
    if ($tclArgs.Count -gt 0) { $vivadoArgs += @('-tclargs') + $tclArgs }
    $p=Start-Process -FilePath $vivado -ArgumentList $vivadoArgs -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($p.ExitCode -ne 0){throw "Vivado failed with exit code $($p.ExitCode)"}
    $stdout=Get-Content -Raw -LiteralPath $out;$stderr=Get-Content -Raw -LiteralPath $err
    if(-not [string]::IsNullOrWhiteSpace($stderr)){throw 'Vivado wrote unexpected stderr'}
    if(($stdout+"`n"+$stderr)-match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b'){throw 'Vivado log contains ERROR/FATAL/FAIL diagnostics'}
    if([regex]::Matches($stdout,'C1_PORTABLE_SOC_DESCRIPTOR_RELAXED_PROXY_PASS').Count -ne 1){throw 'missing relaxed PASS marker'}
    if([regex]::Matches($stdout,'C1_PORTABLE_SOC_DESCRIPTOR_RELAXED_PROXY_SYNTH_PASS').Count -ne 1){throw 'missing relaxed final marker'}
    New-Item -ItemType Directory -Force -Path $reportLogRoot | Out-Null
    foreach ($reportName in @('relaxed_timing.rpt','relaxed_data_timing.rpt',
                              'relaxed_utilization.rpt')) {
        Copy-Item -LiteralPath (Join-Path $runRoot "reports\$reportName") `
            -Destination $reportLogRoot -Force
    }
    $runCleanup = Remove-RunRoot
    $cacheCleanup = Remove-RuntimeCache
    $watch.Stop()
    Write-Status complete done 0 ("C1_PORTABLE_SOC_DESCRIPTOR_RELAXED_PROXY_SYNTH_PASS frame=640x480; cleaned_files={0}; cleaned_bytes={1}" -f ($runCleanup.files+$cacheCleanup.files),($runCleanup.bytes+$cacheCleanup.bytes))
}catch{
    $failureMessage = $_.Exception.Message
    try {
        $runCleanup = Remove-RunRoot
        $failureMessage += "; cleaned_files=$($runCleanup.files); cleaned_bytes=$($runCleanup.bytes); runtime_cache_retained_for_retry"
    } catch {
        $failureMessage += "; cleanup_failed=$($_.Exception.Message)"
    }
    $watch.Stop()
    Write-Status failed vivado 1 $failureMessage
    exit 1
}
