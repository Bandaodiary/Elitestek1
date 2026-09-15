param(
    [switch]$Worker,
    [switch]$PopRefill,
    [switch]$LongBurst,
    [switch]$ReqPopRefill,
    [switch]$ReqPopRefillBaseline,
    [string]$RunId = ''
)

# Detached Vivado/xsim worker for the read-burst prototype.  The worker owns
# the simulator process and deletes its private run tree before returning.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if (($PopRefill -and $LongBurst) -or
        (($ReqPopRefill -or $ReqPopRefillBaseline) -and ($PopRefill -or $LongBurst)) -or
        ($ReqPopRefill -and $ReqPopRefillBaseline)) {
        throw 'PopRefill, LongBurst, and request pop/refill profiles are mutually exclusive'
    }
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "xsim_runs\tensor_read_burst\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $modeArg = ''
    if ($PopRefill) { $modeArg += ' -PopRefill' }
    if ($LongBurst) { $modeArg += ' -LongBurst' }
    if ($ReqPopRefill) { $modeArg += ' -ReqPopRefill' }
    if ($ReqPopRefillBaseline) { $modeArg += ' -ReqPopRefillBaseline' }
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker$modeArg -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{ run_id=$RunId; worker_pid=[int]$result.ProcessId;
                status_path=$statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_run_tensor_read_burst_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\tensor_read_burst\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_runs\tensor_read_burst_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status([string]$State, [string]$Step, [int]$ExitCode, [string]$Message) {
    $obj = [ordered]@{ run_id=$RunId; state=$State; step=$Step; exit_code=$ExitCode;
        message=$Message; process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        log_directory=$runLogRoot; run_directory=$runRoot } | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}
function Invoke-Step([string]$Name, [string]$Tool, [string[]]$ToolArgs,
                     [string]$Marker='') {
    Write-Status 'running' $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $sp = @{ FilePath=$Tool; ArgumentList=$ToolArgs; WorkingDirectory=$runRoot;
        WindowStyle='Hidden'; Wait=$true; PassThru=$true;
        RedirectStandardOutput=$out; RedirectStandardError=$err }
    $proc = Start-Process @sp
    if ($proc.ExitCode -ne 0) { throw "$Name exit code $($proc.ExitCode)" }
    $all = (Get-Content -Raw -LiteralPath $out) + "`n" +
           (Get-Content -Raw -LiteralPath $err)
    if ($all -match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|\$fatal') {
        throw "$Name reported failure"
    }
    if ($Marker -and ([regex]::Matches($all,[regex]::Escape($Marker)).Count -ne 1)) {
        throw "$Name did not emit exactly one $Marker"
    }
}

try {
    if (($PopRefill -and $LongBurst) -or
        (($ReqPopRefill -or $ReqPopRefillBaseline) -and ($PopRefill -or $LongBurst)) -or
        ($ReqPopRefill -and $ReqPopRefillBaseline)) {
        throw 'PopRefill, LongBurst, and request pop/refill profiles are mutually exclusive'
    }
    Write-Status 'running' 'setup' 0 'detached tensor read-burst worker started'
    $xvlogArgs = @('-sv', '-nolog')
    if ($PopRefill) { $xvlogArgs += @('-d', 'C1_RSP_POP_REFILL_TB') }
    if ($LongBurst) { $xvlogArgs += @('-d', 'C1_LONG_BURST_TB') }
    if ($ReqPopRefill) { $xvlogArgs += @('-d', 'C1_REQ_POP_REFILL_TB') }
    $topName = 'tb_c1_tensor_mem_axi128_read_burst_client'
    $simName = 'tb_c1_tensor_mem_axi128_read_burst_client_sim'
    $tbSource = Join-Path $simRoot 'tb_c1_tensor_mem_axi128_read_burst_client.sv'
    $marker = 'C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_PASS'
    if ($ReqPopRefill -or $ReqPopRefillBaseline) {
        $topName = 'tb_c1_tensor_mem_axi128_read_burst_client_req_pop_refill'
        $simName = 'tb_c1_tensor_mem_axi128_read_burst_client_req_pop_refill_sim'
        $tbSource = Join-Path $simRoot 'tb_c1_tensor_mem_axi128_read_burst_client_req_pop_refill.sv'
        $marker = 'C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_REQ_POP_REFILL_PASS'
    }
    $xvlogArgs += @(
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),
        $tbSource)
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        $topName, '-s', $simName, '-nolog')
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        $simName, '-runall', '-nolog') `
        $marker
    $watch.Stop(); Write-Status 'complete' 'done' 0 $marker
} catch {
    $watch.Stop(); Write-Status 'failed' 'worker' 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
