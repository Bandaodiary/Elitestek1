param(
    [switch]$Worker,
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptPath = $PSCommandPath

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $caseRoot "logs\apb_isp_config_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
                   "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" " +
                   "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine
        CurrentDirectory = $caseRoot
    }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$result.ProcessId
        status_path = $statusPath
    } | ConvertTo-Json
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RunId)) {
    throw 'Worker mode requires -RunId'
}

$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
$runRoot = Join-Path $simRoot "apb_isp_config_xsim_run_$RunId"
$runLogRoot = Join-Path $logRoot "apb_isp_config_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_apb_isp_config_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'

New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status {
    param(
        [string]$State,
        [string]$Step,
        [int]$ExitCode,
        [string]$Message
    )
    $status = [ordered]@{
        run_id = $RunId
        state = $State
        step = $Step
        exit_code = $ExitCode
        message = $Message
        process_id = $PID
        updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot
        run_directory = $runRoot
    } | ConvertTo-Json
    $status | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $status | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-LoggedStep {
    param(
        [string]$Name,
        [string]$Tool,
        [string[]]$Arguments
    )
    Write-Status -State 'running' -Step $Name -ExitCode 0 -Message "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)"
    }
}

try {
    Write-Status -State 'running' -Step 'setup' -ExitCode 0 `
        -Message 'detached APB ISP configuration verification worker started'

    Invoke-LoggedStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments @(
            '-sv',
            (Join-Path $rtlRoot 'control\c1_apb_isp_config.sv'),
            (Join-Path $simRoot 'tb_c1_apb_isp_config.sv')
        )
    Invoke-LoggedStep -Name 'xelab' -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @('tb_c1_apb_isp_config', '-s', 'tb_c1_apb_isp_config_sim')
    Invoke-LoggedStep -Name 'xsim' -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_apb_isp_config_sim', '-runall')

    $passMarker = 'C1_APB_ISP_CONFIG_PASS cfg=8 gamma=16'
    $simOutput = Get-Content -Raw -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log')
    if ([regex]::Matches($simOutput, [regex]::Escape($passMarker)).Count -ne 1) {
        throw "xsim output does not contain exactly one PASS marker: $passMarker"
    }

    foreach ($name in @('xvlog', 'xelab', 'xsim')) {
        $stdoutPath = Join-Path $runLogRoot "$name.stdout.log"
        $stderrPath = Join-Path $runLogRoot "$name.stderr.log"
        $stdout = Get-Content -Raw -LiteralPath $stdoutPath
        if ($stdout -match '(?i)\b(fatal|error|fail)\b') {
            throw "$name stdout contains Fatal/Error/FAIL"
        }
        if ((Get-Item -LiteralPath $stderrPath).Length -ne 0) {
            throw "$name stderr is not empty"
        }
    }

    Write-Status -State 'complete' -Step 'done' -ExitCode 0 -Message $passMarker
} catch {
    Write-Status -State 'failed' -Step 'exception' -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
}
