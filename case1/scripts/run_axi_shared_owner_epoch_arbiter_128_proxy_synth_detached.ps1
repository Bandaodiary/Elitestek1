param(
    [switch]$Worker,
    [string]$RunId='',
    [ValidateRange(1,7)][int]$Clients=2,
    [ValidateSet(0,1)][int]$ReadSkid=0
)

# Detached compact Vivado proxy for the optional owner/epoch arbiter shell.
# Only reports and a JSON summary are retained; the private synthesis tree is
# removed in finally and Vivado is outside the caller's Windows job.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot=Join-Path $caseRoot 'logs\axi_shared_owner_epoch_arbiter_128_proxy_synth_runs'
$tcl=Join-Path $caseRoot 'scripts\synth_axi_shared_owner_epoch_arbiter_128_proxy.tcl'
$vivado=Join-Path 'D:\vivado\vivado\Vivado\2023.1\bin' 'vivado.bat'
if(-not $Worker){
    if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId -Clients $Clients -ReadSkid $ReadSkid"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed: $($r.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=(Join-Path $logRoot "$RunId\status.json")}|ConvertTo-Json
    return
}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot=Join-Path $caseRoot "sim\xsim_run_axi_shared_owner_epoch_arbiter_128_proxy_$RunId"
$runLog=Join-Path $logRoot $RunId
$statusPath=Join-Path $runLog 'status.json';$summaryPath=Join-Path $runLog 'summary.json';$latestPath=Join-Path $logRoot 'latest_status.json'
$watch=[Diagnostics.Stopwatch]::StartNew();$script:step='setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Write-Status([string]$state,[string]$step,[int]$code,[string]$message,[object]$metrics=$null){
    $j=([ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);log_directory=$runLog;summary_path=$summaryPath;metrics=$metrics}|ConvertTo-Json -Depth 6)
    $j|Set-Content -LiteralPath $statusPath -Encoding UTF8;$j|Set-Content -LiteralPath $latestPath -Encoding UTF8
}
function Metric([string]$txt,[string]$label){
    $m=[regex]::Match($txt,'(?m)^\s*\|\s*'+[regex]::Escape($label)+'\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*\|')
    if($m.Success){return [double]::Parse($m.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)}
    $m=[regex]::Match($txt,'(?m)^\s*'+[regex]::Escape($label)+'\s+([0-9]+(?:\.[0-9]+)?)\s*$')
    if($m.Success){return [double]::Parse($m.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)}
    return $null
}
function Timing([string]$txt){
    $lines=$txt -split "`r?`n"
    for($i=0;$i -lt $lines.Count;$i++){
        if($lines[$i] -match 'WNS\(ns\)' -and $lines[$i] -match 'TNS\(ns\)'){
            for($j=$i+1;$j -lt [math]::Min($i+12,$lines.Count);$j++){
                $m=[regex]::Match($lines[$j],'^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if($m.Success){return [ordered]@{wns_ns=[double]$m.Groups[1].Value;tns_ns=[double]$m.Groups[2].Value}}
            }
        }
    }
    return [ordered]@{wns_ns=$null;tns_ns=$null}
}
function Copy-RuntimeTree([string]$source,[string]$destination){
    New-Item -ItemType Directory -Force -Path $destination|Out-Null
    $sourceRoot=$source.TrimEnd('\')
    foreach($file in (Get-ChildItem -LiteralPath $sourceRoot -Recurse -File)){
        $relative=$file.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $target=Join-Path $destination $relative
        $targetDir=Split-Path -Parent $target
        New-Item -ItemType Directory -Force -Path $targetDir|Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}
try{
    Write-Status running vivado 0 'detached owner/epoch arbiter shell proxy synthesis started'
    # Vivado may launch a helper synthesis process under WMI.  Stage only the
    # small Tcl runtime directories that helper needs, so it does not race a
    # read from the installed tree (and keep the stage inside the disposable
    # runRoot).
    $vivadoRoot='D:\vivado\vivado\Vivado\2023.1'
    $env:XILINX_VIVADO=$vivadoRoot
    $env:RDI_APPROOT=$vivadoRoot
    $env:RDI_PATCHROOT=Join-Path $runRoot 'vivado_rt'
    $env:XILINX_PATH=$env:RDI_PATCHROOT
    $env:C1_PROXY_CLIENTS=$Clients.ToString([Globalization.CultureInfo]::InvariantCulture)
    $env:C1_PROXY_READ_SKID=$ReadSkid.ToString([Globalization.CultureInfo]::InvariantCulture)
    $sourceRt=Join-Path $vivadoRoot 'scripts\rt'
    $stageRt=Join-Path $env:RDI_PATCHROOT 'scripts\rt'
    foreach($name in @('data','fpga_tcl','base_tcl')){
        $source=Join-Path $sourceRt $name
        $destination=Join-Path $stageRt $name
        # Copy each file by literal path.  The installed Vivado tree is backed
        # by a lazy package filesystem on this host; wildcard recursive copies
        # occasionally return before a helper-only Tcl file is materialized.
        Copy-RuntimeTree $source $destination
    }
    foreach($sentinel in @(
        (Join-Path $stageRt 'data\common.tcl'),
        (Join-Path $stageRt 'fpga_tcl\rtSynthParallelPrep.tcl'),
        (Join-Path $stageRt 'data\unimacro\unimacro_verilog.tcl'),
        (Join-Path $stageRt 'data\unimacro\unimacro_vhdl.tcl'))){
        if(-not (Test-Path -LiteralPath $sentinel -PathType Leaf)){
            throw "Vivado runtime stage sentinel is missing: $sentinel"
        }
    }
    $env:RT_LIBPATH=Join-Path $stageRt 'data'
    $env:SYNTH_COMMON=$env:RT_LIBPATH
    $env:RT_TCL_PATH=Join-Path $stageRt 'base_tcl\tcl'
    Get-ChildItem -LiteralPath $env:RDI_PATCHROOT -Recurse -File|ForEach-Object{$_.Attributes=[IO.FileAttributes]::Normal}
    $out=Join-Path $runLog 'vivado.stdout.log';$err=Join-Path $runLog 'vivado.stderr.log'
    $p=Start-Process -FilePath $vivado -ArgumentList @('-mode','batch','-nolog','-nojournal','-notrace','-source',$tcl) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($null -eq $p -or $p.ExitCode -ne 0){throw "Vivado exit code $($p.ExitCode)"}
    $stdout=Get-Content -Raw -LiteralPath $out;$stderr=Get-Content -Raw -LiteralPath $err
    if($stdout -match '(?im)^\s*(ERROR|FATAL):' -or $stderr -match '(?im)^\s*(ERROR|FATAL):'){throw 'Vivado reported an error'}
    $marker='C1_AXI_SHARED_OWNER_EPOCH_ARBITER_128_PROXY_SYNTH_PASS'
    if([regex]::Matches($stdout,[regex]::Escape($marker)).Count -ne 1){throw 'synthesis marker missing or duplicated'}
    $util=Get-Content -Raw -LiteralPath (Join-Path $runRoot 'reports\utilization.rpt')
    $tim=Timing (Get-Content -Raw -LiteralPath (Join-Path $runRoot 'reports\timing.rpt'))
    $metrics=[ordered]@{part='xc7a200tsbg484-1';clock_mhz=100.0;clients=$Clients;read_response_skid=$ReadSkid;luts=Metric $util 'Slice LUTs*';registers=Metric $util 'Slice Registers';bram_tiles=Metric $util 'Block RAM Tile';dsps=Metric $util 'DSPs';wns_ns=$tim.wns_ns;tns_ns=$tim.tns_ns;timing_met=($null -ne $tim.wns_ns -and $tim.wns_ns -ge 0.0);marker=$marker}
    [ordered]@{run_id=$RunId;marker=$marker;state='complete';metrics=$metrics}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop();Write-Status complete done 0 $marker $metrics
}catch{
    $watch.Stop();Write-Status failed $script:step 1 $_.Exception.Message;exit 1
}finally{
    $resolvedCase=[IO.Path]::GetFullPath($caseRoot);$resolvedRun=[IO.Path]::GetFullPath($runRoot)
    if($resolvedRun.StartsWith($resolvedCase+[IO.Path]::DirectorySeparatorChar)){
        if(Test-Path -LiteralPath $resolvedRun){Remove-Item -LiteralPath $resolvedRun -Recurse -Force}
    }else{throw 'refusing to remove a runRoot outside caseRoot'}
}
