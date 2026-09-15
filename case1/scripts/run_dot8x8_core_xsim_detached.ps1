param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$PipelinedDotTree,
    [switch]$PipelinedDotTreeFull
)

# WMI launches a hidden worker outside the calling Codex Windows Job.  Each
# Vivado step must exit zero and leave stderr empty.  Simulation success also
# requires exactly one dedicated PASS marker and rejects fatal/error/fail text.

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    $RunId = [guid]::NewGuid().ToString('N')
    $statusPath = Join-Path $logRoot "dot8x8_core_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    if ($PipelinedDotTree) { $commandLine += ' -PipelinedDotTree' }
    if ($PipelinedDotTreeFull) { $commandLine += ' -PipelinedDotTreeFull' }
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

$runRoot = Join-Path $simRoot "xsim_dot8x8_core_run_$RunId"
$runLogRoot = Join-Path $logRoot "dot8x8_core_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'dot8x8_core_status.json'
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

function Invoke-VivadoStep {
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
        -Message 'detached 8x8 INT8 compute-core worker started'
    $xvlogArguments = @('-sv')
    if ($PipelinedDotTree) { $xvlogArguments += @('-d','C1_PIPELINED_DOT_TREE') }
    if ($PipelinedDotTreeFull) { $xvlogArguments += @('-d','C1_PIPELINED_DOT_TREE_FULL') }
    $xvlogArguments += @(
            (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum.sv'),
            (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_pipelined.sv'),
            (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_treepipe.sv'),
            (Join-Path $rtlRoot 'cnn\c1_requant_bank8.sv'),
            (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_core.sv'),
            (Join-Path $simRoot 'tb_c1_dot8x8_requant_core.sv')
        )
    Invoke-VivadoStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments $xvlogArguments
    Invoke-VivadoStep -Name 'xelab_dot8x8_core' -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @('tb_c1_dot8x8_requant_core', '-s', 'tb_c1_dot8x8_requant_core_sim')
    Invoke-VivadoStep -Name 'xsim_dot8x8_core' -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_dot8x8_requant_core_sim', '-runall') `
        -ExpectedPass 'C1_DOT8X8_REQUANT_CORE_PASS'
    $script:totalWatch.Stop()
    Write-Status -State 'complete' -Step 'done' -ExitCode 0 `
        -Message '8x8 INT8 compute-core xsim regression complete'
} catch {
    $script:totalWatch.Stop()
    Write-Status -State 'failed' -Step $script:currentStep -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
}
