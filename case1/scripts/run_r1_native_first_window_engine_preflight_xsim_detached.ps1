param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$CompileOnly,
    [switch]$PipelinedAddress,
    [switch]$PipelinedPixelIndex,
    [int]$WindowPixels = 1
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$vectorRoot = Join-Path $caseRoot 'vectors\microstyle_artifact'
$logRoot = Join-Path $caseRoot 'logs'

if (@(1,2,4,8,16) -notcontains $WindowPixels) {
    throw "WindowPixels must be one of {1,2,4,8,16}, got $WindowPixels"
}
$windowDefine = "C1_NATIVE_WINDOW_PIXELS_$WindowPixels"

# The foreground only creates a worker through WMI (or the native breakaway
# helper), so Vivado/xsim is not attached to the current Windows Job.
if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "native_first_window_engine_preflight_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $compileArg = if ($CompileOnly) { ' -CompileOnly' } else { '' }
    $addressArg = if ($PipelinedAddress) { ' -PipelinedAddress' } else { '' }
    $pixelArg = if ($PipelinedPixelIndex) { ' -PipelinedPixelIndex' } else { '' }
    $windowArg = ' -WindowPixels ' + $WindowPixels
    $quote = [char]34
    $commandLine = $quote + $powerShell + $quote + ' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $quote + $PSCommandPath + $quote + ' -Worker -RunId ' + $RunId + $compileArg + $addressArg + $pixelArg + $windowArg
    $workerPid = $null
    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
        if ($result.ReturnValue -eq 0) { $workerPid = [int]$result.ProcessId }
    } catch { $result = $null }
    if ($null -eq $workerPid) {
        $launcher = Join-Path $caseRoot 'scripts\start_detached_process.ps1'
        $launcherOutput = & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher -CommandLine $commandLine -CurrentDirectory $caseRoot 2>&1
        if ($LASTEXITCODE -ne 0) { throw "detached process fallback failed: $($launcherOutput -join ' ')" }
        try { $workerPid = [int](($launcherOutput | Select-Object -Last 1).ToString().Trim()) }
        catch { throw "detached process fallback returned invalid pid: $($launcherOutput -join ' ')" }
    }
    [ordered]@{ run_id=$RunId; worker_pid=$workerPid; status_path=$statusPath } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $simRoot "xsim_run_native_first_window_engine_$RunId"
$runLogRoot = Join-Path $logRoot "native_first_window_engine_preflight_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'native_first_window_engine_preflight_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep = 'setup'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status {
    param([string]$State,[string]$Step,[int]$ExitCode,[string]$Message)
    $value = [ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$ExitCode;message=$Message;process_id=$PID;elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);updated=(Get-Date).ToString('o');log_directory=$runLogRoot;run_directory=$runRoot} | ConvertTo-Json
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Save-CompactLog {
    param([string]$Source,[string]$Destination,[string]$Marker='')
    $lines = @()
    if (Test-Path -LiteralPath $Source) {
        if ($Marker) {
            $lines += @(Select-String -LiteralPath $Source -Pattern ([regex]::Escape($Marker)) -AllMatches -ErrorAction SilentlyContinue | ForEach-Object { $_.Line })
        }
        $lines += @(Get-Content -LiteralPath $Source -Tail 80 -ErrorAction SilentlyContinue)
    }
    if ($lines.Count -eq 0) { $lines = @('(empty)') }
    $lines | Select-Object -Unique | Set-Content -LiteralPath $Destination -Encoding UTF8
}

function Invoke-XsimStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$ExpectedPass='')
    $script:currentStep = $Name
    Write-Status running $Name 0 "starting $Name"
    $stdoutPath = Join-Path $runRoot "$Name.stdout.raw.log"
    $stderrPath = Join-Path $runRoot "$Name.stderr.raw.log"
    $compactStdout = Join-Path $runLogRoot "$Name.stdout.log"
    $compactStderr = Join-Path $runLogRoot "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    try {
        if ($process.ExitCode -ne 0) { throw "$Name exit $($process.ExitCode)" }
        if (Select-String -LiteralPath $stderrPath -Pattern '\S' -Quiet -ErrorAction SilentlyContinue) { throw "$Name wrote stderr" }
        $badPattern='(?i)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened|\$\s*fatal'
        if (Select-String -LiteralPath $stdoutPath -Pattern $badPattern -Quiet -ErrorAction SilentlyContinue) { throw "$Name reported Fatal/Error/FAIL" }
        if ($ExpectedPass) {
            $hits = @(Select-String -LiteralPath $stdoutPath -Pattern ([regex]::Escape($ExpectedPass)) -AllMatches -ErrorAction SilentlyContinue)
            $count = 0
            foreach ($hit in $hits) { if ($hit.Matches) { $count += $hit.Matches.Count } else { $count++ } }
            if ($count -ne 1) { throw "$Name marker mismatch count=$count" }
        }
    } finally {
        Save-CompactLog $stdoutPath $compactStdout $ExpectedPass
        Save-CompactLog $stderrPath $compactStderr
    }
}

try {
    Write-Status running setup 0 'detached native first-window real-engine preflight started'
    Copy-Item -LiteralPath (Join-Path $vectorRoot 'descriptors.mem') -Destination (Join-Path $runRoot 'descriptors.mem')
    Copy-Item -LiteralPath (Join-Path $vectorRoot 'parameter_arena.mem') -Destination (Join-Path $runRoot 'parameter_arena.mem')
    $sources = @(
        (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_decoder_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_layer_command_decoder.sv'),
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum.sv'),
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_pipelined.sv'),
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_treepipe.sv'),
        (Join-Path $rtlRoot 'cnn\c1_requant_bank8.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_core.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dwconv3x3_c8_requant_core.sv'),
        (Join-Path $rtlRoot 'cnn\c1_r1_c8_parameter_scheduler.sv'),
        (Join-Path $rtlRoot 'cnn\c1_r1_parameter_bank.sv'),
        (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_engine.sv'),
        (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_cnn_top.sv'),
        (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_tensor_adapter.sv'),
        (Join-Path $rtlRoot 'cnn\c1_pixel_result_writer.sv'),
        (Join-Path $simRoot 'tb_c1_r1_native_first_window_engine_preflight.sv')
    )
    # Use a value-free macro here.  Vivado's Windows batch wrapper can split
    # a `NAME=VALUE` define at the equals sign when passed through
    # Start-Process; the named defines avoid that ambiguity while the
    # TB still accepts a numeric macro for direct Icarus use.
    $xvlogArgs = @('-sv','-d','C1_USE_PARAMETER_BANK', '-d', $windowDefine)
    if ($PipelinedAddress) { $xvlogArgs += @('-d','C1_PIPELINED_TENSOR_ADDRESS') }
    if ($PipelinedPixelIndex) { $xvlogArgs += @('-d','C1_PIPELINED_TENSOR_PIXEL_INDEX') }
    $xvlogArgs += $sources
    Invoke-XsimStep xvlog (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    Invoke-XsimStep xelab (Join-Path $vivadoBin 'xelab.bat') @('tb_c1_r1_native_first_window_engine_preflight','-s','native_first_window_engine_preflight_sim')
    $compileMarker = 'C1_R1_NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT_ELAB_PASS frame=640x480 stages=22 bank=1'
    if ($CompileOnly) {
        # SwitchParameter cannot be cast directly to Int32 on all Windows
        # PowerShell versions; normalize through an explicit boolean first.
        $pipelineFlag = if ($PipelinedAddress.IsPresent) { 1 } else { 0 }
        $pixelPipelineFlag = if ($PipelinedPixelIndex.IsPresent) { 1 } else { 0 }
        "$compileMarker pipeline=$pipelineFlag pixel_pipeline=$pixelPipelineFlag window_pixels=$WindowPixels" | Set-Content -LiteralPath (Join-Path $runLogRoot 'compile_only.stdout.log') -Encoding UTF8
        '(empty)' | Set-Content -LiteralPath (Join-Path $runLogRoot 'compile_only.stderr.log') -Encoding UTF8
        $watch.Stop(); Write-Status complete elab 0 $compileMarker
        return
    }
    Invoke-XsimStep xsim (Join-Path $vivadoBin 'xsim.bat') @('native_first_window_engine_preflight_sim','-runall') 'C1_R1_NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT_PASS'
    $watch.Stop(); Write-Status complete done 0 'C1_R1_NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT_PASS'
} catch {
    $watch.Stop(); Write-Status failed $script:currentStep 1 $_.Exception.Message; exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) { Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
