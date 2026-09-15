param(
    [switch]$Worker,
    [switch]$CacheSideband,
    [switch]$PipelinedAddress,
    [switch]$PipelinedPixelIndex,
    [switch]$PipelinedDescriptorValidation,
    [switch]$NarrowDescriptorSizeCheck,
    [switch]$PipelinedDescriptorSizeArith,
    [switch]$FixedDescriptorSizeLimits,
    [switch]$PipelinedDescriptorPixelCount,
    [switch]$IterativeDescriptorPixelCount,
    [string]$RunId = ''
)

# WMI launches the hidden worker outside the Codex Windows Job.  Success
# requires clean exit codes, empty stderr, no Fatal/Error/FAIL diagnostic and
# exactly one self-checking tensor-adapter PASS marker.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
$testName = 'r1_microstyle_tensor_adapter'
$topName = 'tb_c1_r1_microstyle_tensor_adapter'
$passMarker = 'C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS'
if ($CacheSideband) {
    $testName = 'r1_microstyle_tensor_adapter_cache_sideband'
    $topName = 'tb_c1_r1_microstyle_tensor_adapter_cache_sideband'
    $passMarker = 'C1_R1_MICROSTYLE_TENSOR_ADAPTER_CACHE_SIDEBAND_PASS'
}

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $logRoot `
        "xsim_runs\$testName\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $workerOption = if ($CacheSideband) { ' -CacheSideband' } else { '' }
    if ($PipelinedAddress) { $workerOption += ' -PipelinedAddress' }
    if ($PipelinedPixelIndex) { $workerOption += ' -PipelinedPixelIndex' }
    if ($PipelinedDescriptorValidation) {
        $workerOption += ' -PipelinedDescriptorValidation'
    }
    if ($NarrowDescriptorSizeCheck) {
        $workerOption += ' -NarrowDescriptorSizeCheck'
    }
    if ($PipelinedDescriptorSizeArith) {
        $workerOption += ' -PipelinedDescriptorSizeArith'
    }
    if ($FixedDescriptorSizeLimits) {
        $workerOption += ' -FixedDescriptorSizeLimits'
    }
    if ($PipelinedDescriptorPixelCount) {
        $workerOption += ' -PipelinedDescriptorPixelCount'
    }
    if ($IterativeDescriptorPixelCount) {
        $workerOption += ' -IterativeDescriptorPixelCount'
    }
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId$workerOption"
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
        -Message 'detached MicroStyle tensor-adapter worker started'
    $xvlogArguments = @(
        '-sv',
        (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_tensor_adapter.sv'),
        (Join-Path $rtlRoot 'cnn\c1_pixel_result_writer.sv'),
        (Join-Path $simRoot 'tb_c1_r1_microstyle_tensor_adapter.sv')
    )
    if ($PipelinedAddress) {
        $xvlogArguments += @('-d', 'C1_PIPELINED_TENSOR_ADDRESS')
    }
    if ($PipelinedPixelIndex) {
        $xvlogArguments += @('-d', 'C1_PIPELINED_TENSOR_PIXEL_INDEX')
    }
    if ($PipelinedDescriptorValidation) {
        $xvlogArguments += @('-d', 'C1_PIPELINED_DESCRIPTOR_VALIDATION')
    }
    if ($NarrowDescriptorSizeCheck) {
        $xvlogArguments += @('-d', 'C1_NARROW_DESCRIPTOR_SIZE_CHECK')
    }
    if ($PipelinedDescriptorSizeArith) {
        $xvlogArguments += @('-d', 'C1_PIPELINED_DESCRIPTOR_SIZE_ARITH')
    }
    if ($FixedDescriptorSizeLimits) {
        $xvlogArguments += @('-d', 'C1_FIXED_DESCRIPTOR_SIZE_LIMITS')
    }
    if ($PipelinedDescriptorPixelCount) {
        $xvlogArguments += @('-d', 'C1_PIPELINED_DESCRIPTOR_PIXEL_COUNT')
    }
    if ($IterativeDescriptorPixelCount) {
        $xvlogArguments += @('-d', 'C1_ITERATIVE_DESCRIPTOR_PIXEL_COUNT')
    }
    if ($CacheSideband) {
        $xvlogArguments += (Join-Path $simRoot `
            'tb_c1_r1_microstyle_tensor_adapter_cache_sideband.sv')
    }
    Invoke-VivadoStep -Name 'xvlog' `
        -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments $xvlogArguments
    Invoke-VivadoStep -Name 'xelab' `
        -Tool (Join-Path $vivadoBin 'xelab.bat') -Arguments @(
            $topName,
            '-s', "${topName}_sim"
        )
    Invoke-VivadoStep -Name 'xsim' `
        -Tool (Join-Path $vivadoBin 'xsim.bat') -Arguments @(
            "${topName}_sim", '-runall'
        ) -ExpectedPass $passMarker
    $script:totalWatch.Stop()
    Write-Status -State 'complete' -Step 'done' -ExitCode 0 `
        -Message $passMarker
} catch {
    $script:totalWatch.Stop()
    Write-Status -State 'failed' -Step $script:currentStep -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
} finally {
    # Keep the persistent evidence small.  xvlog/xelab/xsim work files are
    # private to this run and are never needed by the caller after the compact
    # stdout/stderr/status records have been written.
    if (Test-Path -LiteralPath $runRoot) {
        $resolvedRun = (Resolve-Path -LiteralPath $runRoot).Path
        $resolvedSim = (Resolve-Path -LiteralPath $simRoot).Path
        if ($resolvedRun.StartsWith(
                $resolvedSim + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedRun -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}
