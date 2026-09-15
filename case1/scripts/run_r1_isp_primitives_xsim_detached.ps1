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
    $statusPath = Join-Path $caseRoot "logs\r1_isp_primitive_runs\$RunId\status.json"
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
$goldenRoot = Join-Path $caseRoot 'golden'
$logRoot = Join-Path $caseRoot 'logs'
$runRoot = Join-Path $simRoot "r1_isp_primitives_xsim_run_$RunId"
$runLogRoot = Join-Path $logRoot "r1_isp_primitive_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_r1_isp_primitives_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$pythonExe = (Get-Command python -ErrorAction Stop).Source

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
        -Message 'detached R1 ISP primitive verification worker started'

    Invoke-LoggedStep -Name 'vector_gen' -Tool $pythonExe -Arguments @(
        (Join-Path $goldenRoot 'generate_r1_isp_primitive_vectors.py'),
        '--output-dir', $runRoot,
        '--random-count', '10000',
        '--seed', '20260824'
    )
    Invoke-LoggedStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments @(
            '-sv',
            (Join-Path $rtlRoot 'video\r1_blc_bayer4_u10.sv'),
            (Join-Path $rtlRoot 'video\r1_rgb10_color_pipeline.sv'),
            (Join-Path $simRoot 'tb_c1_r1_isp_primitives.sv')
        )
    Invoke-LoggedStep -Name 'xelab' -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @('tb_c1_r1_isp_primitives', '-s', 'tb_c1_r1_isp_primitives_sim')
    Invoke-LoggedStep -Name 'xsim' -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_r1_isp_primitives_sim', '-runall')

    $manifest = Get-Content -Raw -LiteralPath `
        (Join-Path $runRoot 'c1_r1_isp_primitive_vectors.json') | ConvertFrom-Json
    $expectedPass = "C1_R1_ISP_PRIMITIVES_PASS blc=$($manifest.blc_vectors) " +
                    "color=$($manifest.color_vectors) gamma=$($manifest.gamma_entries)"
    $simOutput = Get-Content -Raw -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log')
    $simError = Get-Content -Raw -LiteralPath (Join-Path $runLogRoot 'xsim.stderr.log')
    if (-not $simOutput.Contains($expectedPass)) {
        throw "xsim output is missing exact PASS marker: $expectedPass"
    }
    if (($simOutput + "`n" + $simError) -match
        '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened') {
        throw 'xsim output contains a fatal/error diagnostic despite its process exit code'
    }
    if (-not [string]::IsNullOrWhiteSpace($simError)) {
        throw 'xsim wrote a diagnostic to stderr'
    }

    Write-Status -State 'complete' -Step 'done' -ExitCode 0 -Message $expectedPass
} catch {
    Write-Status -State 'failed' -Step 'exception' -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
}
