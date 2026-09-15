param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Detached Vivado proxy for both PERF_MODE=0 and PERF_MODE=1 seam branches.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "tensor_mem_path_seam_proxy_synth_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed with return value $($result.ReturnValue)" }
    [ordered]@{ run_id=$RunId; worker_pid=[int]$result.ProcessId; status_path=$statusPath } | ConvertTo-Json
    exit 0
}
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
$runRoot = Join-Path $simRoot "tensor_mem_path_seam_proxy_synth_$RunId"
$runLogRoot = Join-Path $logRoot "tensor_mem_path_seam_proxy_synth_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'tensor_mem_path_seam_proxy_synth_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep='setup'; $script:watch=[Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null
function Set-StatusContent { param([string]$Path,[string]$Value)
    for($i=0;$i -lt 20;$i++){try{$Value|Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop;return}catch [IO.IOException]{if($i -eq 19){throw};Start-Sleep -Milliseconds 25}} }
function Write-Status { param([string]$State,[string]$Step,[int]$ExitCode,[string]$Message)
    $s=[ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$ExitCode;message=$Message;process_id=$PID;elapsed_seconds=[math]::Round($script:watch.Elapsed.TotalSeconds,3);updated=(Get-Date).ToString('o');log_directory=$runLogRoot;run_directory=$runRoot}|ConvertTo-Json
    Set-StatusContent $statusPath $s; Set-StatusContent $latestStatusPath $s }
try {
    Write-Status 'running' 'vivado' 0 'starting detached seam proxy synth'
    $stdoutPath=Join-Path $runLogRoot 'vivado.stdout.log'; $stderrPath=Join-Path $runLogRoot 'vivado.stderr.log'
    $p=Start-Process -FilePath (Join-Path $vivadoBin 'vivado.bat') -ArgumentList @('-mode','batch','-nojournal','-nolog','-notrace','-source',(Join-Path $caseRoot 'scripts\synth_tensor_mem_path_seam_proxy.tcl')) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if($p.ExitCode -ne 0){throw "Vivado failed with exit code $($p.ExitCode)"}
    $o=Get-Content -Raw -LiteralPath $stdoutPath; $e=Get-Content -Raw -LiteralPath $stderrPath
    if(($o+"`n"+$e)-match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened'){throw 'Vivado reported Fatal/Error/FAIL'}
    if(-not [string]::IsNullOrWhiteSpace($e)){throw 'Vivado wrote diagnostics to stderr'}
    if([regex]::Matches($o,'C1_TENSOR_MEM_PATH_SEAM_PROXY_SYNTH_PASS').Count -ne 1){throw 'proxy synth marker missing or duplicated'}
    $script:watch.Stop(); Write-Status 'complete' 'done' 0 'C1_TENSOR_MEM_PATH_SEAM_PROXY_SYNTH_PASS'
} catch { $script:watch.Stop(); Write-Status 'failed' $script:currentStep 1 $_.Exception.Message; exit 1 }
