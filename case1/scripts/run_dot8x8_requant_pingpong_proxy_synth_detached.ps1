param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$OutputRestart,
    [switch]$TagPopPush
)

# Detached Vivado proxy for the two-bank inter-pixel MAC shell.  The private
# project/runtime tree is removed after the compact summary is extracted.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptRoot = Join-Path $caseRoot 'scripts'
$logRoot = Join-Path $caseRoot 'logs'
$family = 'dot8x8_requant_pingpong_proxy_synth'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$vivado = Join-Path $vivadoRoot 'bin\vivado.bat'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "${family}_runs\$RunId\status.json"
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd = "`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
           "-WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId" +
           $(if ($OutputRestart) { ' -OutputRestart' } else { '' }) +
           $(if ($TagPopPush) { ' -TagPopPush' } else { '' })
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine=$cmd; CurrentDirectory=$caseRoot }
    if ($r.ReturnValue -ne 0) { throw "WMI worker failed: $($r.ReturnValue)" }
    [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=$statusPath} |
        ConvertTo-Json
    exit 0
}
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $caseRoot "sim\.tmp_${family}_$RunId"
$runLog = Join-Path $logRoot "${family}_runs\$RunId"
$status = Join-Path $runLog 'status.json'
$latest = Join-Path $logRoot "${family}_status.json"
$summaryPath = Join-Path $runLog 'summary.json'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLog | Out-Null
function Status([string]$state,[string]$step,[int]$code,[string]$message) {
    $v=[ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;
      message=$message;process_id=$PID;
      elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
      log_directory=$runLog;run_directory=$runRoot}|ConvertTo-Json
    $v|Set-Content -LiteralPath $status -Encoding UTF8
    $v|Set-Content -LiteralPath $latest -Encoding UTF8
}
function Metric([string]$text,[string]$label) {
    $m=[regex]::Match($text,'(?m)^\|\s*'+[regex]::Escape($label)+
       '\s*\|\s*([0-9,]+(?:\.[0-9]+)?)\s*\|')
    if($m.Success){return [double](($m.Groups[1].Value)-replace ',','')}
    return $null
}
function Timing([string]$text) {
    $lines=$text -split "`r?`n"
    for($i=0;$i -lt $lines.Count;$i++) {
        if($lines[$i] -match 'WNS\(ns\)' -and $lines[$i] -match 'TNS\(ns\)') {
            for($j=$i+1;$j -lt [math]::Min($i+10,$lines.Count);$j++) {
                $m=[regex]::Match($lines[$j],'^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s+'+
                    '([-+]?[0-9]+(?:\.[0-9]+)?)\s+')
                if($m.Success){return [ordered]@{wns_ns=[double]$m.Groups[1].Value;tns_ns=[double]$m.Groups[2].Value}}
            }
        }
    }
    return [ordered]@{wns_ns=$null;tns_ns=$null}
}
try {
    Status 'running' 'vivado' 0 $(if ($TagPopPush) {
        'detached ping-pong MAC tag-pop-push proxy synthesis started'
    } elseif ($OutputRestart) {
        'detached ping-pong MAC output-restart proxy synthesis started'
    } else {
        'detached ping-pong MAC proxy synthesis started'
    })
    # Warm the small installed runtime tree for WMI-created Vivado helpers.
    $buf=New-Object byte[] 65536
    Get-ChildItem -LiteralPath (Join-Path $vivadoRoot 'scripts\rt') -Filter '*.tcl' -File -Recurse |
      ForEach-Object { $s=[IO.File]::OpenRead($_.FullName); while($s.Read($buf,0,$buf.Length)-gt 0){}; $s.Dispose() }
    $out=Join-Path $runLog 'vivado.stdout.log'; $err=Join-Path $runLog 'vivado.stderr.log'
    $tcl=Join-Path $scriptRoot 'synth_dot8x8_requant_pingpong_proxy.tcl'
    $vivadoArgs = @('-mode','batch','-nolog','-nojournal','-notrace','-source',$tcl)
    if ($OutputRestart -or $TagPopPush) {
        $vivadoArgs += @('-tclargs', [int][bool]$OutputRestart,
                         [int][bool]$TagPopPush)
    }
    $p=Start-Process -FilePath $vivado -ArgumentList $vivadoArgs `
       -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($p.ExitCode -ne 0){throw "Vivado exit code $($p.ExitCode)"}
    $stdout=Get-Content -Raw -LiteralPath $out; $stderr=Get-Content -Raw -LiteralPath $err
    $all=$stdout+"`n"+$stderr
    if($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened'){throw 'Vivado reported failure'}
    $marker=if ($TagPopPush) {
        'C1_DOT8X8_REQUANT_PINGPONG_TAG_POP_PUSH_PROXY_SYNTH_PASS'
    } elseif ($OutputRestart) {
        'C1_DOT8X8_REQUANT_PINGPONG_OUTPUT_RESTART_PROXY_SYNTH_PASS'
    } else {
        'C1_DOT8X8_REQUANT_PINGPONG_PROXY_SYNTH_PASS'
    }
    if([regex]::Matches($stdout,[regex]::Escape($marker)).Count -ne 1){throw 'synthesis marker missing'}
    $reportRoot=Join-Path $runRoot 'reports'
    $util=Get-Content -Raw -LiteralPath (Join-Path $reportRoot 'utilization.rpt')
    $tim=Timing (Get-Content -Raw -LiteralPath (Join-Path $reportRoot 'timing.rpt'))
    $metrics=[ordered]@{part='xc7a200tsbg484-1';banks=2;lanes=2;output_restart=[bool]$OutputRestart;tag_pop_push=[bool]$TagPopPush;tag_fifo_depth=8;
      slice_luts=Metric $util 'Slice LUTs*';slice_registers=Metric $util 'Slice Registers';
      bram_tiles=Metric $util 'Block RAM Tile';dsps=Metric $util 'DSPs';
      wns_ns=$tim.wns_ns;tns_ns=$tim.tns_ns;
      timing_met=($null -ne $tim.wns_ns -and $tim.wns_ns -ge 0.0);marker=$marker}
    $critical=Join-Path $reportRoot 'critical.rpt'
    if(Test-Path -LiteralPath $critical){Get-Content -LiteralPath $critical -TotalCount 100 |
      Set-Content -LiteralPath (Join-Path $runLog 'critical_excerpt.rpt') -Encoding UTF8}
    [ordered]@{run_id=$RunId;marker=$marker;state='complete';metrics=$metrics} |
      ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop(); Status 'complete' 'done' 0 $marker
} catch {
    $watch.Stop(); Status 'failed' $script:step 1 $_.Exception.Message; exit 1
} finally {
    if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
