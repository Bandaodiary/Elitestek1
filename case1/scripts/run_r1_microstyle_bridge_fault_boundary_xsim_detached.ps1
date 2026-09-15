param(
    [switch]$Worker,
    [string]$RunId = ''
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = '"' + $powerShell + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Worker -RunId ' + $RunId
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine
        CurrentDirectory = $caseRoot
    }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$result.ProcessId
        status_path = (Join-Path $logRoot "r1_microstyle_bridge_fault_boundary_runs\$RunId\status.json")
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$runRoot = Join-Path $simRoot "r1_microstyle_bridge_fault_boundary_run_$RunId"
$runLogRoot = Join-Path $logRoot "r1_microstyle_bridge_fault_boundary_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$tempFileCount = 0
$tempBytes = 0
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status {
    param([string]$State,[string]$Step,[int]$ExitCode,[string]$Message)
    [ordered]@{
        run_id=$RunId; state=$State; step=$Step; exit_code=$ExitCode
        message=$Message; process_id=$PID
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
        updated=(Get-Date).ToString('o'); log_directory=$runLogRoot
        temp_files_deleted=$tempFileCount; temp_bytes_deleted=$tempBytes
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

function Invoke-XsimStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$ExpectedPass='')
    Write-Status running $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $p = Start-Process -FilePath $Tool -ArgumentList $Arguments -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if ($p.ExitCode -ne 0) { throw "$Name exit $($p.ExitCode)" }
    $stdout = Get-Content -Raw -LiteralPath $out
    $stderr = Get-Content -Raw -LiteralPath $err
    $all = $stdout + [Environment]::NewLine + $stderr
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw "$Name unexpected stderr" }
    if ($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened|\$\s*fatal') {
        throw "$Name log contains ERROR/FATAL/FAIL"
    }
    if ($ExpectedPass) {
        $n = [regex]::Matches($all,[regex]::Escape($ExpectedPass)).Count
        if ($n -ne 1) { throw "$Name missing unique $ExpectedPass" }
    }
}

$finalState='complete'; $finalStep='done'; $finalExit=0
$finalMessage='C1_R1_MICROSTYLE_BRIDGE_FAULT_BOUNDARY_PASS'
try {
    Write-Status running setup 0 'detached bridge fault-boundary verification started'
    $sources = @(
        '-sv',
        (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
        (Join-Path $rtlRoot 'common\c1_r1_unified_output_fifo.sv'),
        (Join-Path $rtlRoot 'common\c1_r1_unified_output_skid.sv'),
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
        (Join-Path $rtlRoot 'top\c1_r1_microstyle_system_bridge.sv'),
        (Join-Path $simRoot 'tb_c1_r1_microstyle_bridge_fault_boundary.sv'))
    Invoke-XsimStep xvlog (Join-Path $vivadoBin 'xvlog.bat') $sources
    Invoke-XsimStep xelab (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_r1_microstyle_bridge_fault_boundary','-s','tb_c1_r1_microstyle_bridge_fault_boundary_sim')
    Invoke-XsimStep xsim (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_r1_microstyle_bridge_fault_boundary_sim','-runall') `
        'C1_R1_MICROSTYLE_BRIDGE_FAULT_BOUNDARY_PASS'
} catch {
    $finalState='failed'; $finalStep='exception'; $finalExit=1
    $finalMessage=$_.Exception.Message
} finally {
    $watch.Stop()
    try {
        if (Test-Path -LiteralPath $runRoot) {
            $items=@(Get-ChildItem -LiteralPath $runRoot -Recurse -File -Force)
            $tempFileCount=$items.Count
            $tempBytes=[long](($items | Measure-Object Length -Sum).Sum)
            $resolvedRun=(Resolve-Path -LiteralPath $runRoot).Path
            $resolvedSim=(Resolve-Path -LiteralPath $simRoot).Path
            if (-not $resolvedRun.StartsWith($resolvedSim+[IO.Path]::DirectorySeparatorChar) -or
                [IO.Path]::GetFileName($resolvedRun) -ne "r1_microstyle_bridge_fault_boundary_run_$RunId") {
                throw "refusing to remove unexpected path $resolvedRun"
            }
            Remove-Item -LiteralPath $resolvedRun -Recurse -Force
        }
    } catch {
        $finalState='failed'; $finalStep='cleanup'; $finalExit=1
        $finalMessage=$_.Exception.Message
    }
    Write-Status $finalState $finalStep $finalExit $finalMessage
}
exit $finalExit

