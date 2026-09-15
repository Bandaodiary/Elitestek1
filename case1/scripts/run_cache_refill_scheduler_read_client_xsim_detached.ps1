param(
    [switch]$Worker,
    [string]$RunId = '',
    [ValidateSet(2,16,32)][int]$SchedulerWindow = 2,
    [switch]$LongRows,
    [switch]$RequestHandoff
)

# Compact scheduler -> AXI128 read-client integration gate.  The WMI worker is
# intentionally detached from the caller's Windows Job; private xsim files
# are removed after each run and only marker/tail excerpts are persisted.
$ErrorActionPreference = 'Stop'
if(!$LongRows -and $SchedulerWindow -ne 2){throw 'Larger scheduler windows require LongRows for real occupancy coverage'}
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    $statusPath = Join-Path $logRoot "xsim_runs\cache_refill_scheduler_read_client\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId -SchedulerWindow $SchedulerWindow" + $(if($LongRows){' -LongRows'}else{''}) + $(if($RequestHandoff){' -RequestHandoff'}else{''})
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed: $($result.ReturnValue)"
    }
    [ordered]@{ run_id = $RunId; worker_pid = [int]$result.ProcessId;
                status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_run_cache_refill_scheduler_read_client_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\cache_refill_scheduler_read_client\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_cache_refill_scheduler_read_client_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status([string]$State, [string]$Step, [int]$ExitCode,
                       [string]$Message) {
    $obj = [ordered]@{ run_id = $RunId; state = $State; step = $Step;
        exit_code = $ExitCode; message = $Message; process_id = $PID;
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3);
        log_directory = $runLogRoot; run_directory = $runRoot } | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Save-CompactLog([string]$RawPath, [string]$CompactPath,
                          [string]$Marker = '') {
    $lines = @()
    if (Test-Path -LiteralPath $RawPath) {
        if ($Marker) {
            $lines += @(Select-String -LiteralPath $RawPath -Pattern $Marker |
                        ForEach-Object { $_.Line })
        }
        $lines += @(Get-Content -LiteralPath $RawPath -Tail 80)
    }
    if ($lines.Count -eq 0) { $lines = @('(empty)') }
    $lines | Select-Object -Unique | Set-Content -LiteralPath $CompactPath -Encoding UTF8
}

function Invoke-Step([string]$Name, [string]$Tool, [string[]]$ToolArgs,
                      [string]$Marker = '') {
    $script:step = $Name
    Write-Status 'running' $Name 0 "starting $Name"
    $rawOut = Join-Path $runRoot "$Name.raw.stdout.log"
    $rawErr = Join-Path $runRoot "$Name.raw.stderr.log"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $proc = Start-Process -FilePath $Tool -ArgumentList $ToolArgs `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr
    Save-CompactLog $rawOut $out $Marker
    Save-CompactLog $rawErr $err
    if ($null -eq $proc -or $proc.ExitCode -ne 0) {
        throw "$Name exit code $($proc.ExitCode)"
    }
    if ($Marker) {
        $markerLines = @(Select-String -LiteralPath $rawOut -Pattern $Marker |
                          ForEach-Object { $_.Line })
        if ($markerLines.Count -ne 1) {
            throw "$Name did not emit exactly one $Marker"
        }
    }
    $bad = @(Select-String -LiteralPath $rawOut,$rawErr `
             -Pattern '(?im)(^|\s)(Fatal|Error):|\$fatal|_FAIL|cannot be opened')
    if ($bad.Count -ne 0) { throw "$Name reported a tool failure" }
}

try {
    Write-Status 'running' 'setup' 0 'detached scheduler/read-client worker started'
    $sourceList = Join-Path $runRoot 'xvlog_sources.f'
    @(
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),
        (Join-Path $simRoot 'tb_c1_cache_refill_scheduler_read_client.sv')
    ) | Set-Content -LiteralPath $sourceList -Encoding ASCII
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') @(
        '-sv', '-nolog', '-f', $sourceList)
    $elabArgs=@(
        'tb_c1_cache_refill_scheduler_read_client', '-s',
        'tb_c1_cache_refill_scheduler_read_client_sim', '-nolog',
        '-generic_top',('"SCH_MAX_OUT='+$SchedulerWindow+'"'))
    if($LongRows){
        foreach($assignment in @('LEAF_REQ_DEPTH=32','LEAF_BURST_BEATS=16','LEAF_MAX_OUT=4','CMD0_WORDS=1920','CMD1_WORDS=1920')){
            $elabArgs+=@('-generic_top',('"'+$assignment+'"'))
        }
    }
    if($RequestHandoff){$elabArgs+=@('-generic_top','"REQ_HANDOFF=1"')}
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') $elabArgs
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_cache_refill_scheduler_read_client_sim', '-runall', '-nolog') `
        'C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_PASS'
    $watch.Stop()
    Write-Status 'complete' 'done' 0 'C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_PASS'
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
