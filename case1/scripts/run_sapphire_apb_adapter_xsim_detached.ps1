param(
    [switch]$Worker,
    [string]$RunId = ''
)

# A small detached xsim regression for the Sapphire APB/IRQ vendor seam.
# The worker is launched with CREATE_BREAKAWAY_FROM_JOB through the common
# helper, so Vivado/xsim are not children of the desktop agent's Windows Job.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $launcher = Join-Path $PSScriptRoot 'start_detached_process.ps1'
    $launcherOutput = & $powerShell -NoLogo -NoProfile -NonInteractive `
        -ExecutionPolicy Bypass -File $launcher -CommandLine $commandLine `
        -CurrentDirectory $caseRoot 2>&1
    if ($LASTEXITCODE -ne 0) { throw "detached launch failed: $($launcherOutput -join ' ')" }
    $workerPid = [int](($launcherOutput | Select-Object -Last 1).ToString().Trim())
    [ordered]@{
        run_id = $RunId
        worker_pid = $workerPid
        status_path = (Join-Path $logRoot "sapphire_apb_adapter_runs\$RunId\status.json")
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $simRoot "sapphire_apb_adapter_run_$RunId"
$runLogRoot = Join-Path $logRoot "sapphire_apb_adapter_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'sapphire_apb_adapter_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status([string]$state,[string]$step,[int]$exitCode,[string]$message) {
    $value = [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$exitCode;
        message=$message;process_id=$PID;updated=(Get-Date).ToString('o');
        log_directory=$runLogRoot} | ConvertTo-Json
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-Step([string]$name,[string]$tool,[string[]]$arguments,[string]$marker='') {
    $script:step = $name
    Write-Status 'running' $name 0 "starting $name"
    $rawOut = Join-Path $runRoot "$name.raw.stdout.log"
    $rawErr = Join-Path $runRoot "$name.raw.stderr.log"
    $compactOut = Join-Path $runLogRoot "$name.stdout.log"
    $compactErr = Join-Path $runLogRoot "$name.stderr.log"
    $p = Start-Process -FilePath $tool -ArgumentList $arguments -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $rawOut `
        -RedirectStandardError $rawErr
    # Preserve only a bounded tail before evaluating the result.  This keeps
    # failure diagnostics useful without retaining the potentially large raw
    # xsim tree/logs.
    $tail = @(Get-Content -LiteralPath $rawOut -Tail 80 -ErrorAction SilentlyContinue)
    if ($tail.Count -eq 0) { $tail = @('(empty)') }
    $tail | Set-Content -LiteralPath $compactOut -Encoding UTF8
    if (Test-Path -LiteralPath $rawErr) {
        @(Get-Content -LiteralPath $rawErr -Tail 40 -ErrorAction SilentlyContinue) |
            Set-Content -LiteralPath $compactErr -Encoding UTF8
    }
    if ($p.ExitCode -ne 0) { throw "$name exit $($p.ExitCode)" }
    $stderrHasText = Select-String -LiteralPath $rawErr -Pattern '\S' -Quiet -ErrorAction SilentlyContinue
    $bad = Select-String -LiteralPath $rawOut -Pattern '(?i)\b(FATAL|ERROR|FAIL)\b|cannot be opened|\$fatal' -Quiet -ErrorAction SilentlyContinue
    if ($stderrHasText -or $bad) { throw "$name emitted diagnostics" }
    if ($marker) {
        $count = [regex]::Matches((Get-Content -Raw -LiteralPath $rawOut), [regex]::Escape($marker)).Count
        if ($count -ne 1) { throw "$name marker count=$count" }
    }
}

try {
    Write-Status 'running' 'setup' 0 'detached Sapphire adapter xsim worker started'
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') @(
        '-sv',
        (Join-Path $rtlRoot 'vendor\c1_sapphire_apb_master_adapter.sv'),
        (Join-Path $rtlRoot 'vendor\c1_sapphire_irq_adapter.sv'),
        (Join-Path $simRoot 'tb_c1_sapphire_apb_master_adapter.sv'))
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_sapphire_apb_master_adapter', '-s', 'tb_c1_sapphire_apb_master_adapter_sim')
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_sapphire_apb_master_adapter_sim', '-runall') 'C1_SAPPHIRE_APB_ADAPTER_PASS'
    Write-Status 'complete' 'done' 0 'Sapphire APB/IRQ adapter regression passed'
} catch {
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    # Do not retain xsim/xelab work trees; only bounded logs/status remain.
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
