param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$OutputRestart,
    [switch]$TagPopPush
)

# Detached, self-cleaning xsim runner for the four-bank MAC scaling point.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
$family = 'dot8x8_requant_pingpong_banks4'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "xsim_runs\$family\$RunId\status.json"
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd = "`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
           "-WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId" +
           $(if ($OutputRestart) { ' -OutputRestart' } else { '' }) +
           $(if ($TagPopPush) { ' -TagPopPush' } else { '' })
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $cmd; CurrentDirectory = $caseRoot }
    if ($r.ReturnValue -ne 0) { throw "WMI worker failed: $($r.ReturnValue)" }
    [ordered]@{ run_id = $RunId; worker_pid = [int]$r.ProcessId;
                status_path = $statusPath } | ConvertTo-Json
    exit 0
}
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $caseRoot "sim\xsim_${family}_$RunId"
$runLog = Join-Path $logRoot "xsim_runs\$family\$RunId"
$status = Join-Path $runLog 'status.json'
$latest = Join-Path $logRoot "xsim_${family}_status.json"
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot, $runLog | Out-Null
function Set-Status([string]$State, [string]$Step, [int]$Code, [string]$Message) {
    $v = [ordered]@{ run_id = $RunId; state = $State; step = $Step;
        exit_code = $Code; message = $Message; process_id = $PID;
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3);
        log_directory = $runLog; run_directory = $runRoot } | ConvertTo-Json
    $v | Set-Content -LiteralPath $status -Encoding UTF8
    $v | Set-Content -LiteralPath $latest -Encoding UTF8
}
function Invoke-Step([string]$Name, [string]$Tool, [string[]]$ToolArgs,
                     [string]$Marker = '') {
    $script:step = $Name
    Set-Status 'running' $Name 0 "starting $Name"
    $o = Join-Path $runLog "$Name.stdout.log"
    $e = Join-Path $runLog "$Name.stderr.log"
    $p = Start-Process -FilePath $Tool -ArgumentList $ToolArgs -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $o `
        -RedirectStandardError $e
    if ($p.ExitCode -ne 0) { throw "$Name exit code $($p.ExitCode)" }
    $t = (Get-Content -Raw -LiteralPath $o) + "`n" +
         (Get-Content -Raw -LiteralPath $e)
    if ($t -match '(?im)(^|\s)(Fatal|Error):|\$fatal|_FAIL') {
        throw "$Name reported failure"
    }
    if ($Marker -and [regex]::Matches($t, [regex]::Escape($Marker)).Count -ne 1) {
        throw "$Name missing marker $Marker"
    }
}
try {
    Set-Status 'running' 'setup' 0 $(if ($TagPopPush) {
        'detached four-bank ping-pong tag-pop-push worker started'
    } elseif ($OutputRestart) {
        'detached four-bank ping-pong output-restart worker started'
    } else {
        'detached four-bank ping-pong worker started'
    })
    $sources = @(
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum.sv'),
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_pipelined.sv'),
        (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_treepipe.sv'),
        (Join-Path $rtlRoot 'cnn\c1_requant_bank8.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_core.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_bank.sv'),
        (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_pingpong.sv'),
        (Join-Path $simRoot 'tb_c1_dot8x8_requant_pingpong.sv'))
    $defines = @('-d', 'C1_PINGPONG_BANKS4_TB')
    if ($OutputRestart) { $defines += @('-d', 'C1_PINGPONG_OUTPUT_RESTART_TB') }
    if ($TagPopPush) { $defines += @('-d', 'C1_PINGPONG_TAG_POP_PUSH_TB') }
    Invoke-Step 'xvlog' (Join-Path 'D:\vivado\vivado\Vivado\2023.1\bin' 'xvlog.bat') `
        (@('-sv', '-nolog') + $defines + $sources)
    Invoke-Step 'xelab' (Join-Path 'D:\vivado\vivado\Vivado\2023.1\bin' 'xelab.bat') `
        @('tb_c1_dot8x8_requant_pingpong', '-s',
          'tb_c1_dot8x8_requant_pingpong_banks4_sim', '-nolog')
    Invoke-Step 'xsim' (Join-Path 'D:\vivado\vivado\Vivado\2023.1\bin' 'xsim.bat') `
        @('tb_c1_dot8x8_requant_pingpong_banks4_sim', '-runall', '-nolog') `
        'C1_DOT8X8_REQUANT_PINGPONG_PASS'
    $watch.Stop()
    Set-Status 'complete' 'done' 0 'C1_DOT8X8_REQUANT_PINGPONG_PASS'
} catch {
    $watch.Stop(); Set-Status 'failed' $script:step 1 $_.Exception.Message; exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
