param(
    [switch]$Worker,
    [string]$RunId = ''
)

# The launcher creates its worker through WMI, so Vivado/xsim are not members
# of the calling Codex shell's Windows Job object.  The same file contains the
# worker branch to keep this full-frame regression self-contained.

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    $RunId = [guid]::NewGuid().ToString('N')
    $statusPath = Join-Path $logRoot "xsim_fullframe_runs\$RunId\status.json"
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

$runRoot = Join-Path $simRoot "xsim_fullframe_run_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_fullframe_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_fullframe_status.json'
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

    if ($ExpectedPass) {
        $stdout = Get-Content -Raw -LiteralPath $stdoutPath
        $stderr = Get-Content -Raw -LiteralPath $stderrPath
        $diagnostics = $stdout + "`n" + $stderr
        if ($diagnostics -match '(?im)(^|\s)(Fatal|Error):|cannot be opened|\$\s*fatal') {
            throw "$Name reported Fatal/Error; inspect $stdoutPath and $stderrPath"
        }
        if ($diagnostics -notmatch [regex]::Escape($ExpectedPass)) {
            throw "$Name did not emit required marker $ExpectedPass"
        }
    }
    Write-Status -State 'running' -Step $Name -ExitCode 0 -Message "$Name complete"
}

try {
    $inputVector = Join-Path $simRoot 'vectors_fullframe\cnn_input_rgb24.hex'
    $expectedVector = Join-Path $simRoot 'vectors_fullframe\cnn_expected_rgb24.hex'
    $manifest = Join-Path $simRoot 'vectors_fullframe\manifest.json'
    foreach ($required in @($inputVector, $expectedVector, $manifest)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "required full-frame vector is missing: $required"
        }
    }

    Write-Status -State 'running' -Step 'setup' -ExitCode 0 `
        -Message 'detached full-frame worker started'
    $sources = @(
        '-sv',
        (Join-Path $rtlRoot 'common\c1_fixed_pkg.sv'),
        (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
        (Join-Path $rtlRoot 'common\c1_window3x3.sv'),
        (Join-Path $rtlRoot 'cnn\c1_conv3x3_rgb3.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dwconv3x3_rgb3.sv'),
        (Join-Path $rtlRoot 'cnn\c1_pwconv1x1_rgb3.sv'),
        (Join-Path $rtlRoot 'cnn\c1_style_cnn3.sv'),
        (Join-Path $simRoot 'tb_c1_style_cnn3_fullframe.sv')
    )
    Invoke-VivadoStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments $sources
    Invoke-VivadoStep -Name 'xelab_fullframe' -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @('tb_c1_style_cnn3_fullframe', '-s', 'tb_c1_style_cnn3_fullframe_sim')
    Invoke-VivadoStep -Name 'xsim_fullframe' -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_style_cnn3_fullframe_sim', '-runall') `
        -ExpectedPass 'C1_STYLE_CNN3_FULLFRAME_PASS'
    $script:totalWatch.Stop()
    Write-Status -State 'complete' -Step 'done' -ExitCode 0 `
        -Message 'R0 CNN 640x480 full-frame xsim regression complete'
} catch {
    $script:totalWatch.Stop()
    Write-Status -State 'failed' -Step $script:currentStep -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
}
