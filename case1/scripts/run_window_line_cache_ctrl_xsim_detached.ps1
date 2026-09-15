param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Detached xsim regression for the row-tag/refill control prototype.
$ErrorActionPreference = 'Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot=Join-Path $caseRoot 'rtl'; $simRoot=Join-Path $caseRoot 'sim'; $logRoot=Join-Path $caseRoot 'logs'
if(-not $Worker){
    if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
    $statusPath=Join-Path $logRoot "xsim_runs\window_line_cache_ctrl\$RunId\status.json"
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed with return value $($r.ReturnValue)"}
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath}|ConvertTo-Json; exit 0
}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'RunId contains unsupported characters'}
$runRoot=Join-Path $simRoot "xsim_run_window_line_cache_ctrl_$RunId"
$runLog=Join-Path $logRoot "xsim_runs\window_line_cache_ctrl\$RunId"
$status=Join-Path $runLog 'status.json'; $latest=Join-Path $logRoot 'xsim_runs\window_line_cache_ctrl_status.json'
$vivado='D:\vivado\vivado\Vivado\2023.1\bin'; $script:step='setup'; $script:watch=[Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Write-Status{param([string]$state,[string]$step,[int]$code,[string]$msg)
    $v=[ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$msg;process_id=$PID;elapsed_seconds=[math]::Round($script:watch.Elapsed.TotalSeconds,3);updated=(Get-Date).ToString('o');log_directory=$runLog;run_directory=$runRoot}|ConvertTo-Json
    $v|Set-Content -LiteralPath $status -Encoding UTF8; $v|Set-Content -LiteralPath $latest -Encoding UTF8}
function Invoke-Step{param([string]$name,[string]$tool,[string[]]$arguments,[string]$marker='')
    $script:step=$name; Write-Status 'running' $name 0 "starting $name"; $o=Join-Path $runLog "$name.stdout.log"; $e=Join-Path $runLog "$name.stderr.log"
    $p=Start-Process -FilePath $tool -ArgumentList $arguments -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    if($p.ExitCode -ne 0){throw "$name failed with exit code $($p.ExitCode)"}; $out=Get-Content -Raw -LiteralPath $o; $err=Get-Content -Raw -LiteralPath $e
    if(($out+"`n"+$err)-match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened|\$\s*fatal'){throw "$name reported Fatal/Error/FAIL"}; if(-not [string]::IsNullOrWhiteSpace($err)){throw "$name wrote diagnostics to stderr"}
    if($marker -and [regex]::Matches($out,[regex]::Escape($marker)).Count -ne 1){throw "$name marker mismatch"}; Write-Status 'running' $name 0 "$name complete"}
try{
    Write-Status 'running' 'setup' 0 'detached window line cache worker started'
    Invoke-Step 'xvlog' (Join-Path $vivado 'xvlog.bat') @('-sv',(Join-Path $rtlRoot 'cnn\c1_window_line_cache_ctrl.sv'),(Join-Path $simRoot 'tb_c1_window_line_cache_ctrl.sv'))
    Invoke-Step 'xelab' (Join-Path $vivado 'xelab.bat') @('tb_c1_window_line_cache_ctrl','-s','tb_c1_window_line_cache_ctrl_sim')
    Invoke-Step 'xsim' (Join-Path $vivado 'xsim.bat') @('tb_c1_window_line_cache_ctrl_sim','-runall') 'C1_WINDOW_LINE_CACHE_RTL_PASS'
    $script:watch.Stop(); Write-Status 'complete' 'done' 0 'C1_WINDOW_LINE_CACHE_RTL_PASS'
}catch{$script:watch.Stop();Write-Status 'failed' $script:step 1 $_.Exception.Message;exit 1}
