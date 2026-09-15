param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$CompileOnly
)

# Keep Vivado/xsim outside the Codex desktop Windows Job.  This staged runner
# is intentionally independent of the full portable-SoC runner so a native
# 640x480 read-side experiment can be compiled or stopped without disturbing
# a long CNN simulation.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'RunId contains unsupported characters'
    }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $extra = if ($CompileOnly) { ' -CompileOnly' } else { '' }
    $commandLine = '"' + $powerShell +
        '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass' +
        ' -WindowStyle Hidden -File "' + $PSCommandPath +
        '" -Worker -RunId ' + $RunId + $extra
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$result.ProcessId
        status_path = Join-Path $logRoot "native_input_dma_runs\$RunId\status.json"
    } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}
$runRoot = Join-Path $simRoot "native_input_dma_run_$RunId"
$runLogRoot = Join-Path $logRoot "native_input_dma_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'native_input_dma_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep = 'setup'
$script:stepSeconds = [ordered]@{}
$script:watch = [Diagnostics.Stopwatch]::StartNew()

New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Set-StatusContent([string]$Path,[string]$Value) {
    $Value | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Write-Status([string]$State,[string]$Step,[int]$ExitCode,[string]$Message) {
    $value = [ordered]@{
        run_id = $RunId
        frame = '3x640x480'
        state = $State
        step = $Step
        exit_code = $ExitCode
        message = $Message
        process_id = $PID
        elapsed_seconds = [math]::Round($script:watch.Elapsed.TotalSeconds,3)
        step_seconds = $script:stepSeconds
        updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot
        run_directory = $runRoot
    } | ConvertTo-Json -Depth 4
    Set-StatusContent $statusPath $value
    Set-StatusContent $latestStatusPath $value
}
function Invoke-VivadoStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$ExpectedPass='')
    $script:currentStep = $Name
    Write-Status running $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $stepWatch = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $stepWatch.Stop()
    $script:stepSeconds[$Name] = [math]::Round($stepWatch.Elapsed.TotalSeconds,3)
    if ($p.ExitCode -ne 0) { throw "$Name failed with exit code $($p.ExitCode)" }
    $stdout = Get-Content -Raw -LiteralPath $out
    $stderr = Get-Content -Raw -LiteralPath $err
    $all = $stdout + [Environment]::NewLine + $stderr
    if ($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|_[Ff][Aa][Ii][Ll]\b|cannot be opened|\$\s*fatal') {
        throw "$Name reported ERROR/FATAL/FAIL; inspect $out and $err"
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "$Name wrote diagnostics to stderr"
    }
    if ($ExpectedPass) {
        $count = [regex]::Matches($stdout,[regex]::Escape($ExpectedPass)).Count
        if ($count -ne 1) { throw "$Name emitted marker count=$count" }
    }
    Write-Status running $Name 0 "$Name complete"
}

try {
    Write-Status running setup 0 'detached native input-DMA/table/arbiter worker started'
    $sources = @(
        (Join-Path $rtlRoot 'dma\c1_axi_frame_buffer_table_reader.sv'),
        (Join-Path $rtlRoot 'dma\c1_axi_xrgb_frame_reader.sv'),
        (Join-Path $rtlRoot 'dma\c1_axi2_serial_arbiter_128.sv'),
        (Join-Path $simRoot 'tb_c1_r1_native_input_dma.sv')
    )
    Invoke-VivadoStep xvlog (Join-Path $vivadoBin 'xvlog.bat') (@('-sv') + $sources)
    Invoke-VivadoStep xelab (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_r1_native_input_dma','-s','tb_c1_r1_native_input_dma_sim')
    if ($CompileOnly) {
        $script:watch.Stop()
        Write-Status complete elaboration 0 `
            'C1_R1_NATIVE_INPUT_DMA_ELAB_PASS frame=3x640x480'
        exit 0
    }
    Invoke-VivadoStep xsim (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_r1_native_input_dma_sim','-runall') `
        'C1_R1_NATIVE_INPUT_DMA_PASS'
    $script:watch.Stop()
    Write-Status complete done 0 'C1_R1_NATIVE_INPUT_DMA_PASS frame=3x640x480'
} catch {
    $script:watch.Stop()
    Write-Status failed $script:currentStep 1 $_.Exception.Message
    exit 1
}
