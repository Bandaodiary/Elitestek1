param([switch]$Worker,[string]$RunId='')
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot=Join-Path $caseRoot 'rtl'; $simRoot=Join-Path $caseRoot 'sim'
$vecRoot=Join-Path $caseRoot 'vectors\microstyle_engine_bitexact_8x8'
$logRoot=Join-Path $caseRoot 'logs\r1_microstyle_engine_artifact_8x8_runs'
if (!$Worker) {
  if ([string]::IsNullOrWhiteSpace($RunId)) {$RunId=[guid]::NewGuid().ToString('N')}
  $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $cl="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
  $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cl;CurrentDirectory=$caseRoot}
  if($r.ReturnValue -ne 0){throw "Win32_Process.Create failed: $($r.ReturnValue)"}
  [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;status_path=(Join-Path $logRoot "$RunId\status.json")}|ConvertTo-Json; return
}
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
$runRoot=Join-Path $simRoot "xsim_r1_microstyle_engine_artifact_8x8_$RunId"
$runLog=Join-Path $logRoot $RunId; $status=Join-Path $runLog 'status.json'
$vivado='D:\vivado\vivado\Vivado\2023.1\bin'; $sw=[Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLog|Out-Null
function Set-Status([string]$state,[string]$step,[int]$code,[string]$message){
  [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$code;message=$message;elapsed_seconds=[math]::Round($sw.Elapsed.TotalSeconds,3);run_directory=$runRoot;log_directory=$runLog}|ConvertTo-Json|Set-Content -LiteralPath $status -Encoding UTF8
}
function Step([string]$name,[string]$tool,[string[]]$toolArgs,[string]$marker=''){
  Set-Status running $name 0 "starting $name"; $o=Join-Path $runLog "$name.stdout.log"; $e=Join-Path $runLog "$name.stderr.log"
  $p=Start-Process -FilePath $tool -ArgumentList $toolArgs -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
  $out=Get-Content -Raw -LiteralPath $o; $err=Get-Content -Raw -LiteralPath $e
  if($p.ExitCode -ne 0 -or ![string]::IsNullOrWhiteSpace($err) -or $out -match '(?im)Fatal|Error:|FAIL'){throw "$name failed"}
  if($marker -and ([regex]::Matches($out,[regex]::Escape($marker))).Count -ne 1){throw "$name marker mismatch"}
}
try {
  Set-Status running setup 0 'detached trained artifact 8x8 engine probe'
  foreach($f in 'descriptors.mem','parameter_arena.mem','engine_vectors.mem','expected_outputs.mem','stage_meta.mem'){Copy-Item -LiteralPath (Join-Path $vecRoot $f) -Destination (Join-Path $runRoot $f)}
  $src=@(
    (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
    (Join-Path $rtlRoot 'control\c1_descriptor_pkg.sv'),
    (Join-Path $rtlRoot 'control\c1_descriptor_decoder_pkg.sv'),
    (Join-Path $rtlRoot 'control\c1_layer_command_decoder.sv'),
    (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum.sv'),
    (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_pipelined.sv'),
    (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_treepipe.sv'),
    (Join-Path $rtlRoot 'cnn\c1_requant_bank8.sv'),
    (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_core.sv'),
    (Join-Path $rtlRoot 'cnn\c1_dwconv3x3_c8_requant_core.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_c8_parameter_scheduler.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_engine.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_cnn_top.sv'),
    (Join-Path $simRoot 'tb_c1_r1_microstyle_engine_artifact_8x8.sv'))
  Step xvlog (Join-Path $vivado 'xvlog.bat') (@('-sv')+$src)
  Step xelab (Join-Path $vivado 'xelab.bat') @('tb_c1_r1_microstyle_engine_artifact_8x8','-s','artifact_8x8_sim')
  Step xsim (Join-Path $vivado 'xsim.bat') @('artifact_8x8_sim','-runall') 'C1_R1_MICROSTYLE_ENGINE_ARTIFACT_8X8_PASS'
  $sw.Stop(); Set-Status complete done 0 'trained artifact 8x8 engine probe passed'
} catch { $sw.Stop(); Set-Status failed $_.Exception.Message 1 $_.Exception.Message; exit 1 }
finally {
  if(Test-Path -LiteralPath $runRoot){Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
