param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Detached compact synthesis runner for the exact line-cache shell.  Vivado
# runs in a WMI-created process outside the interactive Windows job; the
# private runRoot (including the staged Vivado runtime) is deleted in finally.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs\window_line_cache_c8_exact_proxy_synth_runs'
$tcl = Join-Path $caseRoot 'scripts\synth_window_line_cache_c8_exact_burst_shell_proxy.tcl'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$vivado = Join-Path $vivadoRoot 'bin\vivado.bat'
$marker = 'C1_WINDOW_LINE_CACHE_C8_EXACT_BURST_SHELL_PROXY_SYNTH_PASS'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = 'exact_cache_shell_proxy_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    $statusPath = Join-Path $logRoot "$RunId\status.json"
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd = "`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
           "-WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine=$cmd; CurrentDirectory=$caseRoot }
    if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($r.ReturnValue)" }
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath} |
        ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "window_line_cache_c8_exact_proxy_synth_$RunId"
$runLog = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLog 'status.json'
$summaryPath = Join-Path $runLog 'summary.json'
$latestPath = Join-Path $logRoot 'latest_status.json'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog | Out-Null

function Write-Status([string]$State,[string]$Step,[int]$Code,[string]$Message,
                       [object]$Metrics=$null) {
    $o=[ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$Code;
        message=$Message;process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        log_directory=$runLog;summary_path=$summaryPath;metrics=$Metrics}
    ($o|ConvertTo-Json -Depth 8)|Set-Content -LiteralPath $statusPath -Encoding UTF8
    ($o|ConvertTo-Json -Depth 8)|Set-Content -LiteralPath $latestPath -Encoding UTF8
}
function Compact([string]$Raw,[string]$Out,[string]$Needle='') {
    $a=@()
    if(Test-Path -LiteralPath $Raw){
        if($Needle){$a+=@(Select-String -LiteralPath $Raw -Pattern ([regex]::Escape($Needle)) -ErrorAction SilentlyContinue|ForEach-Object{$_.Line})}
        $a+=@(Get-Content -LiteralPath $Raw -Tail 120 -ErrorAction SilentlyContinue)
    }
    if($a.Count -eq 0){$a=@('(empty)')}
    $a|Select-Object -Unique|Set-Content -LiteralPath $Out -Encoding UTF8
}
function Metric([string]$Text,[string]$Label){
    $m=[regex]::Match($Text,'(?m)^\|\s*'+[regex]::Escape($Label)+'\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*\|')
    if($m.Success){return [double]::Parse($m.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)}
    return $null
}
function Timing([string]$Text){
    $ls=$Text -split "`r?`n"
    for($i=0;$i -lt $ls.Count;$i++){
        if($ls[$i] -match 'WNS\(ns\)' -and $ls[$i] -match 'TNS\(ns\)'){
            for($j=$i+1;$j -lt [math]::Min($i+12,$ls.Count);$j++){
                $m=[regex]::Match($ls[$j],'^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if($m.Success){return [ordered]@{wns_ns=[double]$m.Groups[1].Value;tns_ns=[double]$m.Groups[2].Value}}
            }
        }
    }
    return [ordered]@{wns_ns=$null;tns_ns=$null}
}

try {
    Write-Status 'running' 'vivado' 0 'detached exact line-cache shell proxy synthesis started'
    # Hydrate only the small Vivado runtime Tcl directories needed by batch
    # synthesis.  This avoids the known WMI lazy-file race while keeping the
    # staging private and disposable.
    $env:XILINX_VIVADO=$vivadoRoot
    $env:RDI_APPROOT=$vivadoRoot
    $env:RDI_PATCHROOT=Join-Path $runRoot 'vivado_rt'
    $env:XILINX_PATH=$env:RDI_PATCHROOT
    $sourceRt=Join-Path $vivadoRoot 'scripts\rt'
    $stageRt=Join-Path $env:RDI_PATCHROOT 'scripts\rt'
    foreach($name in @('data','fpga_tcl','base_tcl')){
        $source=Join-Path $sourceRt $name
        $destination=Join-Path $stageRt $name
        New-Item -ItemType Directory -Force -Path $destination|Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
    }
    foreach($sentinel in @(
        (Join-Path $stageRt 'data\unimacro\unimacro_verilog.tcl'),
        (Join-Path $stageRt 'data\unimacro\unimacro_vhdl.tcl'))){
        if(-not (Test-Path -LiteralPath $sentinel -PathType Leaf)){throw "Vivado runtime stage sentinel is missing: $sentinel"}
    }
    Get-ChildItem -LiteralPath $env:RDI_PATCHROOT -Recurse -File|ForEach-Object{$_.Attributes=[IO.FileAttributes]::Normal}
    $env:RT_LIBPATH=Join-Path $stageRt 'data'
    $env:SYNTH_COMMON=$env:RT_LIBPATH
    $env:RT_TCL_PATH=Join-Path $stageRt 'base_tcl\tcl'
    $script:step='vivado'
    $rawOut=Join-Path $runRoot 'vivado.stdout.raw.log'
    $rawErr=Join-Path $runRoot 'vivado.stderr.raw.log'
    $out=Join-Path $runLog 'vivado.stdout.log'
    $err=Join-Path $runLog 'vivado.stderr.log'
    $p=Start-Process -FilePath $vivado -ArgumentList @('-mode','batch','-nolog','-nojournal','-notrace','-source',$tcl) `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr
    Compact $rawOut $out $marker; Compact $rawErr $err
    if($null -eq $p -or $p.ExitCode -ne 0){throw "Vivado exit code $($p.ExitCode)"}
    $stdout=Get-Content -Raw -LiteralPath $rawOut
    $stderr=Get-Content -Raw -LiteralPath $rawErr
    if($stdout -match '(?im)^\s*(ERROR|FATAL):' -or $stderr -match '(?im)^\s*(ERROR|FATAL):'){throw 'Vivado reported an error'}
    if([regex]::Matches($stdout,[regex]::Escape($marker)).Count -ne 1){throw 'synthesis marker missing or duplicated'}
    $timingPaths = Join-Path $runRoot 'reports\timing_paths.rpt'
    if(Test-Path -LiteralPath $timingPaths){
        # Preserve only the report header and first few paths; the full report
        # remains private and is removed with runRoot.
        Get-Content -LiteralPath $timingPaths -TotalCount 260 |
            Set-Content -LiteralPath (Join-Path $runLog 'timing_paths.log') -Encoding UTF8
    }
    $util=Get-Content -Raw -LiteralPath (Join-Path $runRoot 'reports\utilization.rpt')
    $tim=Timing (Get-Content -Raw -LiteralPath (Join-Path $runRoot 'reports\timing.rpt'))
    $metrics=[ordered]@{part='xc7a200tsbg484-1';clock_mhz=100.0;
        line_rows=3;max_row_words=1280;cmd_fifo_depth=8;epoch_width=4;
        sched_max_outstanding=16;reader_max_outstanding=4;reader_req_fifo_depth=32;
        reader_burst_beats=16;reader_rsp_fifo_depth=128;exact_count_adapter=1;
        refill_skid_depth=2;
        luts=Metric $util 'Slice LUTs*';registers=Metric $util 'Slice Registers';
        bram_tiles=Metric $util 'Block RAM Tile';dsps=Metric $util 'DSPs';
        wns_ns=$tim.wns_ns;tns_ns=$tim.tns_ns;
        timing_met=($null -ne $tim.wns_ns -and $tim.wns_ns -ge 0.0);marker=$marker}
    [ordered]@{run_id=$RunId;marker=$marker;state='complete';metrics=$metrics}|
        ConvertTo-Json -Depth 8|Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop();Write-Status 'complete' 'done' 0 $marker $metrics
} catch {
    $watch.Stop();Write-Status 'failed' $script:step 1 $_.Exception.Message;exit 1
} finally {
    if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
