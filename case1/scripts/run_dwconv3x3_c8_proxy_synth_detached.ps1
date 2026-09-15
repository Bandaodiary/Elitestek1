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
        CommandLine = $commandLine
        CurrentDirectory = $caseRoot
    }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$result.ProcessId
        status_path = (Join-Path $logRoot "dwconv3x3_c8_proxy_synth_runs\$RunId\status.json")
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

$runRoot = Join-Path $caseRoot "sim\dwconv3x3_c8_proxy_synth_run_$RunId"
$runLogRoot = Join-Path $logRoot "dwconv3x3_c8_proxy_synth_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'dwconv3x3_c8_proxy_synth_status.json'
$vivado = 'D:\vivado\vivado\Vivado\2023.1\bin\vivado.bat'
$vivadoRtScripts = 'D:\vivado\vivado\Vivado\2023.1\scripts\rt'
$tcl = Join-Path $PSScriptRoot 'synth_dwconv3x3_c8_proxy.tcl'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode, [string]$Message)
    $value = [ordered]@{
        run_id = $RunId; state = $State; step = $Step
        exit_code = $ExitCode; message = $Message; process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot
        report_directory = (Join-Path $runRoot 'reports')
    } | ConvertTo-Json
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

try {
    Write-Status running prewarm 0 'pre-reading Vivado runtime Tcl files'
    $prewarmBuffer = New-Object byte[] 65536
    Get-ChildItem -LiteralPath $vivadoRtScripts -Filter '*.tcl' -File -Recurse |
        ForEach-Object {
            $stream = [IO.File]::OpenRead($_.FullName)
            while ($stream.Read($prewarmBuffer, 0, $prewarmBuffer.Length) -gt 0) {}
            $stream.Dispose()
        }
    Write-Status running vivado 0 'detached DW C8 proxy synthesis started'
    $stdoutPath = Join-Path $runLogRoot 'vivado.stdout.log'
    $stderrPath = Join-Path $runLogRoot 'vivado.stderr.log'
    $process = Start-Process -FilePath $vivado -ArgumentList @(
        '-mode', 'batch', '-source', $tcl, '-notrace'
    ) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        throw "Vivado failed with exit code $($process.ExitCode)"
    }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw 'Vivado wrote unexpected stderr'
    }
    if (($stdout + "`n" + $stderr) -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b') {
        throw 'Vivado log contains ERROR/FATAL/FAIL diagnostics'
    }
    if ([regex]::Matches(
            $stdout, 'C1_DWCONV3X3_C8_PROXY_SYNTH_PASS').Count -ne 1) {
        throw 'Vivado did not emit the unique DW proxy PASS marker'
    }
    $watch.Stop()
    Write-Status complete done 0 'C1_DWCONV3X3_C8_PROXY_SYNTH_PASS'
} catch {
    $watch.Stop()
    Write-Status failed vivado 1 $_.Exception.Message
    exit 1
}
