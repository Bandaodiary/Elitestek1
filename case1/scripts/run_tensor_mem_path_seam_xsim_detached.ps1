param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Run the selectable legacy/performance seam in a WMI-created worker so the
# Vivado/xsim process tree is not owned by the current Codex Windows Job.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "xsim_runs\tensor_mem_path_seam\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed with return value $($result.ReturnValue)" }
    [ordered]@{ run_id = $RunId; worker_pid = [int]$result.ProcessId; status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
$runRoot = Join-Path $simRoot "xsim_run_tensor_mem_path_seam_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\tensor_mem_path_seam\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_runs\tensor_mem_path_seam_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep = 'setup'
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
    $status = [ordered]@{ run_id=$RunId; state=$State; step=$Step; exit_code=$ExitCode;
        message=$Message; process_id=$PID;
        elapsed_seconds=[math]::Round($script:totalWatch.Elapsed.TotalSeconds,3);
        updated=(Get-Date).ToString('o'); log_directory=$runLogRoot; run_directory=$runRoot } | ConvertTo-Json
    Set-StatusContent $statusPath $status; Set-StatusContent $latestStatusPath $status
}
function Invoke-VivadoStep {
    param([string]$Name, [string]$Tool, [string[]]$Arguments, [string]$ExpectedPass='')
    $script:currentStep = $Name; Write-Status 'running' $Name 0 "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) { throw "$Name failed with exit code $($process.ExitCode)" }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath; $stderr = Get-Content -Raw -LiteralPath $stderrPath
    if (($stdout + "`n" + $stderr) -match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened|\$\s*fatal') { throw "$Name reported Fatal/Error/FAIL" }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw "$Name wrote diagnostics to stderr" }
    if ($ExpectedPass) {
        if ([regex]::Matches($stdout,[regex]::Escape($ExpectedPass)).Count -ne 1) { throw "$Name did not emit exactly one $ExpectedPass" }
    }
    Write-Status 'running' $Name 0 "$Name complete"
}

try {
    Write-Status 'running' 'setup' 0 'detached tensor memory seam worker started'
    Invoke-VivadoStep 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') @(
        '-sv', (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_bridge.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_packer.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_path_seam.sv'),
        (Join-Path $simRoot 'tb_c1_tensor_mem_path_seam.sv'))
    Invoke-VivadoStep 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_tensor_mem_path_seam', '-s', 'tb_c1_tensor_mem_path_seam_sim')
    Invoke-VivadoStep 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_tensor_mem_path_seam_sim', '-runall') 'C1_TENSOR_MEM_PATH_SEAM_PASS'
    $script:totalWatch.Stop(); Write-Status 'complete' 'done' 0 'C1_TENSOR_MEM_PATH_SEAM_PASS'
} catch {
    $script:totalWatch.Stop(); Write-Status 'failed' $script:currentStep 1 $_.Exception.Message; exit 1
}
