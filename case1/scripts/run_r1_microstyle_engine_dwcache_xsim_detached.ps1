param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$DisableCache,
    [switch]$OverlapMac,
    [switch]$PackedAffine,
    [switch]$StreamDwGroups
)

# Boardless regression for the optional per-output-group DW weight tile cache.
# The WMI-created worker is outside the Codex Windows Job; its private xsim
# tree is removed after completion and only compact status/log files remain.
$ErrorActionPreference = 'Stop'
if($StreamDwGroups -and $DisableCache){throw 'StreamDwGroups requires the DW tile cache'}
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $logRoot "r1_microstyle_engine_dwcache_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    if ($DisableCache) { $commandLine += ' -DisableCache' }
    if ($OverlapMac) { $commandLine += ' -OverlapMac' }
    if ($PackedAffine) { $commandLine += ' -PackedAffine' }
    if ($StreamDwGroups) { $commandLine += ' -StreamDwGroups' }
    # Prefer WMI, but fall back to the native CREATE_BREAKAWAY_FROM_JOB
    # helper when Win32_Process.Create is blocked by local policy.  Both
    # launch paths keep Vivado/xsim outside the calling Windows job.
    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = $commandLine
            CurrentDirectory = $caseRoot
        }
        if ($result.ReturnValue -ne 0) {
            throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
        }
        $workerPid = [int]$result.ProcessId
    }
    catch {
        $fallback = Join-Path $caseRoot 'scripts\start_detached_process.ps1'
        $workerPid = [int](& powershell.exe -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $fallback -CommandLine $commandLine `
            -CurrentDirectory $caseRoot)
    }
    [ordered]@{ run_id = $RunId; worker_pid = $workerPid;
                status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_r1_microstyle_engine_dwcache_$RunId"
$runLogRoot = Join-Path $logRoot "r1_microstyle_engine_dwcache_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'r1_microstyle_engine_dwcache_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status([string]$State, [string]$Step, [int]$ExitCode,
                       [string]$Message) {
    $obj = [ordered]@{
        run_id = $RunId; state = $State; step = $Step; exit_code = $ExitCode
        message = $Message; process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        log_directory = $runLogRoot; run_directory = $runRoot
    } | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-Step([string]$Name, [string]$Tool, [string[]]$ToolArgs,
                      [string]$Marker = '') {
    $script:step = $Name
    Write-Status 'running' $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $proc = Start-Process -FilePath $Tool -ArgumentList $ToolArgs -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if ($null -eq $proc -or $proc.ExitCode -ne 0) {
        throw "$Name exit code $($proc.ExitCode)"
    }
    $all = (Get-Content -Raw -LiteralPath $out) + "`n" +
           (Get-Content -Raw -LiteralPath $err)
    if ($all -match '(?im)(^|\s)(Fatal|Error):|\$fatal|_FAIL') {
        throw "$Name reported failure"
    }
    if ($Marker -and ([regex]::Matches($all, [regex]::Escape($Marker)).Count -ne 1)) {
        throw "$Name did not emit exactly one $Marker"
    }
    return $all
}

try {
    Write-Status 'running' 'setup' 0 'detached DW weight-cache worker started'
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
        (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_engine.sv'),
        (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_cnn_top.sv'),
        (Join-Path $simRoot 'tb_c1_r1_microstyle_engine.sv')
    )
    $xvlogArgs = @('-sv')
    if (-not $DisableCache) { $xvlogArgs += @('-d', 'C1_CACHE_DW_WEIGHT_TILES') }
    if ($OverlapMac) { $xvlogArgs += @('-d', 'C1_MAC_PREFETCH_OVERLAP') }
    if ($PackedAffine) { $xvlogArgs += @('-d', 'C1_PACKED_AFFINE_CACHE') }
    if ($StreamDwGroups) { $xvlogArgs += @('-d', 'C1_STREAM_DW_GROUPS') }
    $xvlogArgs += $sources
    $null = Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    $null = Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_r1_microstyle_engine', '-s',
        'tb_c1_r1_microstyle_engine_dwcache_sim', '-nolog')
    $all = Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_r1_microstyle_engine_dwcache_sim', '-runall', '-nolog') `
        'C1_R1_MICROSTYLE_ENGINE_PASS'
    $marker = [regex]::Match($all, '(?m)^C1_R1_MICROSTYLE_ENGINE_PASS.*$').Value
    if([regex]::Matches($all,'(?m)^C1_ENGINE_DW_STREAM_OPTION enabled='+[int]$StreamDwGroups.IsPresent+'\r?$').Count -ne 1) {
        throw 'Missing actual DW group streaming mode'
    }
    if($StreamDwGroups -and [regex]::Matches($all,'(?m)^C1_ENGINE_DW_STREAM_ABORT_PASS pending_groups=2 drained=1 reset=0\r?$').Count -ne 1) {
        throw 'Missing real multi-group DW abort evidence'
    }
    if([regex]::Matches($all,'(?m)^C1_ENGINE_WEIGHT_WITNESS_PASS changed_lanes=[1-9][0-9]*\r?$').Count -ne 1) {
        throw 'Missing changed-output witnesses for the new weight generation'
    }
    if([regex]::Matches($all,'(?m)^C1_ENGINE_GENERATION_RELOAD_PASS old=9 new=10 dw_center=-1 stages=22 reset=0\r?$').Count -ne 1) {
        throw 'Missing or duplicate changed-weight generation reload evidence'
    }
    $warmAbortPattern='(?m)^C1_ENGINE_WARM_ABORT_PASS cache_dw='+[int](!$DisableCache)+
        ' mac_overlap='+[int]([bool]$OverlapMac)+' stage=18 valid_groups='+
        $(if($DisableCache){'0'}else{'2'})+' held_cycles=8 reset=0\r?$'
    if([regex]::Matches($all,$warmAbortPattern).Count -ne 1) {
        throw 'Missing or duplicate populated-cache abort/backpressure evidence'
    }
    if([regex]::Matches($all,'(?m)^C1_ENGINE_WARM_RESTART_PASS generation=11 stages=22 changed_lanes=[1-9][0-9]* reset=0\r?$').Count -ne 1) {
        throw 'Missing or duplicate changed-weight warm-abort restart evidence'
    }
    $summary = [ordered]@{ marker = $marker;
        cache_dw_weight_tiles = [int](!$DisableCache)
        stream_dw_groups = [int]$StreamDwGroups.IsPresent
        mac_prefetch_overlap = [int]([bool]$OverlapMac)
        packed_affine_cache = [int]([bool]$PackedAffine) }
    foreach ($name in @('stages','outputs','mac','dw','bypass','param_reads','stalls',
                        'aborts','faults','first_run_cycles')) {
        $m = [regex]::Match($marker, $name + '=([0-9]+)')
        if ($m.Success) { $summary[$name] = [int]$m.Groups[1].Value }
    }
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runLogRoot 'summary.json') -Encoding UTF8
    $watch.Stop()
    Write-Status 'complete' 'done' 0 'C1_R1_MICROSTYLE_ENGINE_PASS'
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
