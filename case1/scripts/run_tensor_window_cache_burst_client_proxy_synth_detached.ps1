param([switch]$Worker,[string]$RunId='',
      [ValidateSet(0,32,64,128)][int]$FanoutLimit=0,
      [switch]$BeatFifo)

# Detached, bounded Vivado proxy synthesis for the optional client-6
# burst/refill wrapper.  The worker is created with WMI so Vivado is not tied
# to the interactive Windows job; the private project/runtime trees are
# removed in finally and only compact reports remain.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptRoot=$PSScriptRoot
$simRoot=Join-Path $caseRoot 'sim'
$logRoot=Join-Path $caseRoot 'logs\tensor_window_cache_burst_client_proxy_synth_runs'
$vivadoRoot='D:\vivado\vivado\Vivado\2023.1'
$vivado=Join-Path $vivadoRoot 'bin\vivado.bat'

if(-not $Worker){
    if([string]::IsNullOrWhiteSpace($RunId)){$RunId='tensor_burst_client_proxy_'+(Get-Date -Format 'yyyyMMdd_HHmmss')}
    if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
    $statusPath=Join-Path $logRoot "$RunId\status.json"
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $fanoutArg=if($FanoutLimit -gt 0){" -FanoutLimit $FanoutLimit"}else{''}
    $beatArg=if($BeatFifo){' -BeatFifo'}else{''}
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId ${RunId}${fanoutArg}${beatArg}"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed: $($r.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath}|ConvertTo-Json
    exit 0
}

if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot=Join-Path $simRoot "tensor_window_cache_burst_client_proxy_synth_$RunId"
$runLog=Join-Path $logRoot $RunId
$statusPath=Join-Path $runLog 'status.json'
$latestPath=Join-Path $logRoot 'latest_status.json'
$summaryPath=Join-Path $runLog 'summary.json'
$runtimeCacheRoot=Join-Path $caseRoot ".vivado_rt_cache_tensor_burst_client_$RunId"
$watch=[Diagnostics.Stopwatch]::StartNew();$script:step='setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog | Out-Null

function Write-Status([string]$state,[string]$step,[int]$code,[string]$message,[object]$metrics=$null){
    $o=[ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);log_directory=$runLog;run_directory=$runRoot;summary_path=$summaryPath;metrics=$metrics}
    $j=$o|ConvertTo-Json -Depth 8
    $j|Set-Content -LiteralPath $statusPath -Encoding UTF8
    $j|Set-Content -LiteralPath $latestPath -Encoding UTF8
}
function Compact([string]$raw,[string]$out){
    $a=@();if(Test-Path -LiteralPath $raw){$a+=@(Get-Content -LiteralPath $raw -Tail 160 -ErrorAction SilentlyContinue)}
    if($a.Count -eq 0){$a=@('(empty)')};$a|Select-Object -Unique|Set-Content -LiteralPath $out -Encoding UTF8
}
function Get-Metric([string]$txt,[string]$label){
    $m=[regex]::Match($txt,'(?m)^\|\s*'+[regex]::Escape($label)+'\s*\|\s*([0-9,]+(?:\.[0-9]+)?)\s*\|')
    if($m.Success){return [double](($m.Groups[1].Value)-replace ',','')};return $null
}
function Get-Timing([string]$txt){
    $ls=$txt -split "`r?`n"
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

try{
    Write-Status 'running' 'runtime' 0 'detached client-6 burst proxy synthesis started'
    # Stage the small Vivado runtime subset privately.  Byte-copying avoids
    # on-demand placeholder races in WMI-created helper processes.
    $env:XILINX_VIVADO=$vivadoRoot;$env:RDI_APPROOT=$vivadoRoot
    $env:RDI_PATCHROOT=$runtimeCacheRoot;$env:XILINX_PATH=$runtimeCacheRoot
    $sourceRt=Join-Path $vivadoRoot 'scripts\rt';$stageRt=Join-Path $runtimeCacheRoot 'scripts\rt';$buf=New-Object byte[] 65536
    foreach($name in @('data','fpga_tcl','base_tcl')){
        $srcRoot=Join-Path $sourceRt $name
        Get-ChildItem -LiteralPath $srcRoot -File -Recurse | ForEach-Object {
            $rel=$_.FullName.Substring($srcRoot.Length+1);$dst=Join-Path (Join-Path $stageRt $name) $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst)|Out-Null
            $si=[IO.File]::OpenRead($_.FullName);$so=[IO.File]::Open($dst,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$si.CopyTo($so)}finally{$so.Dispose();$si.Dispose()}
        }
    }
    # A few files in the Vivado installation are cloud-backed hardlinks.  In
    # a WMI-created worker Get-ChildItem/-File can enumerate those entries but
    # the byte-copy walk may leave the corresponding staged file absent.  The
    # synthesis helper always sources data/lib_core.tcl, so repair that one
    # required root-level file explicitly with the provider copy operation and
    # verify a non-empty destination before launching Vivado.
    $libCoreSource=Join-Path $sourceRt 'data\lib_core.tcl'
    $libCoreDestination=Join-Path $stageRt 'data\lib_core.tcl'
    if(-not(Test-Path -LiteralPath $libCoreSource -PathType Leaf)){
        throw "Vivado runtime source missing: $libCoreSource"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $libCoreDestination)|Out-Null
    Copy-Item -LiteralPath $libCoreSource -Destination $libCoreDestination -Force -ErrorAction Stop
    $libCoreInfo=Get-Item -LiteralPath $libCoreDestination -ErrorAction Stop
    if($libCoreInfo.Length -le 0){throw "Vivado runtime staged lib_core.tcl is empty: $libCoreDestination"}
    $sentinel=Join-Path $stageRt 'data\unimacro\unimacro_verilog.tcl'
    if(-not(Test-Path -LiteralPath $sentinel -PathType Leaf)){throw 'Vivado runtime stage sentinel missing'}
    Get-ChildItem -LiteralPath $runtimeCacheRoot -Recurse -File|ForEach-Object{$_.Attributes=[IO.FileAttributes]::Normal}
    $env:RT_LIBPATH=Join-Path $stageRt 'data';$env:SYNTH_COMMON=$env:RT_LIBPATH;$env:RT_TCL_PATH=Join-Path $stageRt 'base_tcl\tcl'
    if($FanoutLimit -gt 0){$env:C1_PROXY_FANOUT_LIMIT=[string]$FanoutLimit}else{Remove-Item Env:C1_PROXY_FANOUT_LIMIT -ErrorAction SilentlyContinue}
    if($BeatFifo){
        $env:C1_PROXY_BEAT_MODE='1';$env:C1_PROXY_RSP_FIFO_DEPTH='64'
    }else{
        Remove-Item Env:C1_PROXY_BEAT_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:C1_PROXY_RSP_FIFO_DEPTH -ErrorAction SilentlyContinue
    }

    $script:step='vivado';$rawOut=Join-Path $runRoot 'vivado.stdout.raw.log';$rawErr=Join-Path $runRoot 'vivado.stderr.raw.log'
    $out=Join-Path $runLog 'vivado.stdout.log';$err=Join-Path $runLog 'vivado.stderr.log'
    $tcl=Join-Path $scriptRoot 'synth_tensor_window_cache_burst_client_proxy.tcl'
    $p=Start-Process -FilePath $vivado -ArgumentList @('-mode','batch','-nolog','-nojournal','-notrace','-source',$tcl) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr
    Compact $rawOut $out;Compact $rawErr $err
    if($null -eq $p -or $p.ExitCode -ne 0){throw "Vivado exit code $($p.ExitCode)"}
    $all=(Get-Content -Raw -LiteralPath $rawOut)+"`n"+(Get-Content -Raw -LiteralPath $rawErr)
    $marker='C1_TENSOR_WINDOW_CACHE_BURST_CLIENT_PROXY_SYNTH_PASS'
    if([regex]::Matches($all,[regex]::Escape($marker)).Count -ne 1){throw 'synthesis marker missing or duplicated'}

    $script:step='reports';$reportDir=Join-Path $runRoot 'reports';$u=Get-Content -Raw -LiteralPath (Join-Path $reportDir 'utilization.rpt');$t=Get-Timing (Get-Content -Raw -LiteralPath (Join-Path $reportDir 'timing.rpt'))
    $timingPaths=Join-Path $reportDir 'timing_paths.rpt'
    if(Test-Path -LiteralPath $timingPaths){
        # Keep only a bounded critical-path excerpt; the full report remains
        # private and is removed with the synthesis runRoot.
        Get-Content -LiteralPath $timingPaths -TotalCount 260 |
            Set-Content -LiteralPath (Join-Path $runLog 'timing_paths.log') -Encoding UTF8
    }
    $metrics=[ordered]@{part='xc7a200tsbg484-1';clock_mhz=100.0;fanout_limit=$FanoutLimit;beat_mode=[bool]$BeatFifo;line_rows=3;max_row_words=1280;max_groups=8;burst_beats=16;reader_max_outstanding=4;reader_rsp_fifo_depth=if($BeatFifo){64}else{128};refill_skid_depth=2;cancel_is_protocol_error=0;luts=Get-Metric $u 'Slice LUTs*';registers=Get-Metric $u 'Slice Registers';bram_tiles=Get-Metric $u 'Block RAM Tile';dsps=Get-Metric $u 'DSPs';wns_ns=$t.wns_ns;tns_ns=$t.tns_ns;timing_met=($null -ne $t.wns_ns -and $t.wns_ns -ge 0.0)}
    $metrics|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop()
    if($metrics.timing_met){
        Write-Status 'complete' 'done' 0 $marker $metrics
    }else{
        # Vivado synthesis itself passed, but the 100 MHz proxy timing did
        # not.  Keep this distinct from a tool/RTL failure so callers cannot
        # accidentally treat a timing-violating artifact as a clean PASS.
        Write-Status 'timing_failed' 'done' 2 "$marker; timing_met=false; WNS=$($metrics.wns_ns) ns" $metrics
        exit 2
    }
}catch{
    $watch.Stop();Write-Status 'failed' $script:step 1 $_.Exception.Message;exit 1
}finally{
    if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $runtimeCacheRoot){Remove-Item -LiteralPath $runtimeCacheRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
