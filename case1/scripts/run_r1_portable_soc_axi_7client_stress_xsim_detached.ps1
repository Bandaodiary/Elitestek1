param(
    [switch]$Worker,
    [string]$RunId = ''
)

# LEGACY diagnostic only; use run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1
# for current portable-SoC evidence.  The worker is launched with WMI so the
# Vivado/xsim process tree is not attached to the caller's Windows Job.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "r1_portable_soc_axi_7client_stress_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine
        CurrentDirectory = $caseRoot
    }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{ run_id=$RunId; worker_pid=[int]$result.ProcessId; status_path=$statusPath } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $simRoot "r1_portable_soc_axi_7client_stress_xsim_run_$RunId"
$runLogRoot = Join-Path $logRoot "r1_portable_soc_axi_7client_stress_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_r1_portable_soc_axi_7client_stress_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep = 'setup'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status {
    param([string]$State,[string]$Step,[int]$ExitCode,[string]$Message)
    $value = [ordered]@{
        run_id=$RunId; state=$State; step=$Step; exit_code=$ExitCode
        message=$Message; process_id=$PID
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
        updated=(Get-Date).ToString('o'); log_directory=$runLogRoot; run_directory=$runRoot
    } | ConvertTo-Json
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-XsimStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$ExpectedPass='')
    $script:currentStep = $Name
    Write-Status running $Name 0 "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $toolPath = Join-Path $vivadoBin $Tool
    $process = Start-Process -FilePath $toolPath -ArgumentList $Arguments -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    if ($null -eq $process) { throw "$Name did not return a process object" }
    if ($process.ExitCode -ne 0) { throw "$Name exit $($process.ExitCode)" }
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { '' }
    $all = $stdout + "`n" + $stderr
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw "$Name wrote stderr" }
    if ($all -match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened|\$\s*fatal') {
        throw "$Name reported Fatal/Error/FAIL"
    }
    if ($ExpectedPass -and ([regex]::Matches($all,[regex]::Escape($ExpectedPass)).Count -ne 1)) {
        throw "$Name marker mismatch"
    }
}

try {
    Write-Status running setup 0 'detached seven-client portable-SoC stress started'
    $packageSources = @(
        (Join-Path $rtlRoot 'common\c1_fixed_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_decoder_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_frame_buffer_pkg.sv')
    )
    $packageSet = @{}
    foreach ($source in $packageSources) { $packageSet[$source] = $true }
    $rtlSources = @(Get-ChildItem -LiteralPath $rtlRoot -Recurse -File -Filter '*.sv' |
        Where-Object { -not $packageSet.ContainsKey($_.FullName) } |
        Sort-Object FullName | Select-Object -ExpandProperty FullName)
    $sources = @($packageSources + $rtlSources + (Join-Path $simRoot 'tb_c1_r1_portable_soc_axi_stress.sv'))
    Invoke-XsimStep xvlog 'xvlog.bat' (@('-sv') + $sources)
    Invoke-XsimStep xelab 'xelab.bat' @('tb_c1_r1_portable_soc_axi_stress','-s','tb_c1_r1_portable_soc_axi_stress_sim')
    Invoke-XsimStep xsim 'xsim.bat' @('tb_c1_r1_portable_soc_axi_stress_sim','-runall') 'C1_R1_PORTABLE_SOC_AXI_7CLIENT_STRESS_PASS'
    $watch.Stop(); Write-Status complete done 0 'C1_R1_PORTABLE_SOC_AXI_7CLIENT_STRESS_PASS'
} catch {
    $watch.Stop(); Write-Status failed $script:currentStep 1 $_.Exception.Message; exit 1
}
