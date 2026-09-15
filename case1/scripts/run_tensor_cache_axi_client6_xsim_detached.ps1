param(
    [switch]$Worker,
    [string]$RunId = ''
)

# The worker is launched through WMI so Vivado/xsim is not attached to the
# current Windows Job.  This is intentionally a small boundary regression,
# separate from the long portable-SoC DDR test.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "tensor_cache_axi_client6_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine; CurrentDirectory = $caseRoot
    }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{ run_id=$RunId; worker_pid=[int]$result.ProcessId; status_path=$statusPath } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $simRoot "tensor_cache_axi_client6_xsim_run_$RunId"
$runLogRoot = Join-Path $logRoot "tensor_cache_axi_client6_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_tensor_cache_axi_client6_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:step = 'setup'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status([string]$State,[string]$Step,[int]$ExitCode,[string]$Message) {
    $value = [ordered]@{ run_id=$RunId; state=$State; step=$Step; exit_code=$ExitCode;
        message=$Message; process_id=$PID; elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        updated=(Get-Date).ToString('o'); log_directory=$runLogRoot; run_directory=$runRoot } | ConvertTo-Json
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-Step([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$Marker='') {
    $script:step = $Name; Write-Status 'running' $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"; $err = Join-Path $runLogRoot "$Name.stderr.log"
    $p = Start-Process -FilePath (Join-Path $vivadoBin $Tool) -ArgumentList $Arguments -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if ($null -eq $p -or $p.ExitCode -ne 0) { throw "$Name exit $($p.ExitCode)" }
    $stdout = if (Test-Path $out) { Get-Content -Raw $out } else { '' }
    $stderr = if (Test-Path $err) { Get-Content -Raw $err } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw "$Name wrote stderr" }
    $all = $stdout + "`n" + $stderr
    if ($all -match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|\$fatal') { throw "$Name reported Fatal/Error/FAIL" }
    if ($Marker -and ([regex]::Matches($all,[regex]::Escape($Marker)).Count -ne 1)) { throw "$Name marker mismatch" }
}

try {
    Write-Status 'running' 'setup' 0 'detached tensor cache client-6 boundary test started'
    $rtl = Join-Path $caseRoot 'rtl'
    $sources = @(
        (Join-Path $rtl 'common\c1_fixed_pkg.sv'),
        (Join-Path $rtl 'cnn\c1_window_line_cache_c8.sv'),
        (Join-Path $rtl 'dma\c1_axi_n_serial_arbiter_128.sv'),
        (Join-Path $rtl 'dma\c1_tensor_mem_axi128_bridge.sv'),
        (Join-Path $rtl 'dma\c1_tensor_window_cache_seam.sv'),
        (Join-Path $rtl 'dma\c1_tensor_window_cache_axi_client.sv'),
        (Join-Path $simRoot 'tb_c1_tensor_window_cache_axi_client.sv')
    )
    Invoke-Step 'xvlog' 'xvlog.bat' (@('-sv') + $sources)
    Invoke-Step 'xelab' 'xelab.bat' @('tb_c1_tensor_window_cache_axi_client','-s','tb_c1_tensor_window_cache_axi_client_sim')
    Invoke-Step 'xsim' 'xsim.bat' @('tb_c1_tensor_window_cache_axi_client_sim','-runall') 'C1_TENSOR_CACHE_AXI_CLIENT6_PASS'
    $watch.Stop(); Write-Status 'complete' 'done' 0 'C1_TENSOR_CACHE_AXI_CLIENT6_PASS'
} catch {
    $watch.Stop(); Write-Status 'failed' $script:step 1 $_.Exception.Message; exit 1
}
