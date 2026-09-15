param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Detached Vivado/xsim runner for the cache-client + seven-client arbiter
# fabric regression.  Win32_Process keeps the worker outside the caller's
# Windows Job, matching the project's boardless simulation policy.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "cache_fabric_ddr_bfm_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine; CurrentDirectory = $caseRoot
    }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{run_id=$RunId;worker_pid=[int]$result.ProcessId;status_path=$statusPath} | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $simRoot "xsim_cache_fabric_ddr_bfm_run_$RunId"
$runLogRoot = Join-Path $logRoot "cache_fabric_ddr_bfm_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_cache_fabric_ddr_bfm_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep = 'setup'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status {
    param([string]$State,[string]$Step,[int]$ExitCode,[string]$Message)
    $value = [ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$ExitCode;
        message=$Message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        updated=(Get-Date).ToString('o');log_directory=$runLogRoot;run_directory=$runRoot} | ConvertTo-Json
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-XsimStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$ExpectedPass='')
    $script:currentStep = $Name
    Write-Status running $Name 0 "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $process = Start-Process -FilePath (Join-Path $vivadoBin $Tool) -ArgumentList $Arguments -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($null -eq $process) { throw "$Name did not return a process object" }
    if ($process.ExitCode -ne 0) { throw "$Name exit $($process.ExitCode)" }
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { '' }
    $all = $stdout + "`n" + $stderr
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw "$Name wrote stderr" }
    if ($all -match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened|\$\s*fatal') { throw "$Name reported Fatal/Error/FAIL" }
    if ($ExpectedPass -and ([regex]::Matches($all,[regex]::Escape($ExpectedPass)).Count -ne 1)) { throw "$Name marker mismatch" }
}

try {
    Write-Status running setup 0 'detached cache-client DDR BFM regression started'
    $sources = @(
        (Join-Path $rtlRoot 'cnn\c1_window_line_cache_c8.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_window_cache_seam.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_bridge.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_window_cache_axi_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_axi_n_serial_arbiter_128.sv'),
        (Join-Path $simRoot 'tb_c1_cache_fabric_ddr_bfm.sv')
    )
    Invoke-XsimStep xvlog 'xvlog.bat' (@('-sv') + $sources)
    Invoke-XsimStep xelab 'xelab.bat' @('tb_c1_cache_fabric_ddr_bfm','-s','tb_c1_cache_fabric_ddr_bfm_sim')
    Invoke-XsimStep xsim 'xsim.bat' @('tb_c1_cache_fabric_ddr_bfm_sim','-runall') 'C1_CACHE_FABRIC_DDR_BFM_PASS'
    $watch.Stop(); Write-Status complete done 0 'C1_CACHE_FABRIC_DDR_BFM_PASS'
} catch {
    $watch.Stop(); Write-Status failed $script:currentStep 1 $_.Exception.Message; exit 1
}
