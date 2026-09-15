# This script deliberately creates the worker through the Windows WMI
# service. Vivado/xsim therefore do not remain children of the Codex shell's
# Windows Job object. If the interactive session is interrupted, the worker
# continues and records its final state in logs/xsim_status.json.

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$worker = (Resolve-Path (Join-Path $PSScriptRoot 'xsim_worker.ps1')).Path
$runId = [guid]::NewGuid().ToString('N')
$statusPath = Join-Path $caseRoot "logs\xsim_runs\$runId\status.json"
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
    status_path = $statusPath
} | ConvertTo-Json
