param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$FirstBeat,
    [switch]$OutputRestart,
    [switch]$TagPopPush
)

# Detached, self-cleaning xsim runner for the inter-pixel MAC overlap shell.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
$family = 'dot8x8_requant_pingpong'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "xsim_runs\$family\$RunId\status.json"
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd = "`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
           "-WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId" +
           $(if ($FirstBeat) { ' -FirstBeat' } else { '' }) +
           $(if ($OutputRestart) { ' -OutputRestart' } else { '' }) +
           $(if ($TagPopPush) { ' -TagPopPush' } else { '' })
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $cmd; CurrentDirectory = $caseRoot }
    if ($r.ReturnValue -ne 0) { throw "WMI worker failed: $($r.ReturnValue)" }
    [ordered]@{ run_id=$RunId; worker_pid=[int]$r.ProcessId;
                status_path=$statusPath } | ConvertTo-Json
    exit 0
}
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_${family}_$RunId"
$runLog = Join-Path $logRoot "xsim_runs\$family\$RunId"
$status = Join-Path $runLog 'status.json'
$latest = Join-Path $logRoot "xsim_${family}_status.json"
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog | Out-Null
function Set-Status([string]$State,[string]$Step,[int]$Code,[string]$Message) {
    $v = [ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$Code;
        message=$Message;process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        log_directory=$runLog;run_directory=$runRoot} | ConvertTo-Json
    $v | Set-Content -LiteralPath $status -Encoding UTF8
    $v | Set-Content -LiteralPath $latest -Encoding UTF8
}
function Invoke-Step([string]$Name,[string]$Tool,[string[]]$ToolArgs,[string]$Marker='') {
    $script:step = $Name
    Set-Status 'running' $Name 0 "starting $Name"
    $o=Join-Path $runLog "$Name.stdout.log"; $e=Join-Path $runLog "$Name.stderr.log"
    $p=Start-Process -FilePath $Tool -ArgumentList $ToolArgs -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $o `
        -RedirectStandardError $e
    if($p.ExitCode -ne 0){throw "$Name exit code $($p.ExitCode)"}
    $t=(Get-Content -Raw -LiteralPath $o)+"`n"+(Get-Content -Raw -LiteralPath $e)
    if($t -match '(?im)(^|\s)(Fatal|Error):|\$fatal|_FAIL'){throw "$Name reported failure"}
    if($Marker -and [regex]::Matches($t,[regex]::Escape($Marker)).Count -ne 1){
        throw "$Name missing marker $Marker"
    }
}
try {
    $sources = @(
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum.sv'),
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_pipelined.sv'),
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_treepipe.sv'),
        (Join-Path $rtlRoot 'cnn\c1_requant_bank8.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_core.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_bank.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_pingpong.sv'),
        (Join-Path $simRoot 'tb_c1_dot8x8_requant_pingpong.sv'))
    $xvlogArgs = @('-sv','-nolog')
    if ($FirstBeat) {
        $xvlogArgs += @('-d','C1_PINGPONG_FIRST_BEAT_TB')
    }
    if ($OutputRestart) {
        $xvlogArgs += @('-d','C1_PINGPONG_OUTPUT_RESTART_TB')
    }
    if ($TagPopPush) {
        $xvlogArgs += @('-d','C1_PINGPONG_TAG_POP_PUSH_TB')
    }
    $xvlogArgs += $sources
    Set-Status 'running' 'setup' 0 $(if ($TagPopPush) {
        'detached ping-pong MAC tag-pop-push worker started'
    } elseif ($OutputRestart) {
        'detached ping-pong MAC output-restart worker started'
    } elseif ($FirstBeat) {
        'detached ping-pong MAC first-beat worker started'
    } else {
        'detached ping-pong MAC worker started'
    })
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_dot8x8_requant_pingpong','-s','tb_c1_dot8x8_requant_pingpong_sim','-nolog')
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_dot8x8_requant_pingpong_sim','-runall','-nolog') `
        'C1_DOT8X8_REQUANT_PINGPONG_PASS'
    $watch.Stop(); Set-Status 'complete' 'done' 0 'C1_DOT8X8_REQUANT_PINGPONG_PASS'
} catch {
    $watch.Stop(); Set-Status 'failed' $script:step 1 $_.Exception.Message; exit 1
} finally {
    if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
