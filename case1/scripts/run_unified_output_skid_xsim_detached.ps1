param([switch]$Worker,[string]$RunId='',[switch]$RegisteredErrorFlush)
$ErrorActionPreference='Stop'; $caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtl=Join-Path $caseRoot 'rtl\common\c1_r1_unified_output_skid.sv'; $tb=Join-Path $caseRoot 'sim\tb_c1_r1_unified_output_skid.sv'
$vb='D:\vivado\vivado\Vivado\2023.1\bin'; $logs=Join-Path $caseRoot 'logs\unified_output_skid_runs'
if(!$Worker){if(!$RunId){$RunId=[guid]::NewGuid().ToString('N')}; if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'bad RunId'}
 $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"; $cl="`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"+$(if($RegisteredErrorFlush){' -RegisteredErrorFlush'}else{''})
 $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cl;CurrentDirectory=$caseRoot}; if($r.ReturnValue -ne 0){throw 'detached create failed'}
 [ordered]@{run_id=$RunId;worker_pid=[int]$r.ProcessId;log_directory=(Join-Path $logs $RunId)}|ConvertTo-Json; return }
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'bad RunId'}
$run=Join-Path $caseRoot "sim\xsim_unified_output_skid_run_$RunId"; $log=Join-Path $logs $RunId; New-Item -ItemType Directory -Force -Path $run,$log|Out-Null
function Step($n,$tool,[string[]]$a){
 $out=Join-Path $log "$n.stdout.log"; $err=Join-Path $log "$n.stderr.log"
 $p=Start-Process $tool -ArgumentList $a -WorkingDirectory $run -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
 if($p.ExitCode){throw "$n failed with exit code $($p.ExitCode)"}
 $s=(Get-Content -Raw $out)+(Get-Content -Raw $err)
 if($s -match '(?im)^\s*(ERROR|FATAL):|\$fatal|\bFAIL\b'){throw "$n emitted an error/failure diagnostic"}
}
try {
 Step xvlog (Join-Path $vb 'xvlog.bat') (@('-sv')+$(if($RegisteredErrorFlush){@('-d','C1_UNIFIED_SKID_REGISTERED_ERROR')}else{@()})+@($rtl,$tb))
 Step xelab (Join-Path $vb 'xelab.bat') @('tb_c1_r1_unified_output_skid','-s','tb_c1_r1_unified_output_skid_sim')
 Step xsim (Join-Path $vb 'xsim.bat') @('tb_c1_r1_unified_output_skid_sim','-runall')
 $d=(Get-Content -Raw (Join-Path $log 'xsim.stdout.log'))+(Get-Content -Raw (Join-Path $log 'xsim.stderr.log'))
 if($d -notmatch 'C1_R1_UNIFIED_OUTPUT_SKID_PASS depth=1 payload=103'){throw 'missing PASS marker'}
 'C1_R1_UNIFIED_OUTPUT_SKID_DETACHED_PASS run_id='+$RunId+' log='+$log
} catch {$_|Out-String|Set-Content (Join-Path $log 'failure.txt');throw}
