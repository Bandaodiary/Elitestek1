param(
    [Parameter(Mandatory = $true)]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs'
$runRoot = Join-Path $caseRoot 'sim\synth_proxy_run'
$statusPath = Join-Path $logRoot 'synth_status.json'
$vivado = 'D:\vivado\vivado\Vivado\2023.1\bin\vivado.bat'
$tcl = Join-Path $PSScriptRoot 'synth_proxy.tcl'
New-Item -ItemType Directory -Force -Path $logRoot, $runRoot | Out-Null

function Write-Status {
    param([string]$State, [int]$ExitCode, [string]$Message)
    [ordered]@{
        run_id = $RunId
        state = $State
        exit_code = $ExitCode
        message = $Message
        process_id = $PID
        updated = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

try {
    Write-Status -State 'running' -ExitCode 0 -Message 'proxy synthesis started'
    $process = Start-Process -FilePath $vivado `
        -ArgumentList @('-mode', 'batch', '-source', $tcl, '-notrace') `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $logRoot 'vivado_proxy_synth.stdout.log') `
        -RedirectStandardError (Join-Path $logRoot 'vivado_proxy_synth.stderr.log')
    if ($process.ExitCode -ne 0) {
        throw "Vivado proxy synthesis failed with exit code $($process.ExitCode)"
    }
    $synthLog = Get-Content -Raw -LiteralPath (Join-Path $logRoot 'vivado_proxy_synth.stdout.log')
    if ($synthLog -notmatch 'C1_PROXY_SYNTH_PASS') {
        throw 'Vivado proxy synthesis did not emit C1_PROXY_SYNTH_PASS'
    }
    if ($synthLog -match '(?im)^ERROR:') {
        throw 'Vivado proxy synthesis log contains ERROR diagnostics'
    }
    Write-Status -State 'complete' -ExitCode 0 -Message 'proxy synthesis complete'
} catch {
    Write-Status -State 'failed' -ExitCode 1 -Message $_.Exception.Message
    exit 1
}
