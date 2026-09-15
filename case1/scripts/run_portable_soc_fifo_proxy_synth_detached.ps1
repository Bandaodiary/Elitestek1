param(
    [switch]$Worker,
    [string]$RunId = ''
)

# WMI creates the worker outside the caller's Windows Job.  Vivado and all
# helper processes therefore survive a Codex window/job interruption.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed with return value $($result.ReturnValue)" }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$result.ProcessId
        status_path = (Join-Path $logRoot "portable_soc_fifo_proxy_runs\$RunId\status.json")
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
$runRoot = Join-Path $caseRoot "sim\portable_soc_fifo_proxy_run_$RunId"
$runLogRoot = Join-Path $logRoot "portable_soc_fifo_proxy_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'portable_soc_fifo_proxy_status.json'
$vivado = 'D:\vivado\vivado\Vivado\2023.1\bin\vivado.bat'
$vivadoRtScripts = 'D:\vivado\vivado\Vivado\2023.1\scripts\rt'
$tcl = Join-Path $PSScriptRoot 'synth_portable_soc_fifo_proxy.tcl'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Set-StatusContent {
    param([string]$Path, [string]$Value)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $Value | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
            return
        } catch [IO.IOException] {
            if ($attempt -eq 19) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}
function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode, [string]$Message)
    $value = [ordered]@{
        run_id = $RunId; state = $State; step = $Step; exit_code = $ExitCode
        message = $Message; process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        updated = (Get-Date).ToString('o'); log_directory = $runLogRoot
        report_directory = (Join-Path $runRoot 'reports')
    } | ConvertTo-Json
    Set-StatusContent $statusPath $value
    Set-StatusContent $latestStatusPath $value
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
    $parallelPrep = Join-Path $vivadoRtScripts 'fpga_tcl\rtSynthParallelPrep.tcl'
    $stream = [IO.File]::OpenRead($parallelPrep)
    while ($stream.Read($prewarmBuffer, 0, $prewarmBuffer.Length) -gt 0) {}
    $stream.Dispose()

    Write-Status running vivado 0 'detached portable SoC FIFO proxy synthesis started'
    $stdoutPath = Join-Path $runLogRoot 'vivado.stdout.log'
    $stderrPath = Join-Path $runLogRoot 'vivado.stderr.log'
    $process = Start-Process -FilePath $vivado -ArgumentList @(
        '-mode', 'batch', '-source', $tcl, '-notrace'
    ) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) { throw "Vivado failed with exit code $($process.ExitCode)" }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw 'Vivado wrote unexpected stderr' }
    if (($stdout + "`n" + $stderr) -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b') {
        throw 'Vivado log contains ERROR/FATAL/FAIL diagnostics'
    }
    if ([regex]::Matches($stdout, 'C1_PORTABLE_SOC_FIFO_PROXY_PASS').Count -ne 2) {
        throw 'Vivado did not emit exactly two variant PASS markers'
    }
    if ([regex]::Matches($stdout, 'C1_PORTABLE_SOC_FIFO_PROXY_SYNTH_PASS variants=2').Count -ne 1) {
        throw 'Vivado did not emit the unique final PASS marker'
    }
    $watch.Stop()
    Write-Status complete done 0 'C1_PORTABLE_SOC_FIFO_PROXY_SYNTH_PASS variants=2 frame=640x480'
} catch {
    $watch.Stop()
    Write-Status failed vivado 1 $_.Exception.Message
    exit 1
}
