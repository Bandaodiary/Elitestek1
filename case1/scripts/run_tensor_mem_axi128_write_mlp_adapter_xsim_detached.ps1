param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$AwBeforePayload,
    [switch]$RspPopRefill
)

# Detached xsim runner for the logical-write packer + burst-level MLP seam.
# Win32_Process.Create keeps Vivado/xsim outside the caller's Windows Job;
# the private run tree is deleted on completion.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "xsim_runs\tensor_write_mlp_adapter\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId" +
        $(if ($AwBeforePayload) { ' -AwBeforePayload' } else { '' }) +
        $(if ($RspPopRefill) { ' -RspPopRefill' } else { '' })
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{ run_id = $RunId; worker_pid = [int]$result.ProcessId;
                status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
$runRoot = Join-Path $simRoot "xsim_run_tensor_write_mlp_adapter_$RunId"
$runLogRoot = Join-Path $logRoot "xsim_runs\tensor_write_mlp_adapter\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'xsim_tensor_write_mlp_adapter_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:step = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot, $runLogRoot | Out-Null

function Write-Status([string]$State, [string]$Step, [int]$ExitCode,
                       [string]$Message) {
    $obj = [ordered]@{
        run_id = $RunId; state = $State; step = $Step; exit_code = $ExitCode
        message = $Message; process_id = $PID
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        log_directory = $runLogRoot; run_directory = $runRoot
    } | ConvertTo-Json
    $obj | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $obj | Set-Content -LiteralPath $latestStatusPath -Encoding UTF8
}

function Invoke-Step([string]$Name, [string]$Tool, [string[]]$ToolArgs,
                      [string]$Marker = '') {
    $script:step = $Name
    Write-Status 'running' $Name 0 "starting $Name"
    $out = Join-Path $runLogRoot "$Name.stdout.log"
    $err = Join-Path $runLogRoot "$Name.stderr.log"
    $proc = Start-Process -FilePath $Tool -ArgumentList $ToolArgs -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if ($null -eq $proc -or $proc.ExitCode -ne 0) { throw "$Name exit code $($proc.ExitCode)" }
    $all = (Get-Content -Raw -LiteralPath $out) + "`n" + (Get-Content -Raw -LiteralPath $err)
    if ($all -match '(?im)(^|\s)(Fatal|Error):|\$fatal|_FAIL') { throw "$Name reported failure" }
    if ($Marker -and ([regex]::Matches($all, [regex]::Escape($Marker)).Count -ne 1)) {
        throw "$Name did not emit exactly one $Marker"
    }
}

try {
    $xvlogArgs = @('-sv', '-nolog')
    if ($AwBeforePayload) {
        $xvlogArgs += @('-d', 'C1_ADAPTER_ISSUE_AW_BEFORE_PAYLOAD_TB')
    }
    if ($RspPopRefill) {
        $xvlogArgs += @('-d', 'C1_ADAPTER_RSP_POP_REFILL_TB')
    }
    $xvlogArgs += @(
        (Join-Path $rtlRoot 'dma\c1_axi128_write_mlp.sv'),
        (Join-Path $rtlRoot 'dma\c1_tensor_mem_axi128_write_mlp_adapter.sv'),
        (Join-Path $simRoot 'tb_c1_tensor_mem_axi128_write_mlp_adapter.sv'))
    Write-Status 'running' 'setup' 0 $(if ($AwBeforePayload) {
        'detached logical-write MLP adapter AW-before-payload worker started'
    } else {
        'detached logical-write MLP adapter worker started'
    })
    Invoke-Step 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    Invoke-Step 'xelab' (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_tensor_mem_axi128_write_mlp_adapter', '-s',
        'tb_c1_tensor_mem_axi128_write_mlp_adapter_sim', '-nolog')
    Invoke-Step 'xsim' (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_tensor_mem_axi128_write_mlp_adapter_sim', '-runall', '-nolog') `
        'C1_TENSOR_MEM_AXI128_WRITE_MLP_ADAPTER_PASS'
    $watch.Stop()
    Write-Status 'complete' 'done' 0 'C1_TENSOR_MEM_AXI128_WRITE_MLP_ADAPTER_PASS'
} catch {
    $watch.Stop()
    Write-Status 'failed' $script:step 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
