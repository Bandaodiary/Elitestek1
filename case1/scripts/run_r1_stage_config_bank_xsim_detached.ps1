param(
    [switch]$Worker,
    [string]$RunId = ''
)

# WMI creates a hidden worker outside the calling Codex Windows Job.  Every
# tool must exit zero, leave stderr empty, and contain no Fatal/Error/FAIL
# diagnostic.  The simulator must emit exactly one dedicated PASS marker.

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    $RunId = [guid]::NewGuid().ToString('N')
    $statusPath = Join-Path $logRoot "r1_stage_config_bank_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
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
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

$runRoot = Join-Path $simRoot "xsim_r1_stage_config_bank_run_$RunId"
$runLogRoot = Join-Path $logRoot "r1_stage_config_bank_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'r1_stage_config_bank_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep = 'setup'
$script:stepSeconds = [ordered]@{}
$script:totalWatch = [Diagnostics.Stopwatch]::StartNew()

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
        elapsed_seconds = [math]::Round($script:totalWatch.Elapsed.TotalSeconds, 3)
        step_seconds = $script:stepSeconds
        updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot
        run_directory = $runRoot
    } | ConvertTo-Json -Depth 4
    $status | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $status | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-StrictStep {
    param(
        [string]$Name,
        [string]$Tool,
        [string[]]$Arguments,
        [string]$ExpectedPass = ''
    )
    $script:currentStep = $Name
    Write-Status -State 'running' -Step $Name -ExitCode 0 -Message "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $watch.Stop()
    $script:stepSeconds[$Name] = [math]::Round($watch.Elapsed.TotalSeconds, 3)
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)"
    }

    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "$Name wrote unexpected stderr; inspect $stderrPath"
    }
    $diagnostics = $stdout + "`n" + $stderr
    if ($diagnostics -match '(?im)(^|\s)(Fatal|Error):|FAIL|cannot be opened|\$\s*fatal') {
        throw "$Name reported Fatal/Error/FAIL; inspect $stdoutPath and $stderrPath"
    }
    if ($ExpectedPass) {
        $passCount = [regex]::Matches(
            $diagnostics, [regex]::Escape($ExpectedPass)).Count
        if ($passCount -ne 1) {
            throw "$Name emitted $passCount copies of required marker $ExpectedPass; expected exactly one"
        }
    }
    Write-Status -State 'running' -Step $Name -ExitCode 0 -Message "$Name complete"
}

try {
    Write-Status -State 'running' -Step 'setup' -ExitCode 0 `
        -Message 'detached R1 stage-config-bank worker started'
    Invoke-StrictStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments @(
            '-sv',
            (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
            (Join-Path $rtlRoot 'control\c1_r1_stage_config_bank.sv'),
            (Join-Path $simRoot 'tb_c1_r1_stage_config_bank.sv')
        )
    Invoke-StrictStep -Name 'xelab_r1_stage_config_bank' `
        -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @('tb_c1_r1_stage_config_bank', '-s',
                     'tb_c1_r1_stage_config_bank_sim')
    Invoke-StrictStep -Name 'xsim_r1_stage_config_bank' `
        -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_r1_stage_config_bank_sim', '-runall') `
        -ExpectedPass 'C1_R1_STAGE_CONFIG_BANK_PASS'

    $script:totalWatch.Stop()
    Write-Status -State 'complete' -Step 'done' -ExitCode 0 `
        -Message 'R1 stage-config-bank xsim regression complete'
} catch {
    $script:totalWatch.Stop()
    Write-Status -State 'failed' -Step $script:currentStep -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
}
