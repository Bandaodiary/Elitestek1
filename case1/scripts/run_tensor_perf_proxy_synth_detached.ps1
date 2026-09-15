param(
    [switch]$Worker,
    [string]$RunId = ''
)

# WMI worker keeps Vivado outside the caller's Windows Job.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs'
$runRootBase = Join-Path $caseRoot 'sim'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "tensor_perf_proxy_synth_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine=$commandLine; CurrentDirectory=$caseRoot
    }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{run_id=$RunId;worker_pid=[int]$result.ProcessId;status_path=$statusPath} | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $runRootBase "tensor_perf_proxy_synth_$RunId"
$runLogRoot = Join-Path $logRoot "tensor_perf_proxy_synth_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'tensor_perf_proxy_synth_status.json'
$vivado = 'D:\vivado\vivado\Vivado\2023.1\bin\vivado.bat'
$tcl = Join-Path $PSScriptRoot 'synth_tensor_perf_proxy.tcl'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status {
    param([string]$State,[int]$ExitCode,[string]$Message)
    $obj=[ordered]@{run_id=$RunId;state=$State;exit_code=$ExitCode;message=$Message;
        process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        updated=(Get-Date).ToString('o');log_directory=$runLogRoot;run_directory=$runRoot} | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

try {
    Write-Status running 0 'detached tensor performance proxy synthesis started'
    $stdoutPath=Join-Path $runLogRoot 'vivado.stdout.log'; $stderrPath=Join-Path $runLogRoot 'vivado.stderr.log'
    $p=Start-Process -FilePath $vivado -ArgumentList @('-mode','batch','-source',$tcl,'-notrace') `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if($null -eq $p -or $p.ExitCode -ne 0){throw "Vivado exit $($p.ExitCode)"}
    $out=Get-Content -Raw -LiteralPath $stdoutPath; $err=Get-Content -Raw -LiteralPath $stderrPath
    if(-not [string]::IsNullOrWhiteSpace($err)){throw 'Vivado wrote stderr'}
    if($out -match '(?im)^ERROR:|\bFAIL\b|Fatal'){throw 'Vivado reported error/fail'}
    if(([regex]::Matches($out,'C1_TENSOR_PERF_PACKER_PROXY_SYNTH_PASS')).Count -ne 1){throw 'proxy synth marker mismatch'}
    $watch.Stop(); Write-Status complete 0 'C1_TENSOR_PERF_PACKER_PROXY_SYNTH_PASS'
} catch {
    $watch.Stop(); Write-Status failed 1 $_.Exception.Message; exit 1
}
