param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$RegisteredErrorFlush
)

# The non-worker invocation only asks WMI to create a detached PowerShell
# process.  Vivado/xvlog/xelab/xsim are therefore children of that worker, not
# children of the Codex Windows Job.  This follows the same process-isolation
# rule as the longer Case-1 regressions.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlFile = Join-Path $caseRoot 'rtl\common\c1_r1_unified_output_fifo.sv'
$tbFile = Join-Path $caseRoot 'sim\tb_c1_r1_unified_output_fifo.sv'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$logRoot = Join-Path $caseRoot 'logs\unified_output_fifo_runs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    } elseif ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'RunId contains unsupported characters'
    }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId" +
        $(if($RegisteredErrorFlush){' -RegisteredErrorFlush'}else{''})
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine
        CurrentDirectory = $caseRoot
    }
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = [int]$result.ProcessId
        log_directory = (Join-Path $logRoot $RunId)
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId contains unsupported characters'
}

$runRoot = Join-Path $caseRoot "sim\xsim_unified_output_fifo_run_$RunId"
$runLogRoot = Join-Path $logRoot $RunId
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Invoke-VivadoStep {
    param(
        [string]$Name,
        [string]$Tool,
        [string[]]$Arguments
    )
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)"
    }
}

try {
    Invoke-VivadoStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments (@('-sv') + $(if($RegisteredErrorFlush){@('-d','C1_UNIFIED_FIFO_REGISTERED_ERROR')}else{@()}) + @($rtlFile,$tbFile))
    Invoke-VivadoStep -Name 'xelab' -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @('tb_c1_r1_unified_output_fifo', '-s',
                     'tb_c1_r1_unified_output_fifo_sim')
    Invoke-VivadoStep -Name 'xsim' -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_r1_unified_output_fifo_sim', '-runall')

    $stdout = Get-Content -Raw -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log')
    $stderr = Get-Content -Raw -LiteralPath (Join-Path $runLogRoot 'xsim.stderr.log')
    $diagnostics = $stdout + "`n" + $stderr
    if ($diagnostics -notmatch 'C1_R1_UNIFIED_OUTPUT_FIFO_PASS depth=2 payload=103') {
        throw 'xsim did not emit the required unified FIFO PASS marker'
    }
    if ($diagnostics -match '(?im)(^|\s)(Fatal|Error):|\$fatal') {
        throw 'xsim reported Fatal/Error; inspect the detached logs'
    }
    "C1_R1_UNIFIED_OUTPUT_FIFO_DETACHED_PASS run_id=$RunId log=$runLogRoot"
    exit 0
} catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $runLogRoot 'failure.txt')
    Write-Error $_
    exit 1
}
