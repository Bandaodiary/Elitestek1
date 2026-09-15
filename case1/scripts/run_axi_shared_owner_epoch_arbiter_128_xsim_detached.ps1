param(
    [switch]$Worker,
    [string]$RunId='',
    [ValidateSet(0,1)][int]$ReadSkid=0
)

# Detached compact xsim smoke for the reusable owner/epoch arbiter shell.
# Vivado/xsim are launched in a separate WMI process and the private xsim
# directory is removed when the worker exits.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot=Join-Path $caseRoot 'rtl\dma'
$simRoot=Join-Path $caseRoot 'sim'
$logRoot=Join-Path $caseRoot 'logs\axi_shared_owner_epoch_arbiter_128_runs'
$shellFile=Join-Path $rtlRoot 'c1_axi_shared_owner_epoch_arbiter_128.sv'
$fenceFile=Join-Path $rtlRoot 'c1_axi_shared_owner_epoch_fence.sv'
$arbiterFile=Join-Path $rtlRoot 'c1_axi_n_serial_arbiter_128.sv'
$tbFile=Join-Path $simRoot 'tb_c1_axi_shared_owner_epoch_arbiter_128.sv'

if(-not $Worker){
    if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId -ReadSkid $ReadSkid"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed: $($r.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=(Join-Path $logRoot "$RunId\status.json")}|ConvertTo-Json
    return
}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot=Join-Path $caseRoot "sim\xsim_run_axi_shared_owner_epoch_arbiter_128_$RunId"
$runLog=Join-Path $logRoot $RunId
$statusPath=Join-Path $runLog 'status.json'
$latestPath=Join-Path $logRoot 'latest_status.json'
$watch=[Diagnostics.Stopwatch]::StartNew();$script:step='setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Write-Status([string]$state,[string]$step,[int]$code,[string]$message){
    $j=([ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);log_directory=$runLog;run_directory=$runRoot}|ConvertTo-Json)
    $j|Set-Content -LiteralPath $statusPath -Encoding UTF8
    $j|Set-Content -LiteralPath $latestPath -Encoding UTF8
}
function Invoke-Step([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$Marker=''){
    $script:step=$Name;Write-Status running $Name 0 "starting $Name"
    $out=Join-Path $runLog "$Name.stdout.log";$err=Join-Path $runLog "$Name.stderr.log"
    $p=Start-Process -FilePath $Tool -ArgumentList $Arguments -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($p.ExitCode -ne 0){throw "$Name exit $($p.ExitCode)"}
    $txt=(Get-Content -Raw -LiteralPath $out)+(Get-Content -Raw -LiteralPath $err)
    if($txt -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened'){throw "$Name log contains an error/failure marker"}
    if($Marker -and [regex]::Matches($txt,[regex]::Escape($Marker)).Count -ne 1){throw "$Name marker missing or duplicated"}
}
try{
    Write-Status running setup 0 'detached owner/epoch arbiter shell xsim started'
    $vivadoBin='D:\vivado\vivado\Vivado\2023.1\bin'
    $xvlogArgs=@('-sv')
    if($ReadSkid -ne 0){$xvlogArgs += @('-d','C1_READ_RESPONSE_SKID')}
    $xvlogArgs += @($fenceFile,$arbiterFile,$shellFile,$tbFile)
    Invoke-Step xvlog (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    Invoke-Step xelab (Join-Path $vivadoBin 'xelab.bat') @('tb_c1_axi_shared_owner_epoch_arbiter_128','-s','tb_c1_axi_shared_owner_epoch_arbiter_128_sim')
    Invoke-Step xsim (Join-Path $vivadoBin 'xsim.bat') @('tb_c1_axi_shared_owner_epoch_arbiter_128_sim','-runall') 'C1_AXI_SHARED_OWNER_EPOCH_ARBITER_PASS'
    $watch.Stop();Write-Status complete done 0 'C1_AXI_SHARED_OWNER_EPOCH_ARBITER_PASS'
}catch{
    $watch.Stop();Write-Status failed $script:step 1 $_.Exception.Message;exit 1
}finally{
    $resolvedCase=[IO.Path]::GetFullPath($caseRoot);$resolvedRun=[IO.Path]::GetFullPath($runRoot)
    if($resolvedRun.StartsWith($resolvedCase+[IO.Path]::DirectorySeparatorChar)){
        if(Test-Path -LiteralPath $resolvedRun){Remove-Item -LiteralPath $resolvedRun -Recurse -Force}
    }else{throw 'refusing to remove a runRoot outside caseRoot'}
}
