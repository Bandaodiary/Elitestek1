param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Vivado/xsim is deliberately detached with WMI so its process tree is not
# tied to the Codex Windows job.  The worker removes its private xsim tree on
# both success and failure; only short stdout/stderr/status files remain.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "xsim_runs\dot8x8_bank\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{ run_id = $RunId; worker_pid = [int]$result.ProcessId;
                status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_run_dot8x8_bank_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\dot8x8_bank\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_runs\dot8x8_bank_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()

New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null
function Write-Status([string]$State, [string]$Step, [int]$ExitCode, [string]$Message) {
    $obj = [ordered]@{ run_id=$RunId; state=$State; step=$Step; exit_code=$ExitCode;
        message=$Message; process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        log_directory=$runLogRoot; run_directory=$runRoot } | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}
function Invoke-Step([string]$Name, [string]$Tool, [string[]]$ToolArgs,
                     [string]$Marker='') {
    Write-Status 'running' $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $startParams = @{ FilePath = $Tool; ArgumentList = $ToolArgs;
        WorkingDirectory = $runRoot; WindowStyle = 'Hidden'; Wait = $true;
        PassThru = $true; RedirectStandardOutput = $out;
        RedirectStandardError = $err }
    $p = Start-Process @startParams
    if ($p.ExitCode -ne 0) { throw "$Name exit code $($p.ExitCode)" }
    $text = (Get-Content -Raw -LiteralPath $out) + "`n" +
            (Get-Content -Raw -LiteralPath $err)
    if ($text -match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|\$fatal') {
        throw "$Name reported failure"
    }
    if ($Marker -and ([regex]::Matches($text,[regex]::Escape($Marker)).Count -ne 1)) {
        throw "$Name did not emit exactly one $Marker"
    }
}

try {
    Write-Status 'running' 'setup' 0 'detached bank worker started'
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') @(
        '-sv', (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum.sv'),
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_pipelined.sv'),
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_treepipe.sv'),
        (Join-Path $rtlRoot 'cnn\c1_requant_bank8.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_core.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_bank.sv'),
        (Join-Path $simRoot 'tb_c1_dot8x8_requant_bank.sv'))
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_dot8x8_requant_bank', '-s', 'tb_c1_dot8x8_requant_bank_sim')
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_dot8x8_requant_bank_sim', '-runall') `
        'C1_DOT8X8_REQUANT_BANK_PASS'
    $watch.Stop(); Write-Status 'complete' 'done' 0 'C1_DOT8X8_REQUANT_BANK_PASS'
} catch {
    $watch.Stop(); Write-Status 'failed' 'worker' 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
