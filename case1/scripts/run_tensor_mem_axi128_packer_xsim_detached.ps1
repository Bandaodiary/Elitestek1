param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Keep Vivado/xsim outside the Codex Windows Job.  The parent process only
# creates this WMI worker and polls status.json; the worker owns all tool
# lifetimes and logs.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $logRoot `
        "xsim_runs\tensor_mem_axi128_packer\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
    }
    [ordered]@{ run_id = $RunId; worker_pid = [int]$result.ProcessId;
                status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

$runRoot = Join-Path $simRoot "xsim_run_tensor_mem_axi128_packer_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\tensor_mem_axi128_packer\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_runs\tensor_mem_axi128_packer_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep = 'setup'
$script:stepSeconds = [ordered]@{}
$script:totalWatch = [Diagnostics.Stopwatch]::StartNew()

New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Set-StatusContent {
    param([string]$Path, [string]$Value)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try { $Value | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop; return }
        catch [IO.IOException] { if ($attempt -eq 19) { throw }; Start-Sleep -Milliseconds 25 }
    }
}

function Write-Status {
    param([string]$State, [string]$Step, [int]$ExitCode, [string]$Message)
    $status = [ordered]@{
        run_id = $RunId; state = $State; step = $Step; exit_code = $ExitCode
        message = $Message; process_id = $PID
        elapsed_seconds = [math]::Round($script:totalWatch.Elapsed.TotalSeconds, 3)
        step_seconds = $script:stepSeconds; updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot; run_directory = $runRoot
    } | ConvertTo-Json -Depth 4
    Set-StatusContent -Path $statusPath -Value $status
    Set-StatusContent -Path $latestStatusPath -Value $status
}

function Invoke-VivadoStep {
    param([string]$Name, [string]$Tool, [string[]]$Arguments,
          [string]$ExpectedPass = '')
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
    if ($process.ExitCode -ne 0) { throw "$Name failed with exit code $($process.ExitCode)" }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    $diagnostics = $stdout + "`n" + $stderr
    if ($diagnostics -match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened|\$\s*fatal') {
        throw "$Name reported Fatal/Error/FAIL"
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw "$Name wrote diagnostics to stderr" }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPass)) {
        $passCount = [regex]::Matches($stdout, [regex]::Escape($ExpectedPass)).Count
        if ($passCount -ne 1) { throw "$Name emitted $passCount copies of required marker $ExpectedPass" }
    }
    Write-Status -State 'running' -Step $Name -ExitCode 0 -Message "$Name complete"
}

try {
    Write-Status -State 'running' -Step 'setup' -ExitCode 0 -Message 'detached tensor AXI128 packer worker started'
    Invoke-VivadoStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') -Arguments @(
        '-sv', (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_packer.sv'),
        (Join-Path $simRoot 'tb_c1_tensor_mem_axi128_packer.sv'))
    Invoke-VivadoStep -Name 'xelab' -Tool (Join-Path $vivadoBin 'xelab.bat') -Arguments @(
        'tb_c1_tensor_mem_axi128_packer', '-s', 'tb_c1_tensor_mem_axi128_packer_sim')
    Invoke-VivadoStep -Name 'xsim' -Tool (Join-Path $vivadoBin 'xsim.bat') -Arguments @(
        'tb_c1_tensor_mem_axi128_packer_sim', '-runall') -ExpectedPass 'C1_TENSOR_MEM_AXI128_PACKER_PASS'
    $script:totalWatch.Stop()
    Write-Status -State 'complete' -Step 'done' -ExitCode 0 -Message 'C1_TENSOR_MEM_AXI128_PACKER_PASS'
} catch {
    $script:totalWatch.Stop()
    Write-Status -State 'failed' -Step $script:currentStep -ExitCode 1 -Message $_.Exception.Message
    exit 1
}
