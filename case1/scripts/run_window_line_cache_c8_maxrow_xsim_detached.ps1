param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Detached xsim regression for the 640x1x2 maximum-row cache boundary.
# Win32_Process creates the worker outside the caller's Windows Job so xsimk
# survives the short-lived Codex command process.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $logRoot "xsim_runs\window_line_cache_c8_maxrow\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine
        CurrentDirectory = $caseRoot
    }
    if ($created.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($created.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$created.ProcessId
        status_path = $statusPath
    } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

$runRoot = Join-Path $simRoot "xsim_run_window_line_cache_c8_maxrow_$RunId"
$runLog = Join-Path $logRoot "xsim_runs\window_line_cache_c8_maxrow\$RunId"
$statusPath = Join-Path $runLog 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_runs\window_line_cache_c8_maxrow_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:step = 'setup'
$script:watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot, $runLog | Out-Null

function Write-Status {
    param(
        [string]$State,
        [string]$Step,
        [int]$Code,
        [string]$Message
    )
    $value = [ordered]@{
        run_id = $RunId
        state = $State
        step = $Step
        exit_code = $Code
        message = $Message
        process_id = $PID
        elapsed_seconds = [math]::Round($script:watch.Elapsed.TotalSeconds, 3)
        updated = (Get-Date).ToString('o')
        log_directory = $runLog
        run_directory = $runRoot
    } | ConvertTo-Json
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-Step {
    param(
        [string]$Name,
        [string]$Tool,
        [string[]]$Arguments,
        [string]$Marker = ''
    )
    $script:step = $Name
    Write-Status 'running' $Name 0 "starting $Name"
    $stdoutPath = Join-Path $runLog "$Name.stdout.log"
    $stderrPath = Join-Path $runLog "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)"
    }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    if (($stdout + "`n" + $stderr) -match
        '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened|\$\s*fatal') {
        throw "$Name reported Fatal/Error/FAIL"
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "$Name wrote diagnostics to stderr"
    }
    if ($Marker -and
        [regex]::Matches($stdout, [regex]::Escape($Marker)).Count -ne 1) {
        throw "$Name marker mismatch"
    }
    Write-Status 'running' $Name 0 "$Name complete"
}

try {
    Write-Status 'running' 'setup' 0 'detached maximum-row cache worker started'
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') @(
        '-sv',
        (Join-Path $rtlRoot 'cnn\c1_window_line_cache_c8.sv'),
        (Join-Path $simRoot 'tb_c1_window_line_cache_c8_maxrow.sv')
    )
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_window_line_cache_c8_maxrow',
        '-s',
        'tb_c1_window_line_cache_c8_maxrow_sim'
    )
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_window_line_cache_c8_maxrow_sim',
        '-runall'
    ) 'C1_WINDOW_LINE_CACHE_C8_MAXROW_PASS'
    $script:watch.Stop()
    Write-Status 'complete' 'done' 0 'C1_WINDOW_LINE_CACHE_C8_MAXROW_PASS'
} catch {
    $script:watch.Stop()
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
}
