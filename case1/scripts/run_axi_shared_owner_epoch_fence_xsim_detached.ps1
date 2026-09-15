param([switch]$Worker, [string]$RunId = '')

# Keep Vivado/xsim outside the caller's Windows job.  The worker owns a
# private runRoot and removes it after the compact marker/status are saved.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlFile = Join-Path $caseRoot 'rtl\dma\c1_axi_shared_owner_epoch_fence.sv'
$tbFile = Join-Path $caseRoot 'sim\tb_c1_axi_shared_owner_epoch_fence.sv'
$logRoot = Join-Path $caseRoot 'logs\axi_shared_owner_epoch_fence_runs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = '"' + $powerShell +
        '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass' +
        ' -WindowStyle Hidden -File "' + $PSCommandPath +
        '" -Worker -RunId ' + $RunId
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$result.ProcessId
        status_path = Join-Path $logRoot "$RunId\status.json"
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $caseRoot "sim\xsim_run_axi_shared_owner_epoch_fence_$RunId"
$runLogRoot = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $caseRoot 'logs\axi_shared_owner_epoch_fence_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:currentStep = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Set-StatusContent {
    param([string]$Path, [string]$Value)
    $Value | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode, [string]$Message)
    $value = [ordered]@{
        run_id=$RunId; state=$State; step=$Step; exit_code=$ExitCode
        message=$Message; process_id=$PID
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
        updated=(Get-Date).ToString('o'); log_directory=$runLogRoot
        run_directory=$runRoot
    } | ConvertTo-Json
    Set-StatusContent $statusPath $value
    Set-StatusContent $latestStatusPath $value
}

function Invoke-VivadoStep {
    param([string]$Name, [string]$Tool, [string[]]$Arguments,
          [string]$ExpectedPass='')
    $script:currentStep = $Name
    Write-Status running $Name 0 "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) { throw "$Name exit $($process.ExitCode)" }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    $all = $stdout + [Environment]::NewLine + $stderr
    if ($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened') {
        throw "$Name log contains an error/failure marker"
    }
    if ($ExpectedPass) {
        $count = [regex]::Matches($all,[regex]::Escape($ExpectedPass)).Count
        if ($count -ne 1) { throw "$Name missing unique marker (count=$count)" }
    }
}

try {
    Write-Status running setup 0 'detached shared owner/epoch fence xsim started'
    Invoke-VivadoStep xvlog (Join-Path $vivadoBin 'xvlog.bat') @(
        '-sv', $rtlFile, $tbFile)
    Invoke-VivadoStep xelab (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_axi_shared_owner_epoch_fence', '-s',
        'tb_c1_axi_shared_owner_epoch_fence_sim')
    Invoke-VivadoStep xsim (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_axi_shared_owner_epoch_fence_sim', '-runall') `
        'C1_AXI_SHARED_OWNER_EPOCH_FENCE_PASS'
    $watch.Stop()
    Write-Status complete done 0 'C1_AXI_SHARED_OWNER_EPOCH_FENCE_PASS'
} catch {
    $watch.Stop()
    Write-Status failed $script:currentStep 1 $_.Exception.Message
    exit 1
} finally {
    # The target is a private runRoot created above; verify its scope before
    # recursive cleanup so a malformed RunId cannot broaden the deletion.
    $resolvedCase = [IO.Path]::GetFullPath($caseRoot)
    $resolvedRun = [IO.Path]::GetFullPath($runRoot)
    if ($resolvedRun.StartsWith($resolvedCase + [IO.Path]::DirectorySeparatorChar)) {
        if (Test-Path -LiteralPath $resolvedRun) {
            Remove-Item -LiteralPath $resolvedRun -Recurse -Force
        }
    } else {
        throw 'refusing to remove a runRoot outside caseRoot'
    }
}
