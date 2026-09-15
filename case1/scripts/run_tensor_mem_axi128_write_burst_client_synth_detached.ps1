param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Detached Vivado synthesis worker.  The private run tree (including reports)
# is deleted after completion; only compact status and logs remain.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs\tensor_mem_axi128_write_burst_client_synth_runs'
$scriptFile = Join-Path $caseRoot 'scripts\synth_tensor_mem_axi128_write_burst_client.tcl'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $statusPath = Join-Path $logRoot "$RunId\status.json"
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd = "`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
           "-WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $cmd; CurrentDirectory = $caseRoot }
    if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($r.ReturnValue)" }
    [ordered]@{ run_id = $RunId; worker_pid = [int]$r.ProcessId;
                status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $caseRoot ".tmp_tensor_mem_axi128_write_burst_synth_$RunId"
$runLog = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLog 'status.json'
$latestPath = Join-Path $logRoot 'latest_status.json'
New-Item -ItemType Directory -Force -Path $runRoot, $runLog | Out-Null

function Write-Status([string]$State, [string]$Step, [int]$Code,
                      [string]$Message) {
    $j = ([ordered]@{ run_id = $RunId; state = $State; step = $Step;
        exit_code = $Code; message = $Message;
        updated = (Get-Date).ToString('o') } | ConvertTo-Json)
    $j | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $j | Set-Content -LiteralPath $latestPath -Encoding UTF8
}

try {
    Write-Status 'running' 'vivado' 0 'detached synthesis worker started'
    $out = Join-Path $runLog 'vivado.stdout.log'
    $err = Join-Path $runLog 'vivado.stderr.log'
    $args = @('-mode', 'batch', '-nolog', '-notrace', '-source', $scriptFile)
    $p = Start-Process -FilePath (Join-Path $vivadoBin 'vivado.bat') `
        -ArgumentList $args -WorkingDirectory $runRoot -WindowStyle Hidden `
        -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if ($p.ExitCode -ne 0) { throw "Vivado exit code $($p.ExitCode)" }
    $txt = (Get-Content -Raw -LiteralPath $out) + "`n" +
           (Get-Content -Raw -LiteralPath $err)
    if ($txt -match '(?im)(Fatal|Error):|\bFAIL\b|cannot be opened') {
        throw 'Vivado reported failure'
    }
    $marker = 'C1_TENSOR_MEM_AXI128_WRITE_BURST_CLIENT_SYNTH_PASS'
    if ([regex]::Matches($txt, [regex]::Escape($marker)).Count -ne 1) {
        throw 'synthesis marker missing or duplicated'
    }
    Write-Status 'complete' 'done' 0 'synthesis passed'
} catch {
    Write-Status 'failed' 'vivado' 1 $_.Exception.Message
    exit 1
} finally {
    # Preserve only the compact text reports for review; discard Vivado's
    # private project/run tree below.
    $reportSrc = Join-Path $runRoot 'reports'
    if (Test-Path -LiteralPath $reportSrc) {
        Get-ChildItem -LiteralPath $reportSrc -File -ErrorAction SilentlyContinue |
            Copy-Item -Destination $runLog -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
