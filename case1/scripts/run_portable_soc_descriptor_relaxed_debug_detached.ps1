param([switch]$Worker, [string]$RunId = '')
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs'
if (-not $Worker) {
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed with return value $($result.ReturnValue)" }
    [ordered]@{run_id=$RunId;worker_pid=[int]$result.ProcessId;status_path=(Join-Path $logRoot "portable_soc_descriptor_relaxed_debug_runs\$RunId\status.json")} | ConvertTo-Json
    return
}
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
$runRoot = Join-Path $caseRoot "sim\portable_soc_descriptor_relaxed_debug_run_$RunId"
$runLogRoot = Join-Path $logRoot "portable_soc_descriptor_relaxed_debug_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$vivado = 'D:\vivado\vivado\Vivado\2023.1\bin\vivado.bat'
$vivadoRtScripts = 'D:\vivado\vivado\Vivado\2023.1\scripts\rt'
$tcl = Join-Path $PSScriptRoot 'synth_portable_soc_descriptor_relaxed_debug.tcl'
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null
try {
    # Pre-read the runtime scripts so the detached Vivado helper does not
    # inherit a partially initialized rtSynthParallelPrep interpreter.
    $buf=New-Object byte[] 65536
    Get-ChildItem -LiteralPath $vivadoRtScripts -Filter '*.tcl' -File -Recurse | ForEach-Object {$s=[IO.File]::OpenRead($_.FullName);while($s.Read($buf,0,$buf.Length)-gt 0){};$s.Dispose()}
    $s=[IO.File]::OpenRead((Join-Path $vivadoRtScripts 'fpga_tcl\rtSynthParallelPrep.tcl'));while($s.Read($buf,0,$buf.Length)-gt 0){};$s.Dispose()
    $out=Join-Path $runLogRoot 'vivado.stdout.log'; $err=Join-Path $runLogRoot 'vivado.stderr.log'
    $p=Start-Process -FilePath $vivado -ArgumentList @('-mode','batch','-source',$tcl,'-notrace') -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $state = if($p.ExitCode -eq 0){'complete'}else{'failed'}
    [ordered]@{run_id=$RunId;state=$state;exit_code=$p.ExitCode;process_id=$PID;log_directory=$runLogRoot;run_directory=$runRoot} | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
    if($p.ExitCode -ne 0){exit 1}
} catch {
    [ordered]@{run_id=$RunId;state='failed';exit_code=1;message=$_.Exception.Message;process_id=$PID;log_directory=$runLogRoot;run_directory=$runRoot} | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
    exit 1
}
