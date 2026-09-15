param([switch]$Worker, [string]$RunId = '', [switch]$PackedAffine)

# WMI-detached structural smoke for ENABLE_TENSOR_WINDOW_CACHE=1.  The worker
# and all Vivado/xsim descendants live outside the caller's Windows Job.
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$logRoot = Join-Path $caseRoot 'logs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = '"' + $powerShell +
        '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass' +
        ' -WindowStyle Hidden -File "' + $PSCommandPath +
        '" -Worker -RunId ' + $RunId
    if ($PackedAffine) { $commandLine += ' -PackedAffine' }
    $workerPid = $null
    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
        if ($result.ReturnValue -eq 0) { $workerPid = [int]$result.ProcessId }
    } catch {
        # Win32_Process.Create is denied in some managed desktop jobs.  Use
        # the native breakaway helper so Vivado/xsim remains outside the job.
    }
    if ($null -eq $workerPid) {
        $helper = Join-Path $caseRoot 'scripts\start_detached_process.ps1'
        if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
            throw 'detached process helper is missing'
        }
        $workerPid = [int](& powershell.exe -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $helper -CommandLine $commandLine `
            -CurrentDirectory $caseRoot)
    }
    [ordered]@{
        run_id = $RunId
        worker_pid = $workerPid
        status_path = Join-Path $logRoot `
            "portable_soc_cache_wiring_smoke_runs\$RunId\status.json"
    } | ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $simRoot "portable_soc_cache_wiring_smoke_run_$RunId"
$runLogRoot = Join-Path $logRoot `
    "portable_soc_cache_wiring_smoke_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot `
    'portable_soc_cache_wiring_smoke_status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew()
$script:currentStep = 'setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Set-StatusContent {
    param([string]$Path,[string]$Value)
    for($attempt=0; $attempt -lt 20; $attempt++) {
        try {
            $Value | Set-Content -LiteralPath $Path -Encoding UTF8 `
                -ErrorAction Stop
            return
        } catch [IO.IOException] {
            if($attempt -eq 19) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Write-Status {
    param([string]$State,[string]$Step,[int]$ExitCode,[string]$Message)
    $value = [ordered]@{
        run_id=$RunId; state=$State; step=$Step; exit_code=$ExitCode
        message=$Message; process_id=$PID
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
        updated=(Get-Date).ToString('o'); log_directory=$runLogRoot
        run_directory=$runRoot
    } | ConvertTo-Json
    Set-StatusContent $statusPath $value
    Set-StatusContent $latestStatusPath $value
}

function Invoke-XsimStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,
          [string]$ExpectedPass='')
    $script:currentStep = $Name
    Write-Status running $Name 0 "starting $Name"
    $stdoutPath = Join-Path $runLogRoot "$Name.stdout.log"
    $stderrPath = Join-Path $runLogRoot "$Name.stderr.log"
    $process = Start-Process -FilePath $Tool -ArgumentList $Arguments `
        -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if($process.ExitCode -ne 0) { throw "$Name exit $($process.ExitCode)" }
    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    $all = $stdout + [Environment]::NewLine + $stderr
    if(-not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "$Name unexpected stderr"
    }
    if($all -match '(?im)^\s*(ERROR|FATAL):|\bFAIL\b|cannot be opened|\$\s*fatal') {
        throw "$Name log contains ERROR/FATAL/FAIL"
    }
    if($ExpectedPass) {
        $passCount = [regex]::Matches(
            $all,[regex]::Escape($ExpectedPass)).Count
        if($passCount -ne 1) {
            throw "$Name missing unique $ExpectedPass (count=$passCount)"
        }
    }
}

try {
    Write-Status running setup 0 `
        'detached cache-enabled portable SoC smoke started'

    $packageSources = @(
        (Join-Path $rtlRoot 'common\c1_fixed_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_decoder_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_frame_buffer_pkg.sv')
    )
    $packageSet = @{}
    foreach($source in $packageSources) { $packageSet[$source] = $true }
    $remainingSources = Get-ChildItem -LiteralPath $rtlRoot -Recurse `
        -File -Filter '*.sv' | Where-Object {
            -not $packageSet.ContainsKey($_.FullName)
        } | Sort-Object FullName | Select-Object -ExpandProperty FullName
    $sources = @($packageSources) + @($remainingSources) + @(
        (Join-Path $simRoot 'tb_c1_r1_portable_soc_cache_wiring_smoke.sv'))

    # The complete source set can exceed Windows' command-line length limit.
    # Use an xvlog response file in the disposable runRoot instead of passing
    # hundreds of absolute paths as individual arguments.
    $sourceList = Join-Path $runRoot 'xvlog_sources.f'
    # ASCII avoids a UTF-8 BOM being interpreted as part of the first source
    # path by xvlog (which would silently skip c1_fixed_pkg.sv).
    $sources | Set-Content -LiteralPath $sourceList -Encoding ASCII
    $xvlogArgs = @('-sv')
    if ($PackedAffine) { $xvlogArgs += @('-d','C1_PACKED_AFFINE_CACHE') }
    $xvlogArgs += @('-f',$sourceList)
    Invoke-XsimStep xvlog (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    Invoke-XsimStep xelab (Join-Path $vivadoBin 'xelab.bat') @(
        'tb_c1_r1_portable_soc_cache_wiring_smoke','-s',
        'tb_c1_r1_portable_soc_cache_wiring_smoke_sim')
    Invoke-XsimStep xsim (Join-Path $vivadoBin 'xsim.bat') @(
        'tb_c1_r1_portable_soc_cache_wiring_smoke_sim','-runall') `
        'C1_R1_PORTABLE_SOC_CACHE_WIRING_SMOKE_PASS'

    $watch.Stop()
    Write-Status complete done 0 `
        'C1_R1_PORTABLE_SOC_CACHE_WIRING_SMOKE_PASS'
} catch {
    $watch.Stop()
    Write-Status failed $script:currentStep 1 $_.Exception.Message
    exit 1
} finally {
    # This smoke is intentionally disposable: the full RTL source set can
    # create a large xsim database, so never leave it in the workspace.
    $resolvedCase = [IO.Path]::GetFullPath($caseRoot)
    $resolvedRun = [IO.Path]::GetFullPath($runRoot)
    if($resolvedRun.StartsWith($resolvedCase + [IO.Path]::DirectorySeparatorChar)) {
        if(Test-Path -LiteralPath $resolvedRun) {
            Remove-Item -LiteralPath $resolvedRun -Recurse -Force
        }
    } else {
        throw 'refusing to remove a smoke runRoot outside caseRoot'
    }
}
