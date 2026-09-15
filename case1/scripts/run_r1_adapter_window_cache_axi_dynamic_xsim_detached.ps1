param(
    [switch]$Worker,
    [string]$RunId = ''
)

# WMI starts a hidden worker outside the Codex Windows Job.  The worker then
# runs xvlog/xelab/xsim synchronously and accepts success only with empty
# stderr and exactly one base marker plus one full AXI-chain marker.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
$testName = 'r1_adapter_window_cache_axi_dynamic'
$topName = 'tb_c1_r1_adapter_window_cache_axi_dynamic'
$passMarker = 'C1_R1_ADAPTER_WINDOW_CACHE_AXI_DYNAMIC_PASS'
$baseMarker = 'C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $logRoot `
        "xsim_runs\$testName\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
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

$runRoot = Join-Path $simRoot "xsim_run_${testName}_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\$testName\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot "xsim_runs\${testName}_status.json"
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep = 'setup'
$script:stepSeconds = [ordered]@{}
$script:totalWatch = [Diagnostics.Stopwatch]::StartNew()

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
        [switch]$CheckMarkers
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
    if (($stdout + "`n" + $stderr) -match
        '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened|\$\s*fatal') {
        throw "$Name reported Fatal/Error/FAIL"
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "$Name wrote diagnostics to stderr"
    }
    if ($CheckMarkers) {
        $passCount = [regex]::Matches($stdout, [regex]::Escape($passMarker)).Count
        $baseCount = [regex]::Matches($stdout, [regex]::Escape($baseMarker)).Count
        if ($passCount -ne 1 -or $baseCount -ne 1) {
            throw "$Name marker mismatch axi_dynamic=$passCount base=$baseCount"
        }
    }
    Write-Status -State 'running' -Step $Name -ExitCode 0 -Message "$Name complete"
}

try {
    Write-Status -State 'running' -Step 'setup' -ExitCode 0 `
        -Message 'detached adapter-cache-AXI dynamic worker started'
    Invoke-VivadoStep -Name 'xvlog' `
        -Tool (Join-Path $vivadoBin 'xvlog.bat') -Arguments @(
            '-sv',
            (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_tensor_adapter.sv'),
            (Join-Path $rtlRoot 'cnn\c1_pixel_result_writer.sv'),
            (Join-Path $rtlRoot 'cnn\c1_window_line_cache_c8.sv'),
            (Join-Path $rtlRoot 'dma\c1_tensor_window_cache_seam.sv'),
            (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_bridge.sv'),
            (Join-Path $simRoot 'tb_c1_r1_microstyle_tensor_adapter.sv'),
            (Join-Path $simRoot 'tb_c1_r1_adapter_window_cache_axi_dynamic.sv')
        )
    Invoke-VivadoStep -Name 'xelab' `
        -Tool (Join-Path $vivadoBin 'xelab.bat') -Arguments @(
            $topName, '-s', "${topName}_sim"
        )
    Invoke-VivadoStep -Name 'xsim' `
        -Tool (Join-Path $vivadoBin 'xsim.bat') -Arguments @(
            "${topName}_sim", '-runall'
        ) -CheckMarkers
    $script:totalWatch.Stop()
    Write-Status -State 'complete' -Step 'done' -ExitCode 0 -Message $passMarker
} catch {
    $script:totalWatch.Stop()
    Write-Status -State 'failed' -Step $script:currentStep -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
}
