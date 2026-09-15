# Start proxy synthesis through WMI so Vivado is outside the caller's Windows
# Job object and can finish even if the interactive Codex session is interrupted.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$worker = (Resolve-Path (Join-Path $PSScriptRoot 'vivado_synth_worker.ps1')).Path
$runId = [guid]::NewGuid().ToString('N')
$powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$worker`" -RunId $runId"
$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = $commandLine
    CurrentDirectory = $caseRoot
}
if ($result.ReturnValue -ne 0) {
    throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
}
[ordered]@{
    run_id = $runId
    worker_pid = [int]$result.ProcessId
    status_path = (Join-Path $caseRoot 'logs\synth_status.json')
} | ConvertTo-Json

