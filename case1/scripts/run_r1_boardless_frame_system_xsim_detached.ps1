param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$Preview,
    [switch]$PreviewCancel,
    [switch]$PreviewError,
    [switch]$PreviewLayout,
    [switch]$SuccessDrainCancel
)

# Launch the Vivado worker through WMI so xvlog/xelab/xsim are not attached to
# the Codex Windows Job.  A passing run requires zero tool exit codes, empty
# stderr, clean diagnostics, and exactly one boardless-system PASS marker.
$ErrorActionPreference = 'Stop'
if($PreviewCancel -and !$Preview){throw 'PreviewCancel requires Preview'}
if($PreviewError -and (!$Preview -or $PreviewCancel)){throw 'PreviewError requires Preview and excludes PreviewCancel'}
if($PreviewLayout -and (!$Preview -or $PreviewCancel -or $PreviewError)){throw 'PreviewLayout requires Preview and excludes other modes'}
if($SuccessDrainCancel -and ($PreviewCancel -or $PreviewError -or $PreviewLayout)){throw 'SuccessDrainCancel excludes other fault scenarios'}
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
    $statusPath = Join-Path $logRoot `
        "r1_boardless_frame_system_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    if($Preview){$commandLine += ' -Preview'}
    if($PreviewCancel){$commandLine += ' -PreviewCancel'}
    if($PreviewError){$commandLine += ' -PreviewError'}
    if($PreviewLayout){$commandLine += ' -PreviewLayout'}
    if($SuccessDrainCancel){$commandLine += ' -SuccessDrainCancel'}
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

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot = Join-Path $simRoot "r1_boardless_frame_system_xsim_run_$RunId"
$runLogRoot = Join-Path $logRoot "r1_boardless_frame_system_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_r1_boardless_frame_system_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep = 'setup'
$script:stepSeconds = [ordered]@{}
$script:totalWatch = [Diagnostics.Stopwatch]::StartNew()

New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Set-StatusContent {
    param([string]$Path, [string]$Value)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $Value | Set-Content -LiteralPath $Path -Encoding UTF8 `
                -ErrorAction Stop
            return
        } catch [IO.IOException] {
            if ($attempt -eq 19) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

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
        elapsed_seconds = [math]::Round(
            $script:totalWatch.Elapsed.TotalSeconds, 3)
        step_seconds = $script:stepSeconds
        updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot
        run_directory = $runRoot
    } | ConvertTo-Json -Depth 4
    Set-StatusContent -Path $statusPath -Value $status
    Set-StatusContent -Path $latestStatusPath -Value $status
}

function Invoke-VivadoStep {
    param(
        [string]$Name,
        [string]$Tool,
        [string[]]$Arguments,
        [string]$ExpectedPass = ''
    )
    $script:currentStep = $Name
    Write-Status -State 'running' -Step $Name -ExitCode 0 `
        -Message "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $watch.Stop()
    $script:stepSeconds[$Name] = [math]::Round(
        $watch.Elapsed.TotalSeconds, 3)
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)"
    }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    $diagnostics = $stdout + "`n" + $stderr
    if ($diagnostics -match `
        '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened|\$\s*fatal') {
        throw "$Name reported Fatal/Error/FAIL"
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "$Name wrote diagnostics to stderr"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPass)) {
        $passCount = [regex]::Matches(
            $stdout, [regex]::Escape($ExpectedPass)).Count
        if ($passCount -ne 1) {
            throw "$Name emitted $passCount copies of required marker $ExpectedPass"
        }
    }
    Write-Status -State 'running' -Step $Name -ExitCode 0 `
        -Message "$Name complete"
}

try {
    Write-Status -State 'running' -Step 'setup' -ExitCode 0 `
        -Message 'detached R1 boardless frame-system worker started'

    Invoke-VivadoStep -Name 'xvlog' `
        -Tool (Join-Path $vivadoBin 'xvlog.bat') -Arguments @(
            '-sv',
            (Join-Path $rtlRoot 'control\c1_descriptor_pkg.sv'),
            (Join-Path $rtlRoot 'control\c1_descriptor_decoder_pkg.sv'),
            (Join-Path $rtlRoot 'control\c1_layer_scheduler.sv'),
            (Join-Path $rtlRoot 'dma\c1_axi_descriptor_reader.sv'),
            (Join-Path $rtlRoot 'control\c1_descriptor_scheduler_subsystem.sv'),
            (Join-Path $rtlRoot 'control\c1_layer_command_decoder.sv'),
            (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
            (Join-Path $rtlRoot 'control\c1_r1_stage_config_bank.sv'),
            (Join-Path $rtlRoot 'control\c1_r1_config_loader_subsystem.sv'),
            (Join-Path $rtlRoot 'dma\c1_axi_frame_buffer_table_reader.sv'),
            (Join-Path $rtlRoot 'control\c1_frame_pair_resolver.sv'),
            (Join-Path $rtlRoot 'control\c1_frame_triple_layout_check.sv'),
            (Join-Path $rtlRoot 'control\c1_r1_job_controller.sv'),
            (Join-Path $rtlRoot 'dma\c1_axi2_serial_arbiter_128.sv'),
            (Join-Path $rtlRoot 'control\c1_r1_job_frontend.sv'),
            (Join-Path $rtlRoot 'control\c1_r1_config_dispatcher.sv'),
            (Join-Path $rtlRoot 'dma\c1_axi_xrgb_frame_reader.sv'),
            (Join-Path $rtlRoot 'dma\c1_axi_xrgb_frame_writer.sv'),
            (Join-Path $rtlRoot 'video\r1_resize_request_q16.sv'),
            (Join-Path $rtlRoot 'video\r1_bilinear_interp_rgb888.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_resize_system.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_resize_line_sampler.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_resize_pipeline.sv'),
            (Join-Path $rtlRoot 'cnn\c1_rgb_s8_center_codec.sv'),
            (Join-Path $rtlRoot 'cnn\c1_r1_compute_ingress.sv'),
            (Join-Path $rtlRoot 'cnn\c1_r1_compute_egress.sv'),
            (Join-Path $rtlRoot 'top\c1_r1_rgb_source_mux.sv'),
            (Join-Path $rtlRoot 'top\c1_r1_compute_shell.sv'),
            (Join-Path $rtlRoot 'control\c1_r1_runtime_join.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_preview_fork.sv'),
            (Join-Path $rtlRoot 'video\c1_r1_preview_dma.sv'),
            (Join-Path $rtlRoot 'top\c1_r1_preview_runtime.sv'),
            (Join-Path $rtlRoot 'top\c1_r1_boardless_frame_system.sv'),
            (Join-Path $simRoot 'tb_c1_r1_boardless_frame_system.sv')
        )
    $xelabArgs=@(
            'tb_c1_r1_boardless_frame_system',
            '-s', 'tb_c1_r1_boardless_frame_system_sim'
        )
    if($Preview){$xelabArgs+=@('-generic_top','"ENABLE_PREVIEW=1"')}
    if($PreviewCancel){$xelabArgs+=@('-generic_top','"PREVIEW_CANCEL_TEST=1"')}
    if($PreviewError){$xelabArgs+=@('-generic_top','"PREVIEW_ERROR_TEST=1"')}
    if($PreviewLayout){$xelabArgs+=@('-generic_top','"PREVIEW_LAYOUT_TEST=1"')}
    if($SuccessDrainCancel){$xelabArgs+=@('-generic_top','"SUCCESS_DRAIN_CANCEL=1"')}
    Invoke-VivadoStep -Name 'xelab' -Tool (Join-Path $vivadoBin 'xelab.bat') -Arguments $xelabArgs
    Invoke-VivadoStep -Name 'xsim' `
        -Tool (Join-Path $vivadoBin 'xsim.bat') -Arguments @(
            'tb_c1_r1_boardless_frame_system_sim', '-runall'
        ) -ExpectedPass 'C1_R1_BOARDLESS_FRAME_SYSTEM_PASS'
    if($Preview -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_BOARDLESS_PREVIEW_PASS ').Count -ne 1){
        throw 'missing unique preview coverage marker'
    }
    if($PreviewCancel -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_BOARDLESS_PREVIEW_CANCEL_PASS ').Count -ne 1){
        throw 'missing unique preview cancellation marker'
    }
    if($PreviewError -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_BOARDLESS_PREVIEW_ERROR_PASS ').Count -ne 1){
        throw 'missing unique preview error marker'
    }
    if($PreviewLayout -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_BOARDLESS_PREVIEW_LAYOUT_PASS ').Count -ne 1){
        throw 'missing unique preview layout marker'
    }
    if($SuccessDrainCancel -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_BOARDLESS_SUCCESS_DRAIN_CANCEL_PASS ').Count -ne 1){
        throw 'missing unique success-drain cancellation/restart marker'
    }

    $script:totalWatch.Stop()
    Write-Status -State 'complete' -Step 'done' -ExitCode 0 `
        -Message 'C1_R1_BOARDLESS_FRAME_SYSTEM_PASS'
} catch {
    $script:totalWatch.Stop()
    Write-Status -State 'failed' -Step $script:currentStep -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
} finally {
    if(Test-Path -LiteralPath $runRoot){
        $resolvedRun=(Resolve-Path -LiteralPath $runRoot).Path
        $expectedRun=[IO.Path]::GetFullPath((Join-Path $simRoot "r1_boardless_frame_system_xsim_run_$RunId"))
        if($resolvedRun -ne $expectedRun -or -not $resolvedRun.StartsWith($simRoot+'\',[StringComparison]::OrdinalIgnoreCase)){
            throw 'refusing cleanup outside exact simulation directory'
        }
        Remove-Item -LiteralPath $resolvedRun -Recurse -Force
    }
}
