param(
    [switch]$Worker,
    [string]$RunId = ''
)

# Detached Vivado proxy synthesis for the row-tag/refill control shell.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'
if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $statusPath = Join-Path $logRoot "window_line_cache_ctrl_proxy_synth_runs\$RunId\status.json"
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "`"$powerShell`" -NoLogo -NoProfile -NonInteractive " +
        "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
        "-Worker -RunId $RunId"
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $caseRoot }
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed with return value $($result.ReturnValue)" }
    [ordered]@{ run_id=$RunId; worker_pid=[int]$result.ProcessId; status_path=$statusPath } | ConvertTo-Json
    exit 0
}
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'RunId contains unsupported characters' }
$runRoot = Join-Path $simRoot "window_line_cache_ctrl_proxy_synth_$RunId"
$runLogRoot = Join-Path $logRoot "window_line_cache_ctrl_proxy_synth_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'window_line_cache_ctrl_proxy_synth_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$script:currentStep='setup'; $script:watch=[Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null
function Set-StatusContent { param([string]$Path,[string]$Value)
    for($i=0;$i -lt 20;$i++){try{$Value|Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop;return}catch [IO.IOException]{if($i -eq 19){throw};Start-Sleep -Milliseconds 25}} }
function Write-Status { param([string]$State,[string]$Step,[int]$ExitCode,[string]$Message)
    $s=[ordered]@{run_id=$RunId;state=$State;step=$Step;exit_code=$ExitCode;message=$Message;process_id=$PID;elapsed_seconds=[math]::Round($script:watch.Elapsed.TotalSeconds,3);updated=(Get-Date).ToString('o');log_directory=$runLogRoot;run_directory=$runRoot}|ConvertTo-Json
    Set-StatusContent $statusPath $s; Set-StatusContent $latestStatusPath $s }
try {
    Write-Status 'running' 'vivado' 0 'starting detached window line cache proxy synth'
    # Make the Vivado runtime roots visible to the child and to any helper
    # process launched by synth_design.  WMI-created workers do not always
    # inherit the interactive settings64 environment.
    $env:XILINX_VIVADO = 'D:\vivado\vivado\Vivado\2023.1'
    $env:RDI_APPROOT = $env:XILINX_VIVADO
    $env:RDI_PATCHROOT = Join-Path $caseRoot '.vivado_rt'
    $env:XILINX_PATH = $env:RDI_PATCHROOT
    $stageData = Join-Path $env:RDI_PATCHROOT 'scripts\rt\data'
    $stageFpgaTcl = Join-Path $env:RDI_PATCHROOT 'scripts\rt\fpga_tcl'
    $stageSentinel = Join-Path $stageData 'unimacro\unimacro_verilog.tcl'
    New-Item -ItemType Directory -Force -Path $stageData,$stageFpgaTcl | Out-Null
    # Copy on every run, even when the stage already exists.  Reading each
    # source also hydrates any cloud-placeholder runtime file immediately
    # before Vivado launches its helper process.
    Copy-Item -Path (Join-Path $env:XILINX_VIVADO 'scripts\rt\data\*') `
        -Destination $stageData -Recurse -Force
    Copy-Item -Path (Join-Path $env:XILINX_VIVADO 'scripts\rt\fpga_tcl\*') `
        -Destination $stageFpgaTcl -Recurse -Force
    if (-not (Test-Path -LiteralPath $stageSentinel)) {
        throw 'Vivado runtime stage sentinel was not copied'
    }
    # Some local installations expose runtime Tcl files as cloud-pinned
    # placeholders.  Vivado's detached synthesis helper can fail to open
    # those files even though the parent process can.  The workspace stage is
    # generated data; normalize its file attributes before launching Vivado.
    Get-ChildItem -LiteralPath $env:RDI_PATCHROOT -Recurse -File |
        ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
    $env:RT_LIBPATH = Join-Path $env:XILINX_VIVADO 'scripts\rt\data'
    $env:SYNTH_COMMON = $env:RT_LIBPATH
    $env:RT_TCL_PATH = Join-Path $env:XILINX_VIVADO 'scripts\rt\base_tcl\tcl'
    $stdoutPath=Join-Path $runLogRoot 'vivado.stdout.log'; $stderrPath=Join-Path $runLogRoot 'vivado.stderr.log'
    $p=Start-Process -FilePath (Join-Path $vivadoBin 'vivado.bat') -ArgumentList @('-mode','batch','-nojournal','-nolog','-notrace','-source',(Join-Path $caseRoot 'scripts\synth_window_line_cache_ctrl_proxy.tcl')) -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if($p.ExitCode -ne 0){throw "Vivado failed with exit code $($p.ExitCode)"}
    $o=Get-Content -Raw -LiteralPath $stdoutPath; $e=Get-Content -Raw -LiteralPath $stderrPath
    if(($o+"`n"+$e)-match '(?im)(^|\s)(Fatal|Error):|\bFAIL\b|cannot be opened'){throw 'Vivado reported Fatal/Error/FAIL'}
    if(-not [string]::IsNullOrWhiteSpace($e)){throw 'Vivado wrote diagnostics to stderr'}
    if([regex]::Matches($o,'C1_WINDOW_LINE_CACHE_CTRL_PROXY_SYNTH_PASS').Count -ne 1){throw 'proxy synth marker missing or duplicated'}
    $script:watch.Stop(); Write-Status 'complete' 'done' 0 'C1_WINDOW_LINE_CACHE_CTRL_PROXY_SYNTH_PASS'
} catch { $script:watch.Stop(); Write-Status 'failed' $script:currentStep 1 $_.Exception.Message; exit 1 }
