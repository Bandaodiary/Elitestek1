param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$CompileOnly,
    [Alias('RealParameterClient')]
    [switch]$RealParameter
)

# WMI-detached Vivado/xsim runner for the boardless 7-client fabric preflight.
# Keeping the worker outside the caller's Windows Job lets xsim finish if the
# interactive Codex shell is interrupted.
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
    if ($RealParameter) { $extra += ' -RealParameter' }
    $cmd = '"' + $ps + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Worker -RunId ' + $RunId + $extra
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmd; CurrentDirectory=$caseRoot}
    if ($created.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($created.ReturnValue)" }
    [ordered]@{run_id=$RunId; worker_pid=[int]$created.ProcessId; status_path=(Join-Path $logRoot "native_boardless_fabric_runs\$RunId\status.json")} | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
$runRoot = Join-Path $simRoot "native_boardless_fabric_run_$RunId"
$runLogRoot = Join-Path $logRoot "native_boardless_fabric_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'native_boardless_fabric_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:step = 'setup'; $script:watch = [Diagnostics.Stopwatch]::StartNew(); $script:times = [ordered]@{}
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status([string]$State,[string]$Step,[int]$ExitCode,[string]$Message) {
    $value = [ordered]@{run_id=$RunId; frame='640x480'; clients=7; state=$State; step=$Step; exit_code=$ExitCode; message=$Message; process_id=$PID; elapsed_seconds=[math]::Round($script:watch.Elapsed.TotalSeconds,3); step_seconds=$script:times; updated=(Get-Date).ToString('o'); log_directory=$runLogRoot; run_directory=$runRoot} | ConvertTo-Json -Depth 4
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}
function Invoke-VivadoStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$Expected='')
    $script:step=$Name; Write-Status running $Name 0 "starting $Name"
    $out=Join-Path $runLogRoot "$Name.stdout.log"; $err=Join-Path $runLogRoot "$Name.stderr.log"; $sw=[Diagnostics.Stopwatch]::StartNew()
    # Callers pass a fully-qualified launcher path.  Execute the .bat wrapper
    # directly, matching the proven native boardless runner and avoiding
    # fragile cmd.exe quote nesting.
    $p=Start-Process -FilePath $Tool -ArgumentList $Arguments -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $sw.Stop(); $script:times[$Name]=[math]::Round($sw.Elapsed.TotalSeconds,3)
    if($p.ExitCode -ne 0){throw "$Name failed with exit code $($p.ExitCode)"}
    $stdout=Get-Content -Raw -LiteralPath $out; $stderr=Get-Content -Raw -LiteralPath $err
    if(-not [string]::IsNullOrWhiteSpace($stderr)){throw "$Name wrote diagnostics to stderr"}
    if(($stdout+"`n"+$stderr)-match '(?im)\b(ERROR|FATAL|FAIL)\b|cannot be opened|\$\s*fatal'){throw "$Name reported an error"}
    if($Expected -and [regex]::Matches($stdout,[regex]::Escape($Expected)).Count -ne 1){throw "$Name emitted marker mismatch"}
    Write-Status running $Name 0 "$Name complete"
}

try {
    $mode = if ($RealParameter) { 'real parameter client + five synthetic peers' } else { 'six synthetic peers' }
    Write-Status running setup 0 "detached native boardless fabric worker started ($mode)"
    $sources=@(
        (Join-Path $rtlRoot 'control\c1_descriptor_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_decoder_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_layer_scheduler.sv'),
        (Join-Path $rtlRoot 'dma\c1_axi_descriptor_reader.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_scheduler_subsystem.sv'),
        (Join-Path $rtlRoot 'control\c1_layer_command_decoder.sv'),
        (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
        (Join-Path $rtlRoot 'cnn\c1_r1_parameter_bank.sv'),
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
        (Join-Path $rtlRoot 'dma\c1_axi_parameter_loader.sv'),
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
        (Join-Path $rtlRoot 'dma\c1_axi_n_serial_arbiter_128.sv'),
        (Join-Path $simRoot 'tb_c1_r1_native_boardless_fabric.sv'))
    $defines = if ($RealParameter) { @('-d','NATIVE_FABRIC_REAL_PARAMETER') } else { @() }
    Invoke-VivadoStep xvlog (Join-Path $vivadoBin 'xvlog.bat') (@('-sv')+$defines+$sources)
    Invoke-VivadoStep xelab (Join-Path $vivadoBin 'xelab.bat') @('tb_c1_r1_native_boardless_fabric','-s','tb_c1_r1_native_boardless_fabric_sim')
    if($CompileOnly){$elabMarker = if ($RealParameter) { 'C1_R1_NATIVE_BOARDLESS_FABRIC_PARAM_ELAB_PASS frame=640x480 clients=7 real_param=1' } else { 'C1_R1_NATIVE_BOARDLESS_FABRIC_ELAB_PASS frame=640x480 clients=7' }; $script:watch.Stop();Write-Status complete elaboration 0 $elabMarker;exit 0}
    $expected = if ($RealParameter) { 'C1_R1_NATIVE_BOARDLESS_FABRIC_PARAM_PASS' } else { 'C1_R1_NATIVE_BOARDLESS_FABRIC_PASS' }
    Invoke-VivadoStep xsim (Join-Path $vivadoBin 'xsim.bat') @('tb_c1_r1_native_boardless_fabric_sim','-runall') $expected
    $doneMarker = if ($RealParameter) { 'C1_R1_NATIVE_BOARDLESS_FABRIC_PARAM_PASS frame=640x480 clients=7 real_param=1' } else { 'C1_R1_NATIVE_BOARDLESS_FABRIC_PASS frame=640x480 clients=7' }
    $script:watch.Stop();Write-Status complete done 0 $doneMarker
} catch { $script:watch.Stop(); Write-Status failed $script:step 1 $_.Exception.Message; exit 1 }
