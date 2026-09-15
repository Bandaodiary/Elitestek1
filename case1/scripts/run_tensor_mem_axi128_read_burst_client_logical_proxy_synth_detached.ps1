param([switch]$Worker,[string]$RunId='')

# WMI-detached, bounded proxy synthesis for the logical-entry FIFO.  The
# private Vivado/runtime tree is removed after a compact summary is written.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptRoot=Join-Path $caseRoot 'scripts'
$logRoot=Join-Path $caseRoot 'logs\tensor_mem_axi128_read_burst_client_logical_synth_runs'
$vivadoRoot='D:\vivado\vivado\Vivado\2023.1'
$vivado=Join-Path $vivadoRoot 'bin\vivado.bat'
if(-not $Worker){
    if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
    $statusPath=Join-Path $logRoot "$RunId\status.json"
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed: $($r.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath}|ConvertTo-Json
    exit 0
}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot=Join-Path $caseRoot "sim\.tmp_tensor_read_logical_synth_$RunId"
$runLog=Join-Path $logRoot $RunId
$statusPath=Join-Path $runLog 'status.json';$latestPath=Join-Path $logRoot 'latest_status.json'
$runtimeCacheRoot=Join-Path $caseRoot "_vivado_rt_cache_logical_$RunId"
$watch=[Diagnostics.Stopwatch]::StartNew();$script:step='setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Write-Status([string]$state,[string]$step,[int]$code,[string]$message){
    $j=([ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);log_directory=$runLog;run_directory=$runRoot}|ConvertTo-Json)
    $j|Set-Content -LiteralPath $statusPath -Encoding UTF8;$j|Set-Content -LiteralPath $latestPath -Encoding UTF8
}
function Get-Metric([string]$txt,[string]$label){
    $m=[regex]::Match($txt,'(?m)^\|\s*'+[regex]::Escape($label)+'\s*\|\s*([0-9,]+(?:\.[0-9]+)?)\s*\|')
    if($m.Success){return [double](($m.Groups[1].Value)-replace ',','')};return $null
}
function Get-Timing([string]$txt){
    $ls=$txt -split "`r?`n"
    for($i=0;$i-lt $ls.Count;$i++){
        if($ls[$i]-match 'WNS\(ns\)' -and $ls[$i]-match 'TNS\(ns\)'){
            for($j=$i+1;$j-lt [math]::Min($i+10,$ls.Count);$j++){
                $m=[regex]::Match($ls[$j],'^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if($m.Success){return [ordered]@{wns_ns=[double]$m.Groups[1].Value;tns_ns=[double]$m.Groups[2].Value}}
            }
        }
    }
    return [ordered]@{wns_ns=$null;tns_ns=$null}
}
try{
    Write-Status 'running' 'synthesis' 0 'detached logical-FIFO proxy synthesis started'
    # Stage the small Vivado RT Tcl subset; WMI-created helper processes can
    # otherwise observe an on-demand runtime file as temporarily missing.
    $env:XILINX_VIVADO=$vivadoRoot;$env:RDI_APPROOT=$vivadoRoot
    $env:RDI_PATCHROOT=$runtimeCacheRoot;$env:XILINX_PATH=$runtimeCacheRoot
    $sourceRt=Join-Path $vivadoRoot 'scripts\rt';$stageRt=Join-Path $runtimeCacheRoot 'scripts\rt';$buf=New-Object byte[] 65536
    $sentinels=@((Join-Path $stageRt 'data\common.tcl'),(Join-Path $stageRt 'data\unimacro\unimacro_verilog.tcl'),(Join-Path $stageRt 'fpga_tcl\rtSynthParallelPrep.tcl'))
    $complete=$true;foreach($s in $sentinels){if(-not(Test-Path -LiteralPath $s -PathType Leaf)){$complete=$false;break}}
    if(-not $complete){foreach($name in @('data','fpga_tcl','base_tcl')){$src=Join-Path $sourceRt $name;$dst=Join-Path $stageRt $name;New-Item -ItemType Directory -Force -Path $dst|Out-Null;Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force}}
    foreach($s in $sentinels){if(-not(Test-Path -LiteralPath $s -PathType Leaf)){throw "Vivado runtime stage sentinel missing: $s"};$st=[IO.File]::OpenRead($s);while($st.Read($buf,0,$buf.Length)-gt 0){};$st.Dispose()}
    Get-ChildItem -LiteralPath $runtimeCacheRoot -Recurse -File|ForEach-Object{$_.Attributes=[IO.FileAttributes]::Normal}
    $env:RT_LIBPATH=Join-Path $stageRt 'data';$env:SYNTH_COMMON=$env:RT_LIBPATH;$env:RT_TCL_PATH=Join-Path $stageRt 'base_tcl\tcl'
    Get-ChildItem -LiteralPath $stageRt -Filter '*.tcl' -File -Recurse|ForEach-Object{$s=[IO.File]::OpenRead($_.FullName);while($s.Read($buf,0,$buf.Length)-gt 0){};$s.Dispose()}
    $out=Join-Path $runLog 'vivado.stdout.log';$err=Join-Path $runLog 'vivado.stderr.log'
    $tcl=Join-Path $scriptRoot 'synth_tensor_mem_axi128_read_burst_client_logical_proxy.tcl'
    $p=Start-Process -FilePath $vivado -ArgumentList @('-mode','batch','-nolog','-nojournal','-notrace','-source',$tcl) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($null-eq $p -or $p.ExitCode-ne 0){throw "vivado failed with exit code $($p.ExitCode)"}
    $all=(Get-Content -Raw -LiteralPath $out)+"`n"+(Get-Content -Raw -LiteralPath $err)
    $marker='C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_LOGICAL_SYNTH_PASS'
    if($all -notmatch $marker){throw 'Vivado did not emit logical-FIFO synthesis marker'}
    $reportDir=Join-Path $runRoot 'reports';$u=Get-Content -Raw -LiteralPath (Join-Path $reportDir 'utilization.rpt');$t=Get-Timing (Get-Content -Raw -LiteralPath (Join-Path $reportDir 'timing.rpt'))
    $summary=[ordered]@{run_id=$RunId;part='xc7a200tsbg484-1';req_fifo_depth=16;burst_beats=16;max_outstanding=4;rsp_fifo_depth=64;rsp_fifo_beat_mode=$false;luts=Get-Metric $u 'Slice LUTs*';registers=Get-Metric $u 'Slice Registers';bram_tiles=Get-Metric $u 'Block RAM Tile';dsps=Get-Metric $u 'DSPs';wns_ns=$t.wns_ns;tns_ns=$t.tns_ns;timing_met=($null -ne $t.wns_ns -and $t.wns_ns -ge 0.0)}
    $summary|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $runLog 'summary.json') -Encoding UTF8
    $watch.Stop();Write-Status 'complete' 'done' 0 $marker
}catch{$watch.Stop();Write-Status 'failed' $script:step 1 $_.Exception.Message;exit 1}
finally{if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue};if(Test-Path -LiteralPath $runtimeCacheRoot){Remove-Item -LiteralPath $runtimeCacheRoot -Recurse -Force -ErrorAction SilentlyContinue}}
