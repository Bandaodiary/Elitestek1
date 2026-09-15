param(
    [switch]$Worker,
    [string]$RunId = ''
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    $RunId = [guid]::NewGuid().ToString('N')
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$result.ProcessId
        status_path = (Join-Path $logRoot "display_prefetch_runs\$RunId\status.json")
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$runRoot = Join-Path $simRoot "display_prefetch_run_$RunId"
$runLogRoot = Join-Path $logRoot "display_prefetch_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'display_prefetch_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Set-StatusContent {
    param([string]$Path, [string]$Value)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $Value | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
            return
        } catch [IO.IOException] {
            if ($attempt -eq 19) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode, [string]$Message)
    $value = [ordered]@{
        run_id = $RunId
        state = $State
        step = $Step
        exit_code = $ExitCode
        message = $Message
        process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot
    } | ConvertTo-Json
    Set-StatusContent -Path $statusPath -Value $value
    Set-StatusContent -Path $latestStatusPath -Value $value
}

function Invoke-XsimStep {
    param([string]$Name, [string]$Tool, [string[]]$Arguments,
          [string]$ExpectedPass = '')
    Write-Status running $Name 0 "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)"
    }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    $diagnostics = $stdout + "`n" + $stderr
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "$Name wrote unexpected stderr"
    }
    if ($diagnostics -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened|\$\s*fatal') {
        throw "$Name log contains ERROR/FATAL/FAIL diagnostics"
    }
    if ($ExpectedPass -and
        ([regex]::Matches($diagnostics, [regex]::Escape($ExpectedPass)).Count -ne 1)) {
        throw "$Name did not emit exactly one $ExpectedPass marker"
    }
}

try {
    Write-Status running setup 0 'detached display-prefetch verification started'
    Invoke-XsimStep xvlog (Join-Path $vivadoBin 'xvlog.bat') @(
        '-sv',
        (Join-Path $rtlRoot 'common\c1_stream_fifo.sv'),
        (Join-Path $rtlRoot 'dma\c1_axi_xrgb_frame_reader.sv'),
        (Join-Path $rtlRoot 'display\c1_display_line_store_cdc.sv'),
        (Join-Path $rtlRoot 'display\c1_hex_osd_overlay.sv'),
        (Join-Path $rtlRoot 'display\c1_display_prefetch_pair.sv'),
        (Join-Path $simRoot 'tb_c1_display_prefetch_pair.sv'),
        (Join-Path $simRoot 'tb_c1_display_line_store_cdc.sv')
    )
    Invoke-XsimStep xelab (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_display_line_store_cdc', '-s', 'tb_c1_display_line_store_cdc_sim'
    )
    Invoke-XsimStep xsim (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_display_line_store_cdc_sim', '-runall'
    ) 'C1_DISPLAY_PREFETCH_CDC_PASS'
    Invoke-XsimStep xelab_pair (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_display_prefetch_pair', '-s', 'tb_c1_display_prefetch_pair_sim'
    )
    Invoke-XsimStep xsim_pair (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_display_prefetch_pair_sim', '-runall'
    ) 'C1_DISPLAY_PREFETCH_PAIR_PASS'
    $watch.Stop()
    Write-Status complete done 0 'C1_DISPLAY_PREFETCH_CDC_PASS'
} catch {
    $watch.Stop()
    Write-Status failed exception 1 $_.Exception.Message
    exit 1
}
