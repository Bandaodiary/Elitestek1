param([switch]$Worker,[string]$RunId='')

# Launch Vivado outside the current Windows job and retain only compact
# reports.  The private synthesis tree is removed on both success and error.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot=Join-Path $caseRoot 'logs\cache_refill_scheduler_proxy_synth_runs'
$tcl=Join-Path $caseRoot 'scripts\synth_cache_refill_scheduler_proxy.tcl'
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
$runRoot=Join-Path $caseRoot "sim\.tmp_cache_refill_scheduler_synth_$RunId"
$runLog=Join-Path $logRoot $RunId
$statusPath=Join-Path $runLog 'status.json'
$summaryPath=Join-Path $runLog 'summary.json'
$latestPath=Join-Path $logRoot 'latest_status.json'
$watch=[Diagnostics.Stopwatch]::StartNew();$script:step='setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Write-Status([string]$state,[string]$step,[int]$code,[string]$message,[object]$metrics=$null){
    $j=([ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);log_directory=$runLog;summary_path=$summaryPath;metrics=$metrics}|ConvertTo-Json -Depth 6)
    $j|Set-Content -LiteralPath $statusPath -Encoding UTF8
    $j|Set-Content -LiteralPath $latestPath -Encoding UTF8
}
function Metric([string]$txt,[string]$label){
    $m=[regex]::Match($txt,'(?m)^\|\s*'+[regex]::Escape($label)+'\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*\|')
    if($m.Success){return [double]::Parse($m.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)}
    return $null
}
function Timing([string]$txt){
    $lines=$txt -split "`r?`n"
    for($i=0;$i -lt $lines.Count;$i++){
        if($lines[$i] -match 'WNS\(ns\)' -and $lines[$i] -match 'TNS\(ns\)'){
            for($j=$i+1;$j -lt [math]::Min($i+10,$lines.Count);$j++){
                $m=[regex]::Match($lines[$j],'^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if($m.Success){return [ordered]@{wns_ns=[double]$m.Groups[1].Value;tns_ns=[double]$m.Groups[2].Value}}
            }
        }
    }
    return [ordered]@{wns_ns=$null;tns_ns=$null}
}
try{
    Write-Status 'running' 'vivado' 0 'detached cache-refill scheduler proxy synthesis started'
    # Touch the small Vivado runtime Tcl tree before starting the detached
    # batch process; this avoids lazy-file races observed with WMI workers.
    $buf=New-Object byte[] 65536
    $rtRoot=Join-Path $vivadoRoot 'scripts\rt'
    Get-ChildItem -LiteralPath $rtRoot -Filter '*.tcl' -File -Recurse|ForEach-Object{
        $s=[IO.File]::OpenRead($_.FullName);while($s.Read($buf,0,$buf.Length)-gt 0){};$s.Dispose()
    }
    $out=Join-Path $runLog 'vivado.stdout.log';$err=Join-Path $runLog 'vivado.stderr.log'
    $p=Start-Process -FilePath $vivado -ArgumentList @('-mode','batch','-nolog','-nojournal','-notrace','-source',$tcl) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($null -eq $p -or $p.ExitCode -ne 0){throw "Vivado exit code $($p.ExitCode)"}
    $stdout=Get-Content -Raw -LiteralPath $out;$stderr=Get-Content -Raw -LiteralPath $err
    if($stdout -match '(?im)^\s*(ERROR|FATAL):' -or $stderr -match '(?im)^\s*(ERROR|FATAL):'){throw 'Vivado reported an error'}
    $marker='C1_CACHE_REFILL_SCHEDULER_PROXY_SYNTH_PASS'
    if([regex]::Matches($stdout,[regex]::Escape($marker)).Count -ne 1){throw 'synthesis marker missing or duplicated'}
    $util=Get-Content -Raw -LiteralPath (Join-Path $runRoot 'reports\utilization.rpt')
    $tim=Timing (Get-Content -Raw -LiteralPath (Join-Path $runRoot 'reports\timing.rpt'))
    $metrics=[ordered]@{part='xc7a200tsbg484-1';clock_mhz=100.0;cmd_fifo_depth=8;max_outstanding=4;epoch_width=4;luts=Metric $util 'Slice LUTs*';registers=Metric $util 'Slice Registers';bram_tiles=Metric $util 'Block RAM Tile';dsps=Metric $util 'DSPs';wns_ns=$tim.wns_ns;tns_ns=$tim.tns_ns;timing_met=($null -ne $tim.wns_ns -and $tim.wns_ns -ge 0.0);marker=$marker}
    [ordered]@{run_id=$RunId;marker=$marker;state='complete';metrics=$metrics}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop();Write-Status 'complete' 'done' 0 $marker $metrics
}catch{
    $watch.Stop();Write-Status 'failed' $script:step 1 $_.Exception.Message;exit 1
}finally{
    if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
