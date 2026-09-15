param(
    [switch]$Worker,
    [string]$RunId,
    [switch]$RegisterAbortReset
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptPath = $PSCommandPath

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $caseRoot `
        "logs\r1_resize_pipeline_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
                   "-ExecutionPolicy Bypass -WindowStyle Hidden " +
                   "-File `"$scriptPath`" -Worker -RunId $RunId" +
                   $(if ($RegisterAbortReset) { ' -RegisterAbortReset' } else { '' })
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{
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
$runRoot = Join-Path $simRoot "r1_resize_pipeline_xsim_run_$RunId"
$runLogRoot = Join-Path $logRoot "r1_resize_pipeline_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_r1_resize_pipeline_status.json'
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
    Write-Status -State 'running' -Step $Name -ExitCode 0 `
        -Message "starting $Name"
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
        -Message 'detached complete R1 resize pipeline worker started'

    Invoke-LoggedStep -Name 'vector_gen' -Tool $pythonExe -Arguments @(
        (Join-Path $goldenRoot 'generate_r1_resize_line_sampler_vectors.py'),
        '--output-dir', $runRoot,
        '--seed', '20260824'
    )
    $xvlogArguments = @(
            '-sv',
            (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
            (Join-Path $rtlRoot 'video\r1_resize_request_q16.sv'),
            (Join-Path $rtlRoot 'video\r1_bilinear_interp_rgb888.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_resize_system.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_resize_line_sampler.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_resize_pipeline.sv'),
            (Join-Path $simRoot 'tb_c1_r1_resize_pipeline.sv'))
    if ($RegisterAbortReset) {
        $xvlogArguments = @('-d', 'C1_REGISTER_ABORT_RESET') + $xvlogArguments
    }
    Invoke-LoggedStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments $xvlogArguments
    Invoke-LoggedStep -Name 'xelab' -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @(
            'tb_c1_r1_resize_pipeline',
            '-s', 'tb_c1_r1_resize_pipeline_sim'
        )
    Invoke-LoggedStep -Name 'xsim' -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_r1_resize_pipeline_sim', '-runall')

    $manifest = Get-Content -Raw -LiteralPath `
        (Join-Path $runRoot 'r1_resize_line_sampler_manifest.json') |
        ConvertFrom-Json
    $expectedPass = "C1_R1_RESIZE_PIPELINE_PASS " +
                    "configs=$($manifest.configs) " +
                    "outputs=$($manifest.outputs) " +
                    'cfg_errors=3 aborts=4'
    $simOutput = Get-Content -Raw -LiteralPath `
        (Join-Path $runLogRoot 'xsim.stdout.log')
    if ([regex]::Matches(
            $simOutput, [regex]::Escape($expectedPass)).Count -ne 1) {
        throw "xsim output does not contain exactly one PASS marker: $expectedPass"
    }

    foreach ($name in @('vector_gen', 'xvlog', 'xelab', 'xsim')) {
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

    Write-Status -State 'complete' -Step 'done' -ExitCode 0 `
        -Message $expectedPass
} catch {
    Write-Status -State 'failed' -Step 'exception' -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
}
