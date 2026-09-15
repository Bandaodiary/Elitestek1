param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Tiny malformed-B smoke test.  Launch through WMI so Vivado/xsim is outside
# the interactive Windows Job; the private run tree is removed on completion.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "xsim_runs\axi_n_write_burst_arbiter_orphan\$RunId\status.json"
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
$runRoot = Join-Path $simRoot "xsim_run_axi_n_write_burst_arbiter_orphan_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\axi_n_write_burst_arbiter_orphan\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_axi_n_write_burst_arbiter_orphan_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:currentStep = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode, [string]$Message)
    $obj = [ordered]@{ run_id = $RunId; state = $State; step = $Step;
        exit_code = $ExitCode; message = $Message; process_id = $PID;
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3);
        log_directory = $runLogRoot; run_directory = $runRoot } | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-Step {
    param([string]$Name, [string]$Tool, [string[]]$ToolArgs, [string]$Marker = '')
    $script:currentStep = $Name
    Write-Status 'running' $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $proc = Start-Process -FilePath $Tool -ArgumentList $ToolArgs `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    if ($null -eq $proc -or $proc.ExitCode -ne 0) { throw "$Name failed with exit code $($proc.ExitCode)" }
    $all = (Get-Content -Raw -LiteralPath $out) + "`n" + (Get-Content -Raw -LiteralPath $err)
    if ($all -match '(?im)(^|\s)(Fatal|Error):|C1_AXI_N_WRITE_BURST_ARBITER_ORPHAN_FAIL') {
        throw "$Name reported a simulator error"
    }
    if ($Marker -and ([regex]::Matches($all, [regex]::Escape($Marker)).Count -ne 1)) {
        throw "$Name did not emit exactly one $Marker"
    }
}

try {
    Write-Status 'running' 'setup' 0 'orphan-B smoke started'
    $xvlog = Join-Path $vivadoBin 'xvlog.bat'
    $xelab = Join-Path $vivadoBin 'xelab.bat'
    $xsim = Join-Path $vivadoBin 'xsim.bat'
    Invoke-Step 'xvlog' $xvlog @(
        '-sv', '-nolog',
        (Join-Path $rtlRoot 'dma\c1_axi_n_write_burst_arbiter_128.sv'),
        (Join-Path $simRoot 'tb_c1_axi_n_write_burst_arbiter_orphan_b.sv'))
    Invoke-Step 'xelab' $xelab @(
        'tb_c1_axi_n_write_burst_arbiter_orphan_b', '-s',
        'tb_c1_axi_n_write_burst_arbiter_orphan_b_sim', '-nolog')
    Invoke-Step 'xsim' $xsim @(
        'tb_c1_axi_n_write_burst_arbiter_orphan_b_sim', '-runall', '-nolog') `
        'C1_AXI_N_WRITE_BURST_ARBITER_ORPHAN_PASS'
    $watch.Stop()
    Write-Status 'complete' 'done' 0 'C1_AXI_N_WRITE_BURST_ARBITER_ORPHAN_PASS'
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:currentStep 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
