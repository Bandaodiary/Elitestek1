param([switch]$Worker,[string]$RunId='')

# WMI-detached Vivado synthesis for the integrated read fabric.  Only a small
# JSON summary survives; the private Vivado project/report tree is deleted.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot=Join-Path $caseRoot 'logs\tensor_mem_axi128_read_fabric_proxy_synth_runs'
$scriptFile=Join-Path $caseRoot 'scripts\synth_tensor_mem_axi128_read_fabric_2c.tcl'
$vivadoBin='D:\vivado\vivado\Vivado\2023.1\bin';$vivadoRoot='D:\vivado\vivado\Vivado\2023.1'
if(-not $Worker){
    if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
    $statusPath=Join-Path $logRoot "$RunId\status.json"
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed: $($r.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath}|ConvertTo-Json;exit 0
}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot=Join-Path $caseRoot ".tmp_tensor_mem_axi128_read_fabric_proxy_synth_$RunId"
$runLog=Join-Path $logRoot $RunId;$statusPath=Join-Path $runLog 'status.json';$summaryPath=Join-Path $runLog 'summary.json';$latestPath=Join-Path $logRoot 'latest_status.json'
$watch=[Diagnostics.Stopwatch]::StartNew();$script:step='setup';New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Status([string]$state,[string]$step,[int]$code,[string]$msg,[object]$metrics=$null){$j=([ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$msg;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);log_directory=$runLog;summary_path=$summaryPath;metrics=$metrics}|ConvertTo-Json -Depth 6);$j|Set-Content -LiteralPath $statusPath -Encoding UTF8;$j|Set-Content -LiteralPath $latestPath -Encoding UTF8}
function Metric([string]$txt,[string]$label){$m=[regex]::Match($txt,'(?m)^\|\s*'+[regex]::Escape($label)+'\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*\|');if($m.Success){return [double]::Parse($m.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)}return $null}
function Timing([string]$txt){$lines=$txt -split "`r?`n";for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match 'WNS\(ns\)' -and $lines[$i] -match 'TNS\(ns\)'){for($j=$i+1;$j -lt [math]::Min($i+10,$lines.Count);$j++){$m=[regex]::Match($lines[$j],'^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+');if($m.Success){return [ordered]@{wns_ns=[double]$m.Groups[1].Value;tns_ns=[double]$m.Groups[2].Value}}}}}return [ordered]@{wns_ns=$null;tns_ns=$null}}
try{
    Status 'running' 'vivado' 0 'detached integrated read-fabric proxy synthesis started'
    $buf=New-Object byte[] 65536;$rtRoot=Join-Path $vivadoRoot 'scripts\rt';Get-ChildItem -LiteralPath $rtRoot -Filter '*.tcl' -File -Recurse|ForEach-Object{$s=[IO.File]::OpenRead($_.FullName);while($s.Read($buf,0,$buf.Length)-gt 0){};$s.Dispose()}
    $out=Join-Path $runLog 'vivado.stdout.log';$err=Join-Path $runLog 'vivado.stderr.log'
    $p=Start-Process -FilePath (Join-Path $vivadoBin 'vivado.bat') -ArgumentList @('-mode','batch','-nolog','-nojournal','-notrace','-source',$scriptFile) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($p.ExitCode -ne 0){throw "Vivado exit code $($p.ExitCode)"}
    $stdout=Get-Content -Raw -LiteralPath $out;$stderr=Get-Content -Raw -LiteralPath $err;$all=$stdout+"`n"+$stderr
    if($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened'){throw 'Vivado reported failure'}
    $marker='C1_TENSOR_MEM_AXI128_READ_FABRIC_PROXY_SYNTH_PASS';if([regex]::Matches($stdout,[regex]::Escape($marker)).Count -ne 1){throw 'synthesis marker missing or duplicated'}
    $util=Get-Content -Raw -LiteralPath (Join-Path $runRoot 'reports\utilization.rpt');$tim=Timing (Get-Content -Raw -LiteralPath (Join-Path $runRoot 'reports\timing.rpt'))
    $metrics=[ordered]@{part='xc7a200tsbg484-1';clients=2;fabric_fifo_depth=8;leaf_burst_beats=4;luts=Metric $util 'Slice LUTs*';registers=Metric $util 'Slice Registers';bram_tiles=Metric $util 'Block RAM Tile';dsps=Metric $util 'DSPs';wns_ns=$tim.wns_ns;tns_ns=$tim.tns_ns;timing_met=($null -ne $tim.wns_ns -and $tim.wns_ns -ge 0.0);marker=$marker}
    [ordered]@{run_id=$RunId;marker=$marker;state='complete';metrics=$metrics}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop();Status 'complete' 'done' 0 $marker $metrics
}catch{$watch.Stop();Status 'failed' $script:step 1 $_.Exception.Message;exit 1}
finally{if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}}
