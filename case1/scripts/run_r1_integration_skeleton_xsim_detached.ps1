param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Win32_Process.Create keeps Vivado/xsim outside the calling Codex Windows Job.
# Completion requires zero tool exit codes, empty stderr for every step, no
# Fatal/Error/FAIL diagnostics, and exactly one smoke PASS marker.

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    $RunId = [guid]::NewGuid().ToString('N')
    $statusPath = Join-Path $logRoot "r1_integration_skeleton_runs\$RunId\status.json"
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

$runRoot = Join-Path $simRoot "xsim_r1_integration_skeleton_run_$RunId"
$runLogRoot = Join-Path $logRoot "r1_integration_skeleton_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'r1_integration_skeleton_status.json'
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
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    $diagnostics = $stdout + "`n" + $stderr
    if ($diagnostics -match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened|\$\s*fatal') {
        throw "$Name reported Fatal/Error/FAIL; inspect $stdoutPath and $stderrPath"
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "$Name wrote diagnostics to stderr"
    }
    if ($ExpectedPass) {
        $passCount = [regex]::Matches(
            $stdout, [regex]::Escape($ExpectedPass)).Count
        if ($passCount -ne 1) {
            throw "$Name emitted $passCount copies of required unique marker $ExpectedPass"
        }
    }
    Write-Status -State 'running' -Step $Name -ExitCode 0 -Message "$Name complete"
}

try {
    Write-Status -State 'running' -Step 'setup' -ExitCode 0 `
        -Message 'detached R1 integration-skeleton worker started'
    Invoke-VivadoStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments @(
            '-sv',
            (Join-Path $rtlRoot 'common\c1_reset_sync.sv'),
            (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
            (Join-Path $rtlRoot 'common\c1_window3x3.sv'),
            (Join-Path $rtlRoot 'common\c1_stream_fifo.sv'),
            (Join-Path $rtlRoot 'video\r1_blc_bayer4_u10.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_debayer_bilinear.sv'),
            (Join-Path $rtlRoot 'video\r1_rgb10_color_pipeline.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_isp_pipeline.sv'),
            (Join-Path $rtlRoot 'control\c1_apb_r1_mux.sv'),
            (Join-Path $rtlRoot 'control\c1_apb_csr.sv'),
            (Join-Path $rtlRoot 'control\c1_apb_isp_config.sv'),
            (Join-Path $rtlRoot 'control\c1_layer_scheduler.sv'),
            (Join-Path $rtlRoot 'dma\c1_axi_descriptor_reader.sv'),
            (Join-Path $rtlRoot 'control\c1_descriptor_scheduler_subsystem.sv'),
            (Join-Path $rtlRoot 'dma\c1_axi_xrgb_frame_reader.sv'),
            (Join-Path $rtlRoot 'dma\c1_axi_xrgb_frame_writer.sv'),
            (Join-Path $rtlRoot 'dma\c1_axi2_serial_arbiter_128.sv'),
            (Join-Path $rtlRoot 'top\c1_r1_integration_skeleton.sv'),
            (Join-Path $simRoot 'tb_c1_r1_integration_skeleton.sv')
        )
    Invoke-VivadoStep -Name 'xelab_r1_integration_skeleton' `
        -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @(
            'tb_c1_r1_integration_skeleton',
            '-s',
            'tb_c1_r1_integration_skeleton_sim'
        )
    Invoke-VivadoStep -Name 'xsim_r1_integration_skeleton' `
        -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_r1_integration_skeleton_sim', '-runall') `
        -ExpectedPass 'C1_R1_INTEGRATION_SKELETON_PASS'
    $script:totalWatch.Stop()
    Write-Status -State 'complete' -Step 'done' -ExitCode 0 `
        -Message 'R1 integration-skeleton xsim smoke complete'
} catch {
    $script:totalWatch.Stop()
    Write-Status -State 'failed' -Step $script:currentStep -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
}
