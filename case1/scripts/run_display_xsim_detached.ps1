param(
    [switch]$Worker,
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptPath = $PSCommandPath

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }

    $statusPath = Join-Path $caseRoot "logs\display_xsim_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
                   "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" " +
                   "-Worker -RunId $RunId"

    # WMI creates the worker outside the caller's Windows Job object.  This
    # keeps xvlog/xelab/xsim alive if the interactive Codex shell is stopped.
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
        status_path = $statusPath
    } | ConvertTo-Json
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RunId)) {
    throw 'Worker mode requires -RunId'
}

$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
$runRoot = Join-Path $simRoot "display_xsim_run_$RunId"
$runLogRoot = Join-Path $logRoot "display_xsim_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_display_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'

New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status {
    param(
        [string]$State,
        [string]$Step,
        [int]$ExitCode,
        [string]$Message
    )
    $status = [ordered]@{
        run_id = $RunId
        state = $State
        step = $Step
        exit_code = $ExitCode
        message = $Message
        process_id = $PID
        updated = (Get-Date).ToString('o')
        log_directory = $runLogRoot
    } | ConvertTo-Json
    $status | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $status | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-VivadoStep {
    param(
        [string]$Name,
        [string]$Tool,
        [string[]]$Arguments,
        [string]$ExpectedPass = ''
    )
    Write-Status -State 'running' -Step $Name -ExitCode 0 -Message "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)"
    }
    if ($ExpectedPass) {
        $stdout = Get-Content -Raw -LiteralPath $stdoutPath
        if ($stdout -match '(?im)(^|\s)(Fatal|Error):|cannot be opened') {
            throw "$Name reported a simulation fatal/error; inspect $stdoutPath"
        }
        if ($stdout -notmatch [regex]::Escape($ExpectedPass)) {
            throw "$Name did not emit required marker $ExpectedPass"
        }
    }
}

try {
    Write-Status -State 'running' -Step 'setup' -ExitCode 0 `
        -Message 'detached display verification worker started'

    Invoke-VivadoStep -Name 'xvlog' -Tool (Join-Path $vivadoBin 'xvlog.bat') `
        -Arguments @(
            '-sv',
            (Join-Path $rtlRoot 'display\c1_video_timing_720p.sv'),
            (Join-Path $rtlRoot 'display\c1_split_compositor.sv'),
            (Join-Path $simRoot 'tb_c1_split_compositor.sv'),
            (Join-Path $simRoot 'tb_c1_compositor_modes.sv')
        )
    Invoke-VivadoStep -Name 'xelab' -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @('tb_c1_split_compositor', '-s', 'tb_c1_split_compositor_sim')
    Invoke-VivadoStep -Name 'xsim' -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_split_compositor_sim', '-runall') `
        -ExpectedPass 'C1_SPLIT_COMPOSITOR_PASS'
    Invoke-VivadoStep -Name 'xelab_modes' -Tool (Join-Path $vivadoBin 'xelab.bat') `
        -Arguments @('tb_c1_compositor_modes', '-s', 'tb_c1_compositor_modes_sim')
    Invoke-VivadoStep -Name 'xsim_modes' -Tool (Join-Path $vivadoBin 'xsim.bat') `
        -Arguments @('tb_c1_compositor_modes_sim', '-runall') `
        -ExpectedPass 'C1_COMPOSITOR_MODES_PASS'

    Write-Status -State 'complete' -Step 'done' -ExitCode 0 `
        -Message 'C1 display xsim verification complete'
} catch {
    Write-Status -State 'failed' -Step 'exception' -ExitCode 1 `
        -Message $_.Exception.Message
    exit 1
}
