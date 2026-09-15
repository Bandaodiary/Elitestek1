param([switch]$Worker, [string]$RunId = '')
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs'
if (-not $Worker) {
    $RunId = [guid]::NewGuid().ToString('N')
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine=$commandLine; CurrentDirectory=$caseRoot
    }
    if ($result.ReturnValue -ne 0) { throw "WMI create failed: $($result.ReturnValue)" }
    [ordered]@{
        run_id=$RunId; worker_pid=[int]$result.ProcessId
        status_path=(Join-Path $logRoot "microstyle_cnn_proxy_synth_runs\$RunId\status.json")
    } | ConvertTo-Json
    return
}
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $caseRoot "sim\microstyle_cnn_proxy_synth_run_$RunId"
$runLogRoot = Join-Path $logRoot "microstyle_cnn_proxy_synth_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'microstyle_cnn_proxy_synth_status.json'
$vivado = 'D:\vivado\vivado\Vivado\2023.1\bin\vivado.bat'
$rt = 'D:\vivado\vivado\Vivado\2023.1\scripts\rt'
$tcl = Join-Path $PSScriptRoot 'synth_microstyle_cnn_top_proxy.tcl'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null
function Write-Status([string]$State,[string]$Step,[int]$Code,[string]$Message) {
    $value=[ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$Code;
        message=$Message;process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        updated=(Get-Date).ToString('o');log_directory=$runLogRoot;
        report_directory=(Join-Path $runRoot 'reports')} | ConvertTo-Json
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}
try {
    Write-Status running prewarm 0 'pre-reading Vivado runtime Tcl files'
    $buffer=New-Object byte[] 65536
    Get-ChildItem -LiteralPath $rt -Filter '*.tcl' -File -Recurse | ForEach-Object {
        $stream=[IO.File]::OpenRead($_.FullName)
        while($stream.Read($buffer,0,$buffer.Length)-gt 0){}
        $stream.Dispose()
    }
    Write-Status running vivado 0 'detached MicroStyle CNN proxy synthesis started'
    $stdout=Join-Path $runLogRoot 'vivado.stdout.log'
    $stderr=Join-Path $runLogRoot 'vivado.stderr.log'
    $process=Start-Process -FilePath $vivado -ArgumentList @(
        '-mode','batch','-source',$tcl,'-notrace') -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr
    if($process.ExitCode-ne 0){throw "Vivado failed with exit code $($process.ExitCode)"}
    $out=Get-Content -Raw -LiteralPath $stdout
    $err=Get-Content -Raw -LiteralPath $stderr
    if(-not [string]::IsNullOrWhiteSpace($err)){throw 'Vivado wrote stderr'}
    if(($out+"`n"+$err)-match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b'){throw 'Vivado diagnostic failure'}
    if([regex]::Matches($out,'C1_MICROSTYLE_CNN_TOP_PROXY_SYNTH_PASS').Count-ne 1){throw 'missing unique PASS'}
    $watch.Stop(); Write-Status complete done 0 'C1_MICROSTYLE_CNN_TOP_PROXY_SYNTH_PASS'
} catch {
    $watch.Stop(); Write-Status failed vivado 1 $_.Exception.Message; exit 1
}
