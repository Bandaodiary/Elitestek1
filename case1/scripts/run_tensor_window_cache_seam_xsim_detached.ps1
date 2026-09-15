param(
    [switch]$Worker,
    [string]$RunId = ''
)

# WMI-detached xsim regression for c1_tensor_window_cache_seam.  The worker
# and xsim/xsimk descendants are intentionally outside the caller's Windows
# Job so a Codex command interruption cannot terminate the simulator.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $logRoot "xsim_runs\tensor_window_cache_seam\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine
        CurrentDirectory = $caseRoot
    }
    if ($created.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($created.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$created.ProcessId
        status_path = $statusPath
    } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

$runRoot = Join-Path $simRoot "xsim_run_tensor_window_cache_seam_$RunId"
$runLog = Join-Path $logRoot "xsim_runs\tensor_window_cache_seam\$RunId"
$statusPath = Join-Path $runLog 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_runs\tensor_window_cache_seam_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:step = 'setup'
$script:watch = [Diagnostics.Stopwatch]::StartNew()
if(Test-Path -LiteralPath $runRoot){throw 'Refusing to reuse an existing simulation directory'}
New-Item -ItemType Directory -Force -Path $runRoot, $runLog | Out-Null

function Write-Status {
    param(
        [string]$State,
        [string]$Step,
        [int]$Code,
        [string]$Message
    )
    $value = [ordered]@{
        run_id = $RunId
        state = $State
        step = $Step
        exit_code = $Code
        message = $Message
        process_id = $PID
        elapsed_seconds = [math]::Round($script:watch.Elapsed.TotalSeconds, 3)
        updated = (Get-Date).ToString('o')
        log_directory = $runLog
        run_directory = $runRoot
    } | ConvertTo-Json
    $value | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $value | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-Step {
    param(
        [string]$Name,
        [string]$Tool,
        [string[]]$Arguments,
        [string]$Marker = ''
    )
    $script:step = $Name
    Write-Status 'running' $Name 0 "starting $Name"
    $stdoutPath = Join-Path $runLog "$Name.stdout.log"
    $stderrPath = Join-Path $runLog "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
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
    if ($Marker -and
        [regex]::Matches($stdout, [regex]::Escape($Marker)).Count -ne 1) {
        throw "$Name marker mismatch"
    }
    Write-Status 'running' $Name 0 "$Name complete"
}

try {
    Write-Status 'running' 'setup' 0 'detached tensor window cache seam worker started'
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') @(
        '-sv',
        (Join-Path $rtlRoot 'cnn\c1_window_line_cache_c8.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_window_cache_seam.sv'),
        (Join-Path $simRoot 'tb_c1_tensor_window_cache_seam.sv')
    )
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_tensor_window_cache_seam',
        '-s',
        'tb_c1_tensor_window_cache_seam_sim'
    )
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_tensor_window_cache_seam_sim',
        '-runall'
    ) 'C1_TENSOR_WINDOW_CACHE_SEAM_PASS'
    $inflightMarker='C1_NONBURST_INFLIGHT_MAINTENANCE_PASS abort_pulses=2 flush_pulses=2 held_response=12 row_reads=8 logical_retire=1'
    if(@(Select-String -LiteralPath (Join-Path $runLog 'xsim.stdout.log') -Pattern ('^'+[regex]::Escape($inflightMarker)+'$')).Count -ne 1){
        throw 'Missing unique nonburst inflight maintenance evidence'
    }
    foreach($firstAbort in @(0,1)){
        foreach($secondAbort in @(0,1)){
            $collisionMarker="C1_NONBURST_MAINTENANCE_COLLISION_PASS first_abort=$firstAbort second_abort=$secondAbort"
            if(@(Select-String -LiteralPath (Join-Path $runLog 'xsim.stdout.log') -Pattern ('^'+[regex]::Escape($collisionMarker)+'$')).Count -ne 1){
                throw 'Missing unique nonburst maintenance collision evidence'
            }
        }
    }
    $script:watch.Stop()
    Write-Status 'complete' 'done' 0 'C1_TENSOR_WINDOW_CACHE_SEAM_PASS'
} catch {
    $script:watch.Stop()
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    if(Test-Path -LiteralPath $runRoot){
        $resolvedRun=(Resolve-Path -LiteralPath $runRoot).Path
        $resolvedSim=(Resolve-Path -LiteralPath $simRoot).Path
        if((Split-Path -Parent $resolvedRun) -ne $resolvedSim -or
           (Split-Path -Leaf $resolvedRun) -ne "xsim_run_tensor_window_cache_seam_$RunId"){
            throw 'Refusing cleanup outside the unique simulation directory'
        }
        Remove-Item -LiteralPath $resolvedRun -Recurse -Force
    }
}
