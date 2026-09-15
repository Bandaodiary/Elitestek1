param(
    [switch]$Worker,
    [string]$RunId = '',
    [ValidateRange(1,32)][int]$SchedulerWindow = 2,
    [ValidateRange(2,256)][int]$WordCount = 5,
    [switch]$RequestHandoff
)

# Detached compact xsim runner for the full boardless exact-count composition.
$ErrorActionPreference = 'Stop'
if($WordCount -le $SchedulerWindow){throw 'WordCount must exceed SchedulerWindow to exercise the synthetic suffix'}
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = 'exact_composition_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    $runLog = Join-Path $logRoot "xsim_runs\cache_refill_scheduler_read_client_exact\$RunId"
    $statusPath = Join-Path $runLog 'status.json'
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId -SchedulerWindow $SchedulerWindow -WordCount $WordCount"
    if($RequestHandoff){$commandLine += ' -RequestHandoff'}
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{run_id=$RunId;worker_pid=[int]$result.ProcessId;status_path=$statusPath} |
        ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_cache_refill_scheduler_read_client_exact_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\cache_refill_scheduler_read_client_exact\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_cache_refill_scheduler_read_client_exact_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Write-Status([string]$State,[string]$Step,[int]$Code,[string]$Message) {
    $obj=[ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$Code;
        message=$Message;process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        log_directory=$runLogRoot;run_directory=$runRoot}|ConvertTo-Json
    $obj|Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj|Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}
function Save-Compact([string]$Source,[string]$Destination,[string]$Marker='') {
    $lines=@()
    if(Test-Path -LiteralPath $Source){
        if($Marker){$lines+=@(Select-String -LiteralPath $Source -Pattern ([regex]::Escape($Marker)) -ErrorAction SilentlyContinue|ForEach-Object{$_.Line})}
        $lines+=@(Get-Content -LiteralPath $Source -Tail 100 -ErrorAction SilentlyContinue)
    }
    if($lines.Count -eq 0){$lines=@('(empty)')}
    $lines|Select-Object -Unique|Set-Content -LiteralPath $Destination -Encoding UTF8
}
function Invoke-Step([string]$Name,[string]$Tool,[string[]]$ToolArgs,[string]$Marker='') {
    Write-Status 'running' $Name 0 "starting $Name"
    $rawOut=Join-Path $runRoot "$Name.stdout.raw.log"; $rawErr=Join-Path $runRoot "$Name.stderr.raw.log"
    $out=Join-Path $runLogRoot "$Name.stdout.log"; $err=Join-Path $runLogRoot "$Name.stderr.log"
    try{
        $p=Start-Process -FilePath $Tool -ArgumentList $ToolArgs -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr
        if($null -eq $p -or $p.ExitCode -ne 0){throw "$Name exit code $($p.ExitCode)"}
        $bad='(?i)(^|\s)(Fatal|Error):|\bFAIL\b|\$fatal'
        if(Select-String -LiteralPath $rawOut,$rawErr -Pattern $bad -Quiet -ErrorAction SilentlyContinue){throw "$Name reported failure"}
        if($Marker){$hits=@(Select-String -LiteralPath $rawOut -Pattern ([regex]::Escape($Marker)) -AllMatches -ErrorAction SilentlyContinue);$count=0;foreach($h in $hits){if($h.Matches){$count+=$h.Matches.Count}else{$count++}};if($count -ne 1){throw "$Name marker missing or duplicated"}}
    }finally{Save-Compact $rawOut $out $Marker;Save-Compact $rawErr $err}
}

try {
    Write-Status 'running' 'setup' 0 'detached exact composition worker started'
    $sources=Join-Path $runRoot 'xvlog_sources.f'
    @(
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_read_burst_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler_read_client.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_completion_adapter.sv'),
        (Join-Path $rtlRoot 'dma\c1_cache_refill_scheduler_read_client_exact.sv'),
        (Join-Path $simRoot 'tb_c1_cache_refill_scheduler_read_client_exact.sv')
    )|Set-Content -LiteralPath $sources -Encoding ASCII
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') @('-sv','-nolog','-f',$sources)
    $xelabArgs = @('tb_c1_cache_refill_scheduler_read_client_exact','-s','tb_c1_cache_refill_scheduler_read_client_exact_sim','-nolog','-generic_top',('"SCHED_MAX='+$SchedulerWindow+'"'),'-generic_top',('"WORDS='+$WordCount+'"'))
    if($RequestHandoff){$xelabArgs += @('-generic_top','"REQ_HANDOFF=1"')}
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') $xelabArgs
    $marker='C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_EXACT_PASS'
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @('tb_c1_cache_refill_scheduler_read_client_exact_sim','-runall','-nolog') $marker
    $watch.Stop();Write-Status 'complete' 'done' 0 $marker
}catch{
    $watch.Stop();Write-Status 'failed' 'worker' 1 $_.Exception.Message;exit 1
}finally{
    if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
