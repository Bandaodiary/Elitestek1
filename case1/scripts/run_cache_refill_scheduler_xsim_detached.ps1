param(
    [switch]$Worker,
    [string]$RunId = '',
    [ValidateSet(1,2,3)][int]$SchedulerWindow = 2,
    [switch]$RequestHandoff
)

# Detached, self-cleaning xsim runner for the read-only refill scheduler.
# The worker is created through WMI so Vivado/xsim is not attached to the
# caller's Windows job.  Tool logs stay private until the step completes;
# only a marker and a short tail are retained in the persistent log folder.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    $statusPath = Join-Path $logRoot "xsim_runs\cache_refill_scheduler\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId -SchedulerWindow $SchedulerWindow"
    if ($RequestHandoff) { $commandLine += ' -RequestHandoff' }
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed: $($result.ReturnValue)"
    }
    [ordered]@{ run_id=$RunId; worker_pid=[int]$result.ProcessId;
                status_path=$statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_cache_refill_scheduler_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\cache_refill_scheduler\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_runs\cache_refill_scheduler_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status([string]$State, [string]$Step, [int]$ExitCode,
                      [string]$Message) {
    $obj = [ordered]@{ run_id=$RunId; state=$State; step=$Step;
        exit_code=$ExitCode; message=$Message; process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        log_directory=$runLogRoot; run_directory=$runRoot } | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Save-CompactLog([string]$Source, [string]$Destination,
                         [string]$Marker='') {
    $lines = @()
    if (Test-Path -LiteralPath $Source) {
        if ($Marker) {
            $lines += @(Select-String -LiteralPath $Source `
                -Pattern ([regex]::Escape($Marker)) -AllMatches `
                -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Line })
        }
        $lines += @(Get-Content -LiteralPath $Source -Tail 80 `
                    -ErrorAction SilentlyContinue)
    }
    if ($lines.Count -eq 0) { $lines = @('(empty)') }
    $lines | Select-Object -Unique |
        Set-Content -LiteralPath $Destination -Encoding UTF8
}

function Invoke-Step([string]$Name, [string]$Tool, [string[]]$ToolArgs,
                     [string]$Marker='') {
    Write-Status 'running' $Name 0 "starting $Name"
    $rawOut = Join-Path $runRoot "$Name.stdout.raw.log"
    $rawErr = Join-Path $runRoot "$Name.stderr.raw.log"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    try {
        $sp = @{ FilePath=$Tool; ArgumentList=$ToolArgs;
            WorkingDirectory=$runRoot; WindowStyle='Hidden'; Wait=$true;
            PassThru=$true; RedirectStandardOutput=$rawOut;
            RedirectStandardError=$rawErr }
        $proc = Start-Process @sp
        if ($proc.ExitCode -ne 0) {
            throw "$Name exit code $($proc.ExitCode)"
        }
        if (Select-String -LiteralPath $rawErr -Pattern '\S' -Quiet `
            -ErrorAction SilentlyContinue) {
            $tail = (Get-Content -LiteralPath $rawErr -Tail 12 `
                     -ErrorAction SilentlyContinue) -join ' '
            throw "$Name reported stderr: $tail"
        }
        $bad = '(?i)(^|\s)(Fatal|Error):|\bFAIL\b|\$fatal'
        if (Select-String -LiteralPath $rawOut -Pattern $bad -Quiet `
            -ErrorAction SilentlyContinue) {
            $tail = (Get-Content -LiteralPath $rawOut -Tail 12 `
                     -ErrorAction SilentlyContinue) -join ' '
            throw "$Name reported failure: $tail"
        }
        if ($Marker) {
            $matches = @(Select-String -LiteralPath $rawOut `
                -Pattern ([regex]::Escape($Marker)) -AllMatches `
                -ErrorAction SilentlyContinue)
            $count = 0
            foreach ($hit in $matches) {
                if ($hit.Matches) { $count += $hit.Matches.Count }
                else { $count++ }
            }
            if ($count -ne 1) {
                throw "$Name did not emit exactly one $Marker"
            }
        }
    } finally {
        Save-CompactLog $rawOut $out $Marker
        Save-CompactLog $rawErr $err
    }
}

try {
    Write-Status 'running' 'setup' 0 'detached cache-refill scheduler worker started'
    $xvlogArgs = @('-sv', '-nolog',
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler.sv'),
        (Join-Path $simRoot 'tb_c1_cache_refill_scheduler.sv'))
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    $xelabArgs = @(
        'tb_c1_cache_refill_scheduler', '-s',
        'tb_c1_cache_refill_scheduler_sim', '-nolog')
    $xelabArgs += @('-generic_top', "`"MAX_OUT=$SchedulerWindow`"")
    if ($RequestHandoff) { $xelabArgs += @('-generic_top', '"REQ_HANDOFF=1"') }
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') $xelabArgs
    $marker = 'C1_CACHE_REFILL_SCHEDULER_PASS'
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_cache_refill_scheduler_sim', '-runall', '-nolog') $marker
    $watch.Stop()
    Write-Status 'complete' 'done' 0 $marker
} catch {
    $watch.Stop()
    Write-Status 'failed' 'worker' 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
