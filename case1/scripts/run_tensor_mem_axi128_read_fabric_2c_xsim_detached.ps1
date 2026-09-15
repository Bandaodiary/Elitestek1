param([switch]$Worker,[string]$RunId='',[switch]$ReqPopRefill,[switch]$EmptyArBypass)

# Detached end-to-end leaf-packer + multi-outstanding read-fabric regression.
# WMI keeps Vivado/xsim outside the caller's Windows Job; the private run tree
# is removed when the worker exits.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot=Join-Path $caseRoot 'rtl';$simRoot=Join-Path $caseRoot 'sim';$logRoot=Join-Path $caseRoot 'logs'
if(-not $Worker){
    if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
    $statusPath=Join-Path $logRoot "xsim_runs\tensor_read_fabric_2c\$RunId\status.json"
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $mode = if ($ReqPopRefill) { ' -ReqPopRefill' } else { '' }
    $emptyMode = if ($EmptyArBypass) { ' -EmptyArBypass' } else { '' }
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId$mode$emptyMode"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed: $($r.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath}|ConvertTo-Json;exit 0
}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot=Join-Path $simRoot "xsim_run_tensor_read_fabric_2c_$RunId"
$runLog=Join-Path $logRoot "xsim_runs\tensor_read_fabric_2c\$RunId"
$statusPath=Join-Path $runLog 'status.json';$latestPath=Join-Path $logRoot 'xsim_tensor_read_fabric_2c_status.json'
$watch=[Diagnostics.Stopwatch]::StartNew();$script:step='setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Status([string]$state,[string]$step,[int]$code,[string]$msg){
    $j=([ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$msg;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);log_directory=$runLog;run_directory=$runRoot}|ConvertTo-Json)
    $j|Set-Content -LiteralPath $statusPath -Encoding UTF8;$j|Set-Content -LiteralPath $latestPath -Encoding UTF8
}
function Step([string]$name,[string]$tool,[string[]]$toolArgs,[string]$marker=''){
    $script:step=$name;Status 'running' $name 0 "starting $name"
    $out=Join-Path $runLog "$name.stdout.log";$err=Join-Path $runLog "$name.stderr.log"
    $p=Start-Process -FilePath $tool -ArgumentList $toolArgs -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($null -eq $p -or $p.ExitCode -ne 0){throw "$name failed with exit code $($p.ExitCode)"}
    $all=(Get-Content -Raw -LiteralPath $out)+"`n"+(Get-Content -Raw -LiteralPath $err)
    if($all -match '(?im)(^|\s)(Fatal|Error):|\$fatal|C1_TENSOR_MEM_AXI128_READ_FABRIC_FAIL'){throw "$name reported simulator failure"}
    if($marker -and [regex]::Matches($all,[regex]::Escape($marker)).Count -ne 1){throw "$name marker missing or duplicated"}
}
try{
    Status 'running' 'setup' 0 'detached integrated tensor read fabric started'
    $xvlog=Join-Path 'D:\vivado\vivado\Vivado\2023.1\bin' 'xvlog.bat'
    $xelab=Join-Path 'D:\vivado\vivado\Vivado\2023.1\bin' 'xelab.bat'
    $xsim=Join-Path 'D:\vivado\vivado\Vivado\2023.1\bin' 'xsim.bat'
    $defines = @()
    if ($ReqPopRefill) { $defines += @('-d','C1_REQ_POP_REFILL_FABRIC_TB') }
    if ($EmptyArBypass) { $defines += @('-d','C1_EMPTY_AR_BYPASS_FABRIC_TB') }
    Step 'xvlog' $xvlog (@('-sv','-nolog') + $defines + @(
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_axi_n_read_burst_arbiter_128.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_fabric_2c.sv'),
        (Join-Path $simRoot 'tb_c1_tensor_mem_axi128_read_fabric_2c.sv')))
    Step 'xelab' $xelab @('tb_c1_tensor_mem_axi128_read_fabric_2c','-s','tb_c1_tensor_mem_axi128_read_fabric_2c_sim','-nolog')
    Step 'xsim' $xsim @('tb_c1_tensor_mem_axi128_read_fabric_2c_sim','-runall','-nolog') 'C1_TENSOR_MEM_AXI128_READ_FABRIC_PASS'
    $watch.Stop();Status 'complete' 'done' 0 'C1_TENSOR_MEM_AXI128_READ_FABRIC_PASS'
}catch{$watch.Stop();Status 'failed' $script:step 1 $_.Exception.Message;exit 1}
finally{if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}}
