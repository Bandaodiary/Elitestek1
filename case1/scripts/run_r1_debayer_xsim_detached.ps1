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

    $statusPath = Join-Path $caseRoot "logs\r1_debayer_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
                   "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" " +
                   "-Worker -RunId $RunId"

    # WMI creates the worker outside the caller's Windows Job object, so the
    # Vivado/xsim process tree survives interruption of the Codex shell.
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
$runRoot = Join-Path $simRoot "r1_debayer_xsim_run_$RunId"
$runLogRoot = Join-Path $logRoot "r1_debayer_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_r1_debayer_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$pythonExe = 'D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'

if (-not (Test-Path -LiteralPath $pythonExe)) {
    throw "SWPC_ENV Python is missing: $pythonExe"
}
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
        -Message 'detached R1 Debayer verification worker started'

    Invoke-LoggedStep -Name 'vector_gen' -Tool $pythonExe -Arguments @(
        (Join-Path $goldenRoot 'generate_r1_debayer_vectors.py'),
        '--output-dir', $runRoot,
        '--seed', '20260824'
    )
    $vectorOutput = Get-Content -Raw -LiteralPath `
        (Join-Path $runLogRoot 'vector_gen.stdout.log')
    if (-not $vectorOutput.Contains('R1_DEBAYER_VECTORS_PASS')) {
        throw 'Python vector generator did not emit its PASS marker'
    }

    Invoke-LoggedStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments @(
            '-sv',
            (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
            (Join-Path $rtlRoot 'common\c1_window3x3.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_debayer_bilinear.sv'),
            (Join-Path $simRoot 'tb_c1_r1_debayer_bilinear.sv')
        )
    Invoke-LoggedStep -Name 'xelab' -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @('tb_c1_r1_debayer_bilinear', '-s', 'tb_c1_r1_debayer_sim')
    Invoke-LoggedStep -Name 'xsim' -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_r1_debayer_sim', '-runall')

    $manifest = Get-Content -Raw -LiteralPath `
        (Join-Path $runRoot 'r1_debayer_manifest.json') | ConvertFrom-Json
    $expectedPass = "C1_R1_DEBAYER_PASS cases=$($manifest.cases) " +
                    "input=$($manifest.input_pixels) output=$($manifest.output_pixels)"
    $simOutput = Get-Content -Raw -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log')
    $simError = Get-Content -Raw -LiteralPath (Join-Path $runLogRoot 'xsim.stderr.log')
    if (-not $simOutput.Contains($expectedPass)) {
        throw "xsim output is missing exact PASS marker: $expectedPass"
    }
    if ($simOutput -match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened') {
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

