param(
    [switch]$Worker,
    [switch]$Burst32,
    [string]$RunId = ''
)

# Detached, boardless BURST_BEATS A/B profile for the AXI128 read leaf.
# Win32_Process.Create detaches the worker from the caller's Windows Job;
# the worker owns a private xsim tree and removes it before returning.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    $statusPath = Join-Path $logRoot "xsim_runs\tensor_read_burst_profile\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $modeArg = ''
    if ($Burst32) { $modeArg = ' -Burst32' }
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker$modeArg -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed: $($result.ReturnValue)"
    }
    [ordered]@{ run_id = $RunId; burst_beats = $(if ($Burst32) { 32 } else { 16 });
                worker_pid = [int]$result.ProcessId; status_path = $statusPath } |
        ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_run_tensor_read_burst_profile_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\tensor_read_burst_profile\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_tensor_read_burst_profile_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status([string]$State, [string]$Step, [int]$ExitCode,
                       [string]$Message) {
    $obj = [ordered]@{ run_id = $RunId; state = $State; step = $Step;
        exit_code = $ExitCode; message = $Message; process_id = $PID;
        burst_beats = $(if ($Burst32) { 32 } else { 16 });
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3);
        log_directory = $runLogRoot; run_directory = $runRoot } | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-Step([string]$Name, [string]$Tool, [string[]]$ToolArgs,
                      [string]$Marker = '') {
    $script:step = $Name
    Write-Status 'running' $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $sp = @{ FilePath = $Tool; ArgumentList = $ToolArgs;
        WorkingDirectory = $runRoot; WindowStyle = 'Hidden'; Wait = $true;
        PassThru = $true; RedirectStandardOutput = $out;
        RedirectStandardError = $err }
    $proc = Start-Process @sp
    if ($null -eq $proc -or $proc.ExitCode -ne 0) {
        throw "$Name exit code $($proc.ExitCode)"
    }
    $all = (Get-Content -Raw -LiteralPath $out) + "`n" +
           (Get-Content -Raw -LiteralPath $err)
    if ($all -match '(?im)(^|\s)(Fatal|Error):|\$fatal|_FAIL') {
        throw "$Name reported failure"
    }
    if ($Marker -and
        ([regex]::Matches($all, [regex]::Escape($Marker)).Count -ne 1)) {
        throw "$Name did not emit exactly one $Marker"
    }
}

try {
    Write-Status 'running' 'setup' 0 'detached read burst A/B worker started'
    $xvlogArgs = @('-sv', '-nolog')
    if ($Burst32) { $xvlogArgs += @('-d', 'C1_BURST32_PROFILE_TB') }
    $xvlogArgs += @(
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),
        (Join-Path $simRoot 'tb_c1_tensor_mem_axi128_read_burst_profile.sv'))
    $topName = 'tb_c1_tensor_mem_axi128_read_burst_profile'
    $simName = if ($Burst32) {
        'tb_c1_tensor_mem_axi128_read_burst_profile_32_sim'
    } else {
        'tb_c1_tensor_mem_axi128_read_burst_profile_16_sim'
    }
    $marker = 'C1_TENSOR_MEM_AXI128_READ_BURST_PROFILE_PASS'
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        $topName, '-s', $simName, '-nolog')
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        $simName, '-runall', '-nolog') $marker
    $watch.Stop()
    Write-Status 'complete' 'done' 0 $marker
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
