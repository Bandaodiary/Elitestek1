param(
    [switch]$Worker,
    [string]$RunId = '',
    [switch]$ReplicateAbortControl,
    [switch]$RegisterFatalTicket,
    [switch]$PreviewDisplay,
    [ValidateSet(0,1,2,3)][int]$SwapAbortCollision=0,
    [switch]$SwapErrorCollision,
    [ValidateSet(0,1,2,3)][int]$CaptureDisplayAlias=0,
    [switch]$CaptureGuardCancel,
    [ValidateSet(0,1,2,3,4,5,6)][int]$CaptureGuardPublish=0,
    [ValidateSet(0,1,2,3,4,5,6,7)][int]$InputRegionCase=0
)

$ErrorActionPreference = 'Stop'
if($InputRegionCase -and ($SwapAbortCollision -or $SwapErrorCollision -or $CaptureDisplayAlias -or $CaptureGuardCancel -or $CaptureGuardPublish)) {
    throw 'InputRegionCase must be run as an independent scenario'
}
if($CaptureGuardPublish -and ($SwapAbortCollision -or $SwapErrorCollision -or $CaptureDisplayAlias -or $CaptureGuardCancel)) {
    throw 'CaptureGuardPublish must be run as an independent scenario'
}
if(($CaptureDisplayAlias -or $CaptureGuardCancel) -and
   ($SwapAbortCollision -or $SwapErrorCollision -or ($CaptureDisplayAlias -and $CaptureGuardCancel))) {
    throw 'Capture guard modes cannot be combined with each other or swap collision modes'
}
if($SwapErrorCollision -and $SwapAbortCollision -notin @(2,3)) {
    throw 'SwapErrorCollision requires boundary mode 2 or 3'
}
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $replicateArg = if ($ReplicateAbortControl) { ' -ReplicateAbortControl' } else { '' }
    $ticketArg = if ($RegisterFatalTicket) { ' -RegisterFatalTicket' } else { '' }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
    $previewArg = if ($PreviewDisplay) { ' -PreviewDisplay' } else { '' }
    $errorArg = if ($SwapErrorCollision) { ' -SwapErrorCollision' } else { '' }
    $errorArg += ' -CaptureDisplayAlias ' + $CaptureDisplayAlias
    if($CaptureGuardCancel) {$errorArg += ' -CaptureGuardCancel'}
    $errorArg += ' -CaptureGuardPublish ' + $CaptureGuardPublish
    $errorArg += ' -InputRegionCase ' + $InputRegionCase
    $commandLine = '"' + $powerShell + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Worker -RunId ' + $RunId + $replicateArg + $ticketArg + $previewArg + $errorArg + ' -SwapAbortCollision ' + $SwapAbortCollision
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)"
    }
    [ordered]@{
        run_id=$RunId
        worker_pid=[int]$result.ProcessId
        status_path=(Join-Path $logRoot "soc_control_runs\$RunId\status.json")
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$runRoot = Join-Path $simRoot "soc_control_run_$RunId"
$runLogRoot = Join-Path $logRoot "soc_control_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'soc_control_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
if ((Test-Path -LiteralPath $runRoot) -or (Test-Path -LiteralPath $runLogRoot)) {
    throw 'RunId already exists; refusing to reuse or clean an existing run'
}
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Set-StatusContent {
    param([string]$Path,[string]$Value)
    for($attempt=0;$attempt -lt 20;$attempt++) {
        try { $Value | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop; return }
        catch [IO.IOException] { if($attempt -eq 19){throw}; Start-Sleep -Milliseconds 25 }
    }
}

function Write-Status {
    param([string]$State,[string]$Step,[int]$ExitCode,[string]$Message)
    $value=[ordered]@{
        run_id=$RunId; state=$State; step=$Step; exit_code=$ExitCode
        message=$Message; process_id=$PID
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
        updated=(Get-Date).ToString('o'); log_directory=$runLogRoot
    } | ConvertTo-Json
    Set-StatusContent $statusPath $value
    Set-StatusContent $latestStatusPath $value
}

function Invoke-XsimStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$ExpectedPass='')
    Write-Status running $Name 0 "starting $Name"
    $stdoutPath=Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath=Join-Path $runLogRoot "$Name.stderr.log"
    $process=Start-Process -FilePath $Tool -ArgumentList $Arguments -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if($process.ExitCode -ne 0){throw "$Name exit $($process.ExitCode)"}
    $stdout=Get-Content -Raw -LiteralPath $stdoutPath
    $stderr=Get-Content -Raw -LiteralPath $stderrPath
    $all=$stdout+[Environment]::NewLine+$stderr
    if(-not [string]::IsNullOrWhiteSpace($stderr)){throw "$Name unexpected stderr"}
    if($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened|\$\s*fatal'){
        throw "$Name log contains ERROR/FATAL/FAIL"
    }
    if($ExpectedPass) {
        $passCount=[regex]::Matches($all,[regex]::Escape($ExpectedPass)).Count
        if($passCount -ne 1){throw "$Name missing unique $ExpectedPass"}
    }
}

try {
    Write-Status running setup 0 'detached SoC control verification started'
    $xvlogArgs = @('-sv')
    if ($ReplicateAbortControl) {
        $xvlogArgs += @('-d', 'C1_REPLICATE_ABORT_CONTROL')
    }
    if ($RegisterFatalTicket) {
        $xvlogArgs += @('-d', 'C1_REGISTER_FATAL_TICKET')
    }
    $xvlogArgs += @(
        (Join-Path $rtlRoot 'control\c1_frame_manager.sv'),
        (Join-Path $rtlRoot 'control\c1_frame_triple_layout_check.sv'),
        (Join-Path $rtlRoot 'control\c1_frame_write_region_guard.sv'),
        (Join-Path $rtlRoot 'control\c1_frames_arena_check.sv'),
        (Join-Path $rtlRoot 'dma\c1_axi_shared_qos_monitor.sv'),
        (Join-Path $rtlRoot 'top\c1_r1_soc_control.sv'),
        (Join-Path $simRoot 'tb_c1_r1_soc_control.sv'))
    Invoke-XsimStep xvlog (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    $xelabArgs=@('tb_c1_r1_soc_control','-s','tb_c1_r1_soc_control_sim')
    if($PreviewDisplay -or $SwapAbortCollision) {
        $xelabArgs+=@('-generic_top','"DIFFERENT_RESOLVED_GEOMETRY=1"')
    }
    if($PreviewDisplay) { $xelabArgs+=@('-generic_top','"PREVIEW_DISPLAY=1"') }
    if($SwapAbortCollision) { $xelabArgs+=@('-generic_top',('"SWAP_ABORT_COLLISION='+$SwapAbortCollision+'"')) }
    if($SwapErrorCollision) { $xelabArgs+=@('-generic_top','"SWAP_ERROR_COLLISION=1"') }
    if($CaptureDisplayAlias) { $xelabArgs+=@('-generic_top',('"CAPTURE_DISPLAY_ALIAS='+$CaptureDisplayAlias+'"')) }
    if($CaptureGuardCancel) { $xelabArgs+=@('-generic_top','"CAPTURE_GUARD_CANCEL=1"') }
    if($CaptureGuardPublish) { $xelabArgs+=@('-generic_top',('"CAPTURE_GUARD_PUBLISH='+$CaptureGuardPublish+'"')) }
    if($InputRegionCase) { $xelabArgs+=@('-generic_top',('"INPUT_REGION_CASE='+$InputRegionCase+'"')) }
    Invoke-XsimStep xelab (Join-Path $vivadoBin 'xelab.bat') $xelabArgs
    $expectedPass=if($SwapAbortCollision -eq 3){'C1_SOC_PENDING_SWAP_ABORT_PASS'}elseif($SwapAbortCollision -eq 2){'C1_SOC_SECOND_SWAP_ABORT_PASS'}else{'C1_R1_SOC_CONTROL_PASS'}
    if($SwapErrorCollision) {
        $expectedPass=if($SwapAbortCollision -eq 3){'C1_SOC_PENDING_SWAP_ERROR_PASS'}else{'C1_SOC_COMMITTED_SWAP_ERROR_PASS'}
    }
    if($CaptureDisplayAlias) {$expectedPass='C1_CAPTURE_DISPLAY_ALIAS_GUARD_PASS'}
    if($CaptureGuardCancel) {$expectedPass='C1_CAPTURE_GUARD_CANCEL_PASS'}
    if($CaptureGuardPublish) {$expectedPass='C1_CAPTURE_GUARD_PUBLISH_PASS'}
    if($InputRegionCase) {$expectedPass='C1_INPUT_REGION_PASS'}
    Invoke-XsimStep xsim (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_r1_soc_control_sim','-runall') $expectedPass
    if($SwapAbortCollision -eq 1) {
        $collisionLines=@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -SimpleMatch 'C1_SOC_SWAP_ABORT_METADATA_PASS')
        if($collisionLines.Count -ne 1){ throw 'Missing unique first-swap collision coverage' }
    }
    $watch.Stop()
    Write-Status complete done 0 $expectedPass
} catch {
    $watch.Stop()
    Write-Status failed exception 1 $_.Exception.Message
    exit 1
} finally {
    # Only this newly allocated run directory may be removed. Keep small
    # tool logs/status outside it; never traverse an old run or workspace root.
    $cleanupTarget=[IO.Path]::GetFullPath($runRoot)
    $cleanupParent=[IO.Path]::GetFullPath($simRoot).TrimEnd('\')
    if([IO.Path]::GetDirectoryName($cleanupTarget) -ne $cleanupParent -or
       [IO.Path]::GetFileName($cleanupTarget) -ne ('soc_control_run_'+$RunId)) {
        throw 'Unsafe simulation cleanup target'
    }
    if(Test-Path -LiteralPath $cleanupTarget) {
        Remove-Item -LiteralPath $cleanupTarget -Recurse -Force
    }
}
