param([switch]$Worker,[string]$RunId='')

# Detached xsim regression for the integrated two-client fabric with the
# optional beat-record response FIFO forwarded into both leaves.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot=Join-Path $caseRoot 'rtl';$simRoot=Join-Path $caseRoot 'sim';$logRoot=Join-Path $caseRoot 'logs'
if(-not $Worker){
    if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
    $statusPath=Join-Path $logRoot "xsim_runs\tensor_read_fabric_2c_beatfifo\$RunId\status.json"
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed: $($r.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath}|ConvertTo-Json;exit 0
}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot=Join-Path $simRoot "xsim_run_tensor_read_fabric_2c_beatfifo_$RunId"
$runLog=Join-Path $logRoot "xsim_runs\tensor_read_fabric_2c_beatfifo\$RunId"
$statusPath=Join-Path $runLog 'status.json';$latestPath=Join-Path $logRoot 'xsim_tensor_read_fabric_2c_beatfifo_status.json'
$watch=[Diagnostics.Stopwatch]::StartNew();$script:step='setup';New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Status([string]$state,[string]$step,[int]$code,[string]$message){$j=([ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);log_directory=$runLog;run_directory=$runRoot}|ConvertTo-Json);$j|Set-Content -LiteralPath $statusPath -Encoding UTF8;$j|Set-Content -LiteralPath $latestPath -Encoding UTF8}
function Step([string]$name,[string]$tool,[string[]]$toolArgs,[string]$marker=''){
    $script:step=$name;Status 'running' $name 0 "starting $name";$out=Join-Path $runLog "$name.stdout.log";$err=Join-Path $runLog "$name.stderr.log"
    $p=Start-Process -FilePath $tool -ArgumentList $toolArgs -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($null-eq $p -or $p.ExitCode-ne 0){throw "$name failed with exit code $($p.ExitCode)"}
    $all=(Get-Content -Raw -LiteralPath $out)+"`n"+(Get-Content -Raw -LiteralPath $err)
    if($all -match '(?im)(^|\s)(Fatal|Error):|\$fatal|C1_TENSOR_MEM_AXI128_READ_FABRIC_FAIL|_FAIL'){throw "$name reported failure"}
    if($marker -and [regex]::Matches($all,[regex]::Escape($marker)).Count -ne 1){throw "$name marker missing or duplicated"}
}
try{
    Status 'running' 'setup' 0 'detached beat-FIFO integrated read fabric started'
    $bin='D:\vivado\vivado\Vivado\2023.1\bin'
    Step 'xvlog' (Join-Path $bin 'xvlog.bat') @('-sv','-nolog','-d','C1_BEAT_FIFO_FABRIC_TB',(Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),(Join-Path $rtlRoot 'dma\c1_axi_n_read_burst_arbiter_128.sv'),(Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_fabric_2c.sv'),(Join-Path $simRoot 'tb_c1_tensor_mem_axi128_read_fabric_2c.sv'))
    Step 'xelab' (Join-Path $bin 'xelab.bat') @('tb_c1_tensor_mem_axi128_read_fabric_2c','-s','tb_c1_tensor_mem_axi128_read_fabric_2c_beatfifo_sim','-nolog')
    Step 'xsim' (Join-Path $bin 'xsim.bat') @('tb_c1_tensor_mem_axi128_read_fabric_2c_beatfifo_sim','-runall','-nolog') 'C1_TENSOR_MEM_AXI128_READ_FABRIC_PASS'
    $watch.Stop();Status 'complete' 'done' 0 'C1_TENSOR_MEM_AXI128_READ_FABRIC_PASS'
}catch{$watch.Stop();Status 'failed' $script:step 1 $_.Exception.Message;exit 1}
finally{if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}}
