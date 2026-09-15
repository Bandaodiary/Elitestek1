param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$CompileOnly
)

# Detached Vivado/xsim runner for the native boardless job preflight.  WMI
# creates the worker outside the desktop job so a Codex shell interruption does
# not kill an in-flight xsim process.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $extra = if ($CompileOnly) { ' -CompileOnly' } else { '' }
    $cmd = '"' + $ps + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Worker -RunId ' + $RunId + $extra
    # WMI is preferred because it creates the worker outside the caller's
    # Windows Job.  Managed desktops can deny Win32_Process.Create, so use
    # the native CREATE_BREAKAWAY_FROM_JOB helper as a safe fallback.
    $workerPid = $null
    try {
        $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{CommandLine=$cmd; CurrentDirectory=$caseRoot}
        if ($created.ReturnValue -eq 0) { $workerPid = [int]$created.ProcessId }
    } catch { $created = $null }
    if ($null -eq $workerPid) {
        $launcher = Join-Path $PSScriptRoot 'start_detached_process.ps1'
        $launcherOutput = & $ps -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $launcher -CommandLine $cmd -CurrentDirectory $caseRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "detached process fallback failed: $($launcherOutput -join ' ')"
        }
        try { $workerPid = [int](($launcherOutput | Select-Object -Last 1).ToString().Trim()) }
        catch { throw "detached process fallback returned invalid pid: $($launcherOutput -join ' ')" }
    }
    [ordered]@{run_id=$RunId; worker_pid=$workerPid; status_path=(Join-Path $logRoot "native_boardless_job_runs\$RunId\status.json")} | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
$runRoot = Join-Path $simRoot "native_boardless_job_run_$RunId"
$runLogRoot = Join-Path $logRoot "native_boardless_job_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'native_boardless_job_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:step = 'setup'
$script:times = [ordered]@{}
$script:watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status([string]$State,[string]$Step,[int]$ExitCode,[string]$Message) {
    $value = [ordered]@{run_id=$RunId; frame='640x480'; state=$State; step=$Step; exit_code=$ExitCode; message=$Message; process_id=$PID; elapsed_seconds=[math]::Round($script:watch.Elapsed.TotalSeconds,3); step_seconds=$script:times; updated=(Get-Date).ToString('o'); log_directory=$runLogRoot; run_directory=$runRoot} | ConvertTo-Json -Depth 4
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-VivadoStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$Expected='')
    $script:step = $Name
    Write-Status running $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $Tool -ArgumentList $Arguments -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $sw.Stop(); $script:times[$Name] = [math]::Round($sw.Elapsed.TotalSeconds,3)
    if ($p.ExitCode -ne 0) { throw "$Name failed with exit code $($p.ExitCode)" }
    $stdout = Get-Content -Raw -LiteralPath $out
    $stderr = Get-Content -Raw -LiteralPath $err
    if (($stdout + "`n" + $stderr) -match '(?im)\b(ERROR|FATAL|FAIL)\b|cannot be opened|\$\s*fatal') { throw "$Name reported an error; inspect $out" }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw "$Name wrote diagnostics to stderr" }
    if ($Expected) {
        $count = [regex]::Matches($stdout,[regex]::Escape($Expected)).Count
        if ($count -ne 1) { throw "$Name emitted marker count=$count" }
    }
    Write-Status running $Name 0 "$Name complete"
}

try {
    Write-Status running setup 0 'detached native boardless job worker started'
    $sources = @(
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
        (Join-Path $rtlRoot 'top\c1_r1_boardless_frame_system.sv'),
        (Join-Path $simRoot 'tb_c1_r1_native_boardless_job.sv')
    )
    Invoke-VivadoStep xvlog (Join-Path $vivadoBin 'xvlog.bat') (@('-sv') + $sources)
    Invoke-VivadoStep xelab (Join-Path $vivadoBin 'xelab.bat') @('tb_c1_r1_native_boardless_job','-s','tb_c1_r1_native_boardless_job_sim')
    if ($CompileOnly) {
        $script:watch.Stop(); Write-Status complete elaboration 0 'C1_R1_NATIVE_BOARDLESS_JOB_ELAB_PASS frame=640x480'; exit 0
    }
    Invoke-VivadoStep xsim (Join-Path $vivadoBin 'xsim.bat') @('tb_c1_r1_native_boardless_job_sim','-runall') 'C1_R1_NATIVE_BOARDLESS_JOB_PASS'
    $script:watch.Stop(); Write-Status complete done 0 'C1_R1_NATIVE_BOARDLESS_JOB_PASS frame=640x480'
} catch {
    $script:watch.Stop(); Write-Status failed $script:step 1 $_.Exception.Message; exit 1
} finally {
    # Keep only compact status/step logs; Vivado's generated run tree is
    # disposable and can otherwise grow substantially on native elaboration.
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
