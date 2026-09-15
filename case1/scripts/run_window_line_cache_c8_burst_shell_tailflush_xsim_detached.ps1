param([switch]$Worker,[string]$RunId='')

# Detached, self-cleaning xsim A/B for the optional row-tail flush mode.
# The WMI worker is intentional: Vivado/xsim must outlive the caller's job.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot=Join-Path $caseRoot 'rtl';$simRoot=Join-Path $caseRoot 'sim';$logRoot=Join-Path $caseRoot 'logs'
if(-not $Worker){
    if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
    $statusPath=Join-Path $logRoot "xsim_runs\cache_burst_shell_tailflush\$RunId\status.json"
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed: $($r.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath}|ConvertTo-Json;exit 0
}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot=Join-Path $simRoot "xsim_cache_burst_shell_tailflush_$RunId"
$runLog=Join-Path $logRoot "xsim_runs\cache_burst_shell_tailflush\$RunId"
$status=Join-Path $runLog 'status.json';$latest=Join-Path $logRoot 'xsim_cache_burst_shell_tailflush_status.json'
$summary=Join-Path $runLog 'summary.log';$watch=[Diagnostics.Stopwatch]::StartNew();$script:step='setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Status([string]$state,[string]$step,[int]$code,[string]$msg){
    $j=([ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$msg;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);log_directory=$runLog;run_directory=$runRoot}|ConvertTo-Json)
    $j|Set-Content -LiteralPath $status -Encoding UTF8;$j|Set-Content -LiteralPath $latest -Encoding UTF8
}
function Step([string]$name,[string]$tool,[string[]]$toolArgs,[string]$marker=''){
    $script:step=$name;Status 'running' $name 0 "starting $name"
    $out=Join-Path $runLog "$name.stdout.log";$err=Join-Path $runLog "$name.stderr.log"
    $p=Start-Process -FilePath $tool -ArgumentList $toolArgs -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($null-eq $p -or $p.ExitCode-ne 0){throw "$name failed with exit code $($p.ExitCode)"}
    $all=(Get-Content -Raw -LiteralPath $out)+"`n"+(Get-Content -Raw -LiteralPath $err)
    if($all -match '(?im)(^|\s)(Fatal|Error):|\$fatal|_FAIL'){throw "$name reported failure"}
    if($marker){
        $hits=[regex]::Matches($all,[regex]::Escape($marker));if($hits.Count-ne 1){throw "$name marker missing or duplicated"}
        $line=($all -split "`r?`n"|Where-Object {$_ -like "*$marker*"}|Select-Object -Last 1)
        if($line){$line|Set-Content -LiteralPath $summary -Encoding UTF8}
    }
    # Keep only the compact marker/status on successful steps; xsim's full
    # transcript and generated work tree are disposable.
    Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
}
try{
    Status 'running' 'setup' 0 'detached cache tail-flush worker started';$bin='D:\vivado\vivado\Vivado\2023.1\bin'
    Step 'xvlog' (Join-Path $bin 'xvlog.bat') @('-sv','-nolog','-d','C1_CACHE_TAIL_FLUSH_TB',(Join-Path $rtlRoot 'cnn\c1_window_line_cache_c8.sv'),(Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),(Join-Path $rtlRoot 'dma\c1_window_line_cache_c8_burst_shell.sv'),(Join-Path $simRoot 'tb_c1_window_line_cache_c8_burst_shell.sv'))
    Step 'xelab' (Join-Path $bin 'xelab.bat') @('tb_c1_window_line_cache_c8_burst_shell','-s','tb_c1_window_line_cache_c8_burst_shell_tailflush_sim','-nolog')
    Step 'xsim' (Join-Path $bin 'xsim.bat') @('tb_c1_window_line_cache_c8_burst_shell_tailflush_sim','-runall','-nolog') 'C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS'
    $watch.Stop();Status 'complete' 'done' 0 'C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS'
}catch{
    $watch.Stop();
    # Preserve only bounded failure context; never retain a generated xsim tree.
    try{ $msg=$_.Exception.Message; $msg|Set-Content -LiteralPath $summary -Encoding UTF8 }catch{}
    Status 'failed' $script:step 1 $_.Exception.Message;exit 1
}finally{if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}}
