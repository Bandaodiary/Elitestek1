param([switch]$Worker, [string]$RunId = '', [switch]$CompileOnly,
      [switch]$ResponseFifo)

# Keep Vivado/xsim outside the desktop agent's Windows Job.  The outer
# process is created with Win32_Process.Create, matching the long-running
# Case-1 portable-SoC runner contract.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = '"' + $powerShell +
        '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass' +
        ' -WindowStyle Hidden -File "' + $PSCommandPath +
        '" -Worker -RunId ' + $RunId +
        $(if($CompileOnly){' -CompileOnly'}else{''}) +
        $(if($ResponseFifo){' -ResponseFifo'}else{''})
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
    if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }
    [ordered]@{ run_id=$RunId; worker_pid=[int]$result.ProcessId;
        status_path=(Join-Path $logRoot "native_display_prefetch_runs\$RunId\status.json") } |
        ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $simRoot "native_display_prefetch_run_$RunId"
$runLogRoot = Join-Path $logRoot "native_display_prefetch_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'native_display_prefetch_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew(); $script:currentStep='setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Set-StatusContent([string]$Path,[string]$Value) {
    $Value | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Write-Status([string]$State,[string]$Step,[int]$ExitCode,[string]$Message) {
    $value=[ordered]@{run_id=$RunId;frame='640x480';state=$State;step=$Step;
        exit_code=$ExitCode;message=$Message;process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        updated=(Get-Date).ToString('o');log_directory=$runLogRoot;
        run_directory=$runRoot} | ConvertTo-Json
    Set-StatusContent $statusPath $value
    Set-StatusContent $latestStatusPath $value
}
function Invoke-XsimStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$ExpectedPass='')
    $script:currentStep=$Name; Write-Status running $Name 0 "starting $Name"
    $out=Join-Path $runLogRoot "$Name.stdout.log"
    $err=Join-Path $runLogRoot "$Name.stderr.log"
    $p=Start-Process -FilePath $Tool -ArgumentList $Arguments -WorkingDirectory $runRoot `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if($p.ExitCode -ne 0){throw "$Name exit $($p.ExitCode)"}
    $stdout=Get-Content -Raw -LiteralPath $out
    $stderr=Get-Content -Raw -LiteralPath $err
    $all=$stdout+[Environment]::NewLine+$stderr
    if(-not [string]::IsNullOrWhiteSpace($stderr)){throw "$Name unexpected stderr"}
    if($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|_[Ff][Aa][Ii][Ll]\b|cannot be opened|\$\s*fatal'){
        throw "$Name log contains ERROR/FATAL/FAIL"
    }
    if($ExpectedPass){
        $n=[regex]::Matches($all,[regex]::Escape($ExpectedPass)).Count
        if($n -ne 1){throw "$Name missing unique marker count=$n"}
    }
}

try {
    Write-Status running setup 0 'detached native display prefetch preflight started'
    $packageSources=@(
        (Join-Path $rtlRoot 'common\c1_fixed_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_decoder_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_frame_buffer_pkg.sv'))
    $packageSet=@{}; foreach($s in $packageSources){$packageSet[$s]=$true}
    $remaining=Get-ChildItem -LiteralPath $rtlRoot -Recurse -File -Filter '*.sv' |
        Where-Object {-not $packageSet.ContainsKey($_.FullName)} |
        Sort-Object FullName | Select-Object -ExpandProperty FullName
    $sources=@($packageSources)+@($remaining)+@((Join-Path $simRoot 'tb_c1_r1_native_display_prefetch.sv'))
    $xvlogArgs=@('-sv')
    if($ResponseFifo){$xvlogArgs += @('-d','C1_DISPLAY_RESPONSE_FIFO')}
    # Avoid cmd.exe's command-line length limit as the RTL tree grows.
    $sourceListPath = Join-Path $runRoot 'xvlog_sources.f'
    $sources | Set-Content -LiteralPath $sourceListPath -Encoding ASCII
    $xvlogArgs += @('-f',$sourceListPath)
    Invoke-XsimStep xvlog (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    Invoke-XsimStep xelab (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_r1_native_display_prefetch','-s','tb_c1_r1_native_display_prefetch_sim')
    if ($CompileOnly) {
        $watch.Stop()
        Write-Status complete elaboration 0 'C1_R1_NATIVE_DISPLAY_PREFETCH_ELAB_PASS frame=640x480'
        return
    }
    Invoke-XsimStep xsim (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_r1_native_display_prefetch_sim','-runall') `
        'C1_R1_NATIVE_DISPLAY_PREFETCH_PASS'
    $watch.Stop()
    Write-Status complete done 0 'C1_R1_NATIVE_DISPLAY_PREFETCH_PASS frame=640x480'
} catch {
    $watch.Stop()
    Write-Status failed $script:currentStep 1 $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $runRoot -PathType Container) {
        $resolvedRun = (Resolve-Path -LiteralPath $runRoot).Path
        $resolvedSim = (Resolve-Path -LiteralPath $simRoot).Path
        if ((Split-Path -Parent $resolvedRun) -ne $resolvedSim -or
            (Split-Path -Leaf $resolvedRun) -notmatch '^native_display_prefetch_run_[A-Za-z0-9_-]+$') {
            throw "Refusing unsafe native display cleanup: $resolvedRun"
        }
        Remove-Item -LiteralPath $resolvedRun -Recurse -Force
    }
}
