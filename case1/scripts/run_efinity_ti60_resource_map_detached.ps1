<##
.SYNOPSIS
  Run a bounded, boardless Efinity map for the Case-1 Ti60 resource proxy.

.DESCRIPTION
  The foreground invocation only creates a WMI-detached worker.  The worker
  copies the three tiny project files into a private %TEMP% tree, runs the
  bundled Efinity Python runner with flow=map (and optional -RunPnr), extracts
  bounded resource/final-STA summaries, and removes the private tree in finally.
  No bitstream, simulation, GUI, Vivado or xsim process is started.
##>
[CmdletBinding()]
param(
    [switch]$Worker,
    [string]$RunId = '',
    [string]$DesignName = 'c1_ti60_resource_proxy',
    [string]$TopModule = '',
    [string]$EfinityHome = 'D:\ELS\Efinity\2026.1',
    [int]$TimeoutSeconds = 180,
    [switch]$RunPnr,
    [switch]$ProjectInPlace,
    [switch]$CdcAudit
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'efinity_final_timing.ps1')
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$proxyRoot = Join-Path $caseRoot 'efinity'
$logRoot = Join-Path $caseRoot 'logs\efinity_resource_runs'

if (-not $Worker) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
    if ($DesignName -notmatch '^[A-Za-z0-9_]+$') { throw 'invalid DesignName' }
    if ([string]::IsNullOrWhiteSpace($TopModule)) { $TopModule = $DesignName }
    if ($TopModule -notmatch '^[A-Za-z0-9_]+$') { throw 'invalid TopModule' }
    if (Test-Path -LiteralPath (Join-Path $logRoot $RunId)) { throw 'RunId already exists; refusing to overwrite evidence' }
    $statusPath = Join-Path $logRoot "$RunId\status.json"
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $pnrArg = if ($RunPnr) { ' -RunPnr' } else { '' }
    $inPlaceArg = if ($ProjectInPlace) { ' -ProjectInPlace' } else { '' }
    $cdcArg = if ($CdcAudit) { ' -CdcAudit' } else { '' }
    $cmd = "`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId -DesignName $DesignName -TopModule $TopModule -EfinityHome `"$EfinityHome`" -TimeoutSeconds $TimeoutSeconds$pnrArg$inPlaceArg$cdcArg"
    $workerPid = $null
    try {
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $caseRoot }
        if ($r.ReturnValue -eq 0) { $workerPid = [int]$r.ProcessId }
    } catch {
        # CIM/WMI is often denied inside a managed desktop job.  The native
        # helper uses CreateProcess(CREATE_BREAKAWAY_FROM_JOB) and is the
        # preferred fallback; either path keeps Efinity outside this turn's
        # Windows Job object.
    }
    if ($null -eq $workerPid) {
        $helper = Join-Path $caseRoot 'scripts\start_detached_process.ps1'
        if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'detached process helper is missing' }
        $workerPid = [int](& $helper -CommandLine $cmd -CurrentDirectory $caseRoot)
    }
    [ordered]@{ run_id = $RunId; worker_pid = $workerPid; status_path = $statusPath } | ConvertTo-Json
    exit 0
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'invalid RunId' }
if ($DesignName -notmatch '^[A-Za-z0-9_]+$') { throw 'invalid DesignName' }
if ([string]::IsNullOrWhiteSpace($TopModule)) { $TopModule = $DesignName }
if ($TopModule -notmatch '^[A-Za-z0-9_]+$') { throw 'invalid TopModule' }
$runRoot = Join-Path $env:TEMP "c1_efinity_resource_${DesignName}_$RunId"
$runLog = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLog 'status.json'
$summaryPath = Join-Path $runLog 'summary.json'
$latestPath = Join-Path $logRoot 'latest_status.json'
$watch = [Diagnostics.Stopwatch]::StartNew()
$workerStart = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')
$workerInJob = $null
$workerBudget = $null
$budgetLease = $null
$budgetOwned = $false
$resourceTempRoot = [IO.Path]::GetFullPath($env:TEMP)
$script:step = 'setup'
# No -Force: the worker also refuses a duplicate, including launch races.
if ((Test-Path -LiteralPath $runRoot) -or (Test-Path -LiteralPath $runLog)) { throw 'RunId/private directory already exists' }
New-Item -ItemType Directory -Path $runLog | Out-Null
New-Item -ItemType Directory -Path $runRoot | Out-Null

function Write-Status([string]$State, [string]$Step, [int]$Code, [string]$Message, [object]$Metrics = $null) {
    $obj = [ordered]@{
        run_id = $RunId; state = $State; step = $Step; exit_code = $Code
        message = $Message; process_id = $PID
        worker_start = $workerStart; worker_in_windows_job = $workerInJob; workload_budget = $workerBudget
        run_directory = $runRoot; run_directory_present = (Test-Path -LiteralPath $runRoot)
        elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        log_directory = $runLog; summary_path = $summaryPath; metrics = $Metrics
    }
    $json = $obj | ConvertTo-Json -Depth 8
    $json | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $json | Set-Content -LiteralPath $latestPath -Encoding UTF8
}

function Get-Tail([string]$Path, [int]$Lines = 120) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue)
}

function Read-ResourceMetrics([string[]]$Files, [string]$TopName) {
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($file in $Files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $file
        # Reports are normally small; skip unexpectedly huge databases/logs.
        if ($item.Length -gt 16MB) { continue }
        foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
            if ($line -match '(?i)LE|XLR|LUT|flip.flop|logic element|DSP|multiplier|EBR|block ram|memory|register|resource' -or
                $line -match '\s+[0-9,]+\([0-9,]+\)\s+[0-9,]+\([0-9,]+\)') {
                [void]$all.Add($line.ToString())
            }
        }
    }
    $text = $all -join "`n"
    function FirstNumber([string[]]$Patterns) {
        foreach ($pattern in $Patterns) {
            $m = [regex]::Match($text, $pattern)
            if ($m.Success) { return [int](($m.Groups[1].Value -replace ',', '')) }
        }
        return $null
    }
    $primitiveLines = @($all | Where-Object { $_ -match '(?i)EFX_[A-Z0-9_]+\s*:\s*[0-9][0-9,]*' })
    $primitiveCounts = @{}
    foreach ($line in $primitiveLines) {
        $pm = [regex]::Match($line.ToString(), '(?i)\b(EFX_[A-Z0-9_]+)\s*:\s*([0-9][0-9,]*)')
        if ($pm.Success) {
            $key = $pm.Groups[1].Value.ToUpperInvariant()
            $value = [int](($pm.Groups[2].Value -replace ',', ''))
            if (-not $primitiveCounts.ContainsKey($key) -or $value -gt $primitiveCounts[$key]) { $primitiveCounts[$key] = $value }
        }
    }
    $moduleRow = $null
    $moduleRows = New-Object System.Collections.Generic.List[string]
    $moduleMetrics = [ordered]@{ ff = $null; srl = $null; adds = $null; luts = $null; comb4 = $null; rams = $null; dsp_mults = $null }
    foreach ($line in $all) {
        $row = [regex]::Match($line.ToString(), '(?im)^\s*(?:INFO\s*:\s*)?[^\s]+\s+([0-9][0-9,]*)\([0-9][0-9,]*\)\s+([0-9][0-9,]*)\([0-9][0-9,]*\)\s+([0-9][0-9,]*)\([0-9][0-9,]*\)\s+([0-9][0-9,]*)\([0-9][0-9,]*\)\s+([0-9][0-9,]*)\([0-9][0-9,]*\)\s+([0-9][0-9,]*)\([0-9][0-9,]*\)\s+([0-9][0-9,]*)\([0-9][0-9,]*\)\s*$')
        $rootLabel = [regex]::Match($line.ToString(), '^\s*(?:INFO\s*:\s*)?' + [regex]::Escape($TopName) + ':(\S+)\s+')
        $isRoot = $false
        if ($rootLabel.Success) {
            $printed = $rootLabel.Groups[1].Value
            $isRoot = $printed -ceq $TopName
            if (-not $isRoot -and $printed.EndsWith('...') -and $printed.Length -ge 11) {
                $isRoot = $TopName.StartsWith($printed.Substring(0,$printed.Length-3), [StringComparison]::Ordinal)
            }
        }
        if ($row.Success -and $isRoot) {
            $moduleRow = $line.ToString()
            $keys = @('ff', 'srl', 'adds', 'luts', 'comb4', 'rams', 'dsp_mults')
            for ($ri = 0; $ri -lt $keys.Count; $ri++) {
                $moduleMetrics[$keys[$ri]] = [int](($row.Groups[$ri + 1].Value -replace ',', ''))
            }
        }
        if ($row.Success) { [void]$moduleRows.Add($line.ToString()) }
    }
    return [ordered]@{
        le = if ($null -ne $moduleMetrics.luts -and $moduleMetrics.luts -gt 0) { $moduleMetrics.luts } elseif ($primitiveCounts.ContainsKey('EFX_LUT4')) { $primitiveCounts['EFX_LUT4'] } else { FirstNumber @('(?im)\b(?:logic\s+elements?|LEs?)\b[^0-9\r\n]*([0-9][0-9,]*)', '(?im)\bLE\b\s*\|\s*([0-9][0-9,]*)') }
        registers = if ($null -ne $moduleMetrics.ff -and $moduleMetrics.ff -gt 0) { $moduleMetrics.ff } elseif ($primitiveCounts.ContainsKey('EFX_FF')) { $primitiveCounts['EFX_FF'] } else { $null }
        dsp = if ($primitiveCounts.Count -gt 0) { [int](($primitiveCounts.GetEnumerator() | Where-Object { $_.Key -match '^EFX_DSP' } | Measure-Object -Property Value -Sum).Sum) } elseif ($null -ne $moduleMetrics.dsp_mults) { $moduleMetrics.dsp_mults } else { $null }
        ebr = if ($null -ne $moduleMetrics.rams) { $moduleMetrics.rams } elseif (@($primitiveCounts.Keys | Where-Object { $_ -match '^EFX_(?:EBR|RAM)' }).Count -gt 0) { [int](($primitiveCounts.GetEnumerator() | Where-Object { $_.Key -match '^EFX_(?:EBR|RAM)' } | Measure-Object -Property Value -Sum).Sum) } else { $null }
        report_lines = $all.Count
        sample = @($all | Select-Object -First 300)
        primitive_lines = $primitiveLines
        primitive_counts = $primitiveCounts
        module_row = $moduleRow
        # Keep this bounded. C4's 32 parameter-bank RAM instances otherwise
        # pushed spatial/compute hierarchy beyond the former 40-row cutoff.
        # Retain the original bounded prefix, plus a small structural view:
        # many replicated RAM rows must not hide late sibling bus modules.
        module_rows = @($moduleRows | Select-Object -First 80)
        # Small targeted rows survive private-project cleanup; avoid copying full reports.
        resource_opt_module_rows = @($moduleRows | Where-Object { $_ -match '\+u_(quant|compute|pack|unpack|spatial_pack|spatial_unpack|spatial|store|engine|linear):' } | Select-Object -First 24)
        module_focus_rows = @($moduleRows | Where-Object { $_ -match '\+u_(system|control|cnn|fabric|read|write|leases|capture|scanout):' } | Select-Object -First 32)
        module = $moduleMetrics
    }
}

try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Case1EfinityJobCheck {
    [DllImport("kernel32.dll",SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
}
'@
    $jobValue = $false
    if (-not [Case1EfinityJobCheck]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle,[IntPtr]::Zero,[ref]$jobValue)) { throw 'Cannot verify Efinity Job isolation' }
    $workerInJob = $jobValue
    if ($workerInJob) { throw 'Efinity worker is bound to a Windows Job' }
    . (Join-Path $PSScriptRoot 'set_fpga_worker_budget.ps1')
    Write-Status 'running' 'prepare' 0 'detached Efinity Ti60 map started'
    if ($ProjectInPlace) {
        foreach ($name in @("$DesignName.xml", "$DesignName.sdc")) {
            $src = Join-Path $proxyRoot $name
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Missing in-place project file: $src" }
        }
    } else {
        foreach ($name in @("$DesignName.v", "$DesignName.sdc", "$DesignName.xml")) {
            $src = Join-Path $proxyRoot $name
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Missing proxy file: $src" }
            Copy-Item -LiteralPath $src -Destination (Join-Path $runRoot $name)
        }
    }
    $outDir = Join-Path $runRoot 'out'
    $workDir = Join-Path $runRoot 'work'
    New-Item -ItemType Directory -Force -Path $outDir, $workDir | Out-Null
    $efUnix = $EfinityHome.Replace('\', '/')
    $env:EFINITY_HOME = $efUnix
    $env:EFXPT_HOME = "$efUnix/pt"
    $env:EFXPGM_HOME = "$efUnix/pgm"
    $env:EFXDBG_HOME = "$efUnix/debugger"
    $env:EFXIPM_HOME = "$efUnix/ipm"
    $env:EFXSVF_HOME = "$efUnix/debugger/svf_player"
    $env:EFXSERDESDBG_HOME = "$efUnix/debugger/serdes_debug_tool"
    $env:EFINITY_USER_DIR_INI = ((Join-Path $env:LOCALAPPDATA 'Efinity\efinity\user_dir.ini').Replace('\', '/'))
    $env:PYTHONHOME = Join-Path $EfinityHome 'python311'
    $env:PATH = ((Join-Path $EfinityHome 'python311\bin') + ';' +
                 (Join-Path $EfinityHome 'bin') + ';' +
                 (Join-Path $EfinityHome 'scripts') + ';' + $env:PATH)

    $stdoutTmp = Join-Path $runRoot 'efinity.stdout.log'
    $stderrTmp = Join-Path $runRoot 'efinity.stderr.log'
    $python = Join-Path $EfinityHome 'python311\bin\python.exe'
    $runner = Join-Path $EfinityHome 'scripts\efx_run.py'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "Missing Efinity Python: $python" }
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Missing Efinity runner: $runner" }
    $script:step = 'efx_map'
    $args = @($runner, $DesignName, '--prj', '-f', 'map',
              '--family', 'Titanium', '--device', 'Ti60F225',
              '--output_dir', $outDir, '--work_dir', $workDir,
              '--timeout', [string]$TimeoutSeconds,
              '--map_opts', "root=$TopModule")
    # The worker itself was created with CREATE_BREAKAWAY_FROM_JOB.  Invoke
    # the bundled Python directly so it inherits that detached process; this
    # also avoids Start-Process rebuilding a Windows environment block with
    # duplicate Path/PATH entries on some managed hosts.
    $projectCwd = if ($ProjectInPlace) { $proxyRoot } else { $runRoot }
    Push-Location $projectCwd
    try {
        & $python @args 1> $stdoutTmp 2> $stderrTmp
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $stdoutTail = Get-Tail $stdoutTmp
    $stderrTail = Get-Tail $stderrTmp
    $stdoutTail | Set-Content -LiteralPath (Join-Path $runLog 'efinity.stdout.tail.log') -Encoding UTF8
    $stderrTail | Set-Content -LiteralPath (Join-Path $runLog 'efinity.stderr.tail.log') -Encoding UTF8
    if ($exitCode -ne 0) { throw "Efinity runner exit code $exitCode" }

    if ($CdcAudit) {
        # Retain only relevant FF blocks, never the full multi-MB netlist.
        # Default flows remain unchanged. These are implementation evidence,
        # not simulation models and not a physical CDC sign-off by themselves.
        $kept=New-Object System.Collections.Generic.List[string]
        $count=0
        Get-ChildItem -LiteralPath $runRoot -Recurse -File|Where-Object {$_.Extension -in @('.v','.sv','.json','.xml')}|
            Select-Object FullName,Length|ConvertTo-Json -Depth 2|Set-Content -LiteralPath (Join-Path $runLog 'cdc_artifact_names.json') -Encoding UTF8
        foreach($netlist in Get-ChildItem -LiteralPath $outDir -File -Filter '*.map.v') {
            Get-Content -LiteralPath $netlist.FullName -TotalCount 24|Set-Content -LiteralPath (Join-Path $runLog 'cdc_netlist_header.txt') -Encoding UTF8
            $block=New-Object System.Collections.Generic.List[string]
            $previous=New-Object System.Collections.Generic.Queue[string]
            $inBlock=$false
            foreach($line in [IO.File]::ReadLines($netlist.FullName)) {
                if($line -match '^\s*EFX_FF(?:\s|#)') {
                    $block.Clear();foreach($oldLine in $previous){$block.Add($oldLine)}
                    $inBlock=$true
                }
                if($inBlock){$block.Add($line)}
                if($inBlock -and $line -match ';\s*(?://.*)?$') {
                    $retentionPattern=if($DesignName -like 'c1_ti60_c39_joint_*'){
                        # Joint CPU netlists are not an IP inspection target.
                        # Keep only the host CDC blocks, not similarly named CPU internals.
                        'u_host/u_system/(?:u_ingress|u_camera_snapshot|capture_tag|camera_snapshot)'
                    }else{'(?:u_ingress|u_camera_snapshot|lower_|upper_|plain_|src_q)'}
                    if(($block -join "`n") -match $retentionPattern) {
                        $count++;if($count -gt 700){throw 'CDC netlist evidence exceeded bounded register count'}
                        $kept.AddRange([string[]]$block);$kept.Add('')
                    }
                    $inBlock=$false
                }
                $previous.Enqueue($line);if($previous.Count -gt 4){[void]$previous.Dequeue()}
            }
        }
        if($count -eq 0){throw 'no CDC register blocks found in mapped netlist'}
        $kept|Set-Content -LiteralPath (Join-Path $runLog 'cdc_mapped_registers.txt') -Encoding UTF8
        "C27_CDC_MAPPED_REGISTERS count=$count"|Set-Content -LiteralPath (Join-Path $runLog 'cdc_map_summary.log') -Encoding UTF8
    }

    $pnrExit = $null
    $pnrTail = @()
    $pnrErrTail = @()
    if ($RunPnr) {
        $script:step = 'efx_pnr'
        $pnrStdoutTmp = Join-Path $runRoot 'efinity_pnr.stdout.log'
        $pnrStderrTmp = Join-Path $runRoot 'efinity_pnr.stderr.log'
        $pnrArgs = @($runner, $DesignName, '--prj', '-f', 'pnr',
                     '--family', 'Titanium', '--device', 'Ti60F225',
                     '--output_dir', $outDir, '--work_dir', $workDir,
                     '--timeout', [string]$TimeoutSeconds)
        Push-Location $projectCwd
        try {
            & $python @pnrArgs 1> $pnrStdoutTmp 2> $pnrStderrTmp
            $pnrExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $pnrTail = Get-Tail $pnrStdoutTmp
        $pnrErrTail = Get-Tail $pnrStderrTmp
        $pnrTail | Set-Content -LiteralPath (Join-Path $runLog 'efinity.pnr.stdout.tail.log') -Encoding UTF8
        $pnrErrTail | Set-Content -LiteralPath (Join-Path $runLog 'efinity.pnr.stderr.tail.log') -Encoding UTF8
        if ($pnrExit -ne 0) { throw "Efinity PNR runner exit code $pnrExit" }
        if ($CdcAudit) {
            # Keep small primary PNR evidence even if a later STA tool crashes.
            foreach($suffix in @('place.rpt','timing.rpt','hier_util.rpt')) {
                $evidence=Join-Path $outDir "$DesignName.$suffix"
                if(Test-Path -LiteralPath $evidence -PathType Leaf) {
                    Get-Content -LiteralPath $evidence -TotalCount 280 |
                        Set-Content -LiteralPath (Join-Path $runLog "pnr_before_cdc_$suffix") -Encoding UTF8
                }
            }
        }
    }

    $cdcClassification=$null
    if ($RunPnr -and $CdcAudit) {
        $auditScript=Join-Path $proxyRoot "$DesignName.audit.tcl"
        if(-not(Test-Path -LiteralPath $auditScript -PathType Leaf)){throw 'missing bounded CDC STA script'}
        $env:C27_AUDIT_OUT=$outDir.Replace('\','/')
        $staOut=Join-Path $runRoot 'cdc_sta.stdout.log';$staErr=Join-Path $runRoot 'cdc_sta.stderr.log'
        $script:step='cdc_sta'
        $staArgs=@($runner,$DesignName,'--prj','-f','sta_tclsh','--tcl_script',$auditScript,
                   '--family','Titanium','--device','Ti60F225','--output_dir',$outDir,'--work_dir',$workDir,
                   '--timeout',[string]$TimeoutSeconds)
        Push-Location $projectCwd
        try {& $python @staArgs 1> $staOut 2> $staErr;$staExit=$LASTEXITCODE}
        finally {Pop-Location}
        foreach($logFile in @($staOut,$staErr)) {
            if(Test-Path -LiteralPath $logFile) {
                if((Get-Item -LiteralPath $logFile).Length -gt 2MB){throw 'CDC STA text exceeded output bound'}
                Copy-Item -LiteralPath $logFile -Destination (Join-Path $runLog (Split-Path $logFile -Leaf))
            }
        }
        # Copy any reports BEFORE checking exit status so a late tool crash
        # cannot erase already generated, bounded timing evidence.
        foreach($partial in @(Get-ChildItem -LiteralPath $outDir -Filter 'c27_*.rpt' -File)) {
            if($partial.Length -gt 2MB){throw 'CDC partial report exceeded bounded retention'}
            Copy-Item -LiteralPath $partial.FullName -Destination (Join-Path $runLog $partial.Name)
        }
        if($staExit -ne 0){throw "CDC STA runner exit code $staExit"}
        $staLines=Get-Content -LiteralPath $staOut
        if(@($staLines|Where-Object {$_ -cmatch '^C27_AUDIT_PASS$'}).Count -ne 1){throw 'CDC STA missing successful script completion'}
        $classificationScript=Join-Path $proxyRoot "$DesignName.cdc.tcl"
        $mandatoryReports=@('c27_bus_setup.rpt','c27_bus_hold.rpt','c27_setup.rpt','c27_hold.rpt')
        if(-not(Test-Path -LiteralPath $classificationScript)){$mandatoryReports+=@('c27_cdc.rpt')}
        foreach($reportName in $mandatoryReports) {
            $reportPath=Join-Path $outDir $reportName
            if(-not(Test-Path -LiteralPath $reportPath -PathType Leaf)){throw "missing CDC report $reportName"}
            if((Get-Item -LiteralPath $reportPath).Length -gt 2MB){throw 'CDC report exceeded bounded retention'}
            Copy-Item -LiteralPath $reportPath -Destination (Join-Path $runLog $reportName)
        }
        # Optional bounded per-domain/crossing reports for multi-clock probes.
        foreach($reportName in @('c27_core_setup.rpt','c27_core_hold.rpt','c27_camera_setup.rpt','c27_camera_hold.rpt','c27_camera_to_core.rpt','c27_core_to_camera.rpt')) {
            $reportPath=Join-Path $outDir $reportName
            if(Test-Path -LiteralPath $reportPath -PathType Leaf) {
                if((Get-Item -LiteralPath $reportPath).Length -gt 2MB){throw 'CDC domain report exceeded bounded retention'}
                Copy-Item -LiteralPath $reportPath -Destination (Join-Path $runLog $reportName)
            }
        }
        if(Test-Path -LiteralPath $classificationScript -PathType Leaf) {
            $classOut=Join-Path $runRoot 'cdc_classification.stdout.log'
            $classErr=Join-Path $runRoot 'cdc_classification.stderr.log'
            $classArgs=@($runner,$DesignName,'--prj','-f','sta_tclsh','--tcl_script',$classificationScript,
                '--family','Titanium','--device','Ti60F225','--output_dir',$outDir,'--work_dir',$workDir,
                '--timeout',[string]$TimeoutSeconds)
            Push-Location $projectCwd
            try {& $python @classArgs 1> $classOut 2> $classErr;$classExit=$LASTEXITCODE}
            finally {Pop-Location}
            foreach($logFile in @($classOut,$classErr)) {
                if((Get-Item -LiteralPath $logFile).Length -gt 2MB){throw 'CDC classification log exceeded bound'}
                Copy-Item -LiteralPath $logFile -Destination (Join-Path $runLog (Split-Path $logFile -Leaf))
            }
            $classComplete=$classExit -eq 0 -and @((Get-Content -LiteralPath $classOut)|Where-Object {$_ -cmatch '^C27_CDC_CLASSIFICATION_PASS$'}).Count -eq 1
            $cdcClassification=[ordered]@{complete=$classComplete;exit_code=$classExit;physical_cdc_signoff=$false}
            $cdcClassification|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $runLog 'cdc_classification_status.json') -Encoding UTF8
            foreach($partial in @(Get-ChildItem -LiteralPath $outDir -Filter 'c27_cdc*.rpt' -File)) {
                if($partial.Length -gt 2MB){throw 'CDC classification report exceeded bound'}
                Copy-Item -LiteralPath $partial.FullName -Destination (Join-Path $runLog $partial.Name)
            }
        }
    }

    $reports = @(Get-ChildItem -LiteralPath $runRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.rpt', '.log', '.xml', '.txt') })
    $metrics = Read-ResourceMetrics ($reports | Select-Object -ExpandProperty FullName) $DesignName
    if ($metrics.sample) {
        $metrics.sample | Set-Content -LiteralPath (Join-Path $runLog 'resource_lines.sample.log') -Encoding UTF8
        $metrics.Remove('sample')
    }
    if ($metrics.primitive_lines) {
        $metrics.primitive_lines | Set-Content -LiteralPath (Join-Path $runLog 'resource_primitives.log') -Encoding UTF8
        $metrics.Remove('primitive_lines')
    }
    $pnrResources = [ordered]@{
        xlr_cells_used = $null; xlr_cells_total = $null; xlr_cells_percent = $null
        memory_blocks_used = $null; memory_blocks_total = $null; memory_blocks_percent = $null
        dsp_blocks_used = $null; dsp_blocks_total = $null; dsp_blocks_percent = $null
    }
    foreach ($report in $reports) {
        if ($report.Length -gt 16MB) { continue }
        foreach ($line in (Get-Content -LiteralPath $report.FullName -ErrorAction SilentlyContinue)) {
            $rx = [regex]::Match($line.ToString(), '(?im)^\s*XLR(?: Cells|s):\s*([0-9,]+)\s*/\s*([0-9,]+)\s*\(([0-9.]+)%')
            if ($rx.Success) { $pnrResources.xlr_cells_used = [int]($rx.Groups[1].Value -replace ',',''); $pnrResources.xlr_cells_total = [int]($rx.Groups[2].Value -replace ',',''); $pnrResources.xlr_cells_percent = [double]$rx.Groups[3].Value }
            $rm = [regex]::Match($line.ToString(), '(?im)^\s*Memory Blocks:\s*([0-9]+)\s*/\s*([0-9]+)\s*\(([0-9.]+)%')
            if ($rm.Success) { $pnrResources.memory_blocks_used = [int]$rm.Groups[1].Value; $pnrResources.memory_blocks_total = [int]$rm.Groups[2].Value; $pnrResources.memory_blocks_percent = [double]$rm.Groups[3].Value }
            $rd = [regex]::Match($line.ToString(), '(?im)^\s*DSP Blocks:\s*([0-9]+)\s*/\s*([0-9]+)\s*\(([0-9.]+)%')
            if ($rd.Success) { $pnrResources.dsp_blocks_used = [int]$rd.Groups[1].Value; $pnrResources.dsp_blocks_total = [int]$rd.Groups[2].Value; $pnrResources.dsp_blocks_percent = [double]$rd.Groups[3].Value }
        }
    }
    $marker = ($DesignName.ToUpperInvariant() + '_MAP_PASS')
    $timingLines = @($reports | ForEach-Object {
        if ($_.Length -le 16MB) {
            Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '(?i)slack|fmax|frequency|critical path|period|arrival|required|wns|tns|timing' }
        }
    } | Select-Object -First 160)
    if ($timingLines.Count -gt 0) {
        $timingLines | Set-Content -LiteralPath (Join-Path $runLog 'timing_lines.sample.log') -Encoding UTF8
    }
    # Preserve a bounded final-STA excerpt BEFORE private database cleanup.
    # The keyword-only summary omits launch/capture pins and cell/net paths,
    # making a negative slack impossible to diagnose without rerunning PNR.
    # This is text evidence only, never a waveform or netlist/database copy.
    $finalTimingReport = $reports | Where-Object { $_.Name -eq "$DesignName.timing.rpt" } | Select-Object -First 1
    if ($null -ne $finalTimingReport) {
        Get-Content -LiteralPath $finalTimingReport.FullName -TotalCount 260 |
            Set-Content -LiteralPath (Join-Path $runLog 'timing_max_paths.sample.log') -Encoding UTF8
    }
    $timingText = $timingLines -join "`n"
    $timing = [ordered]@{
        post_place_period_ns = $null; post_place_frequency_mhz = $null;
        final_period_ns = $null; final_frequency_mhz = $null;
        max_period_ns = $null; max_frequency_mhz = $null;
        post_place_slack_ns = $null; post_place_hold_slack_ns = $null;
        final_slack_ns = $null; final_hold_slack_ns = $null
    }
    $periods = [regex]::Matches($timingText, '(?im)Geomean max period:\s*([0-9]+(?:\.[0-9]+)?)')
    if ($periods.Count -ge 1) {
        $timing.post_place_period_ns = [double]$periods[0].Groups[1].Value
        $timing.post_place_frequency_mhz = [math]::Round(1000.0 / $timing.post_place_period_ns, 3)
        $timing.max_period_ns = $timing.post_place_period_ns
        $timing.max_frequency_mhz = $timing.post_place_frequency_mhz
    }
    if ($periods.Count -ge 2) {
        $timing.final_period_ns = [double]$periods[$periods.Count - 1].Groups[1].Value
        $timing.final_frequency_mhz = [math]::Round(1000.0 / $timing.final_period_ns, 3)
        $timing.max_period_ns = $timing.final_period_ns
        $timing.max_frequency_mhz = $timing.final_frequency_mhz
    }
    $slacks = [regex]::Matches($timingText, '(?im)Worst Negative Slack \(WNS\).*?value="([-+]?[0-9]+(?:\.[0-9]+)?) ns"')
    $holds = [regex]::Matches($timingText, '(?im)Worst Hold Slack \(WHS\).*?value="([-+]?[0-9]+(?:\.[0-9]+)?) ns"')
    if ($slacks.Count -ge 1) { $timing.post_place_slack_ns = [double]$slacks[0].Groups[1].Value }
    if ($slacks.Count -ge 2) { $timing.final_slack_ns = [double]$slacks[$slacks.Count - 1].Groups[1].Value }
    if ($holds.Count -ge 1) { $timing.post_place_hold_slack_ns = [double]$holds[0].Groups[1].Value }
    if ($holds.Count -ge 2) { $timing.final_hold_slack_ns = [double]$holds[$holds.Count - 1].Groups[1].Value }
    # Intermediate logs can repeat a post-place geomean and omit WNS/WHS.
    # Only the complete final STA table may establish final timing evidence.
    if ($RunPnr) {
        $timing.final_slack_ns = $null; $timing.final_hold_slack_ns = $null
        $timing.final_period_ns = $null; $timing.final_frequency_mhz = $null
        $timing.max_period_ns = $null; $timing.max_frequency_mhz = $null
        $timing.final_source = 'unavailable'; $timing.final_parse_error = $null
        $timing.geomean_is_core_fmax = $false
        if ($null -ne $finalTimingReport) {
            try {
                $finalSta = Get-EfinityFinalTiming ((Get-Content -LiteralPath (Join-Path $runLog 'timing_max_paths.sample.log') -TotalCount 260) -join "`n")
                $timing.final_slack_ns = $finalSta.final_slack_ns
                $timing.final_hold_slack_ns = $finalSta.final_hold_slack_ns
                $timing.final_period_ns = $finalSta.geomean_period_ns
                $timing.final_frequency_mhz = $finalSta.geomean_frequency_mhz
                $timing.max_period_ns = $finalSta.geomean_period_ns
                $timing.max_frequency_mhz = $finalSta.geomean_frequency_mhz
                $timing.final_source = $finalSta.source
                $finalSta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runLog 'final_sta_table.json') -Encoding UTF8
            } catch { $timing.final_parse_error = $_.Exception.Message }
        }
    }
    if ($RunPnr) { $metrics.timing = $timing; $metrics.pnr_resources = $pnrResources }
    if ($null -ne $cdcClassification) { $metrics.cdc_classification = $cdcClassification }
    $marker = ($DesignName.ToUpperInvariant() + $(if ($RunPnr) { '_MAP_PNR_PASS' } else { '_MAP_PASS' }))
    if ($null -ne $cdcClassification -and -not $cdcClassification.complete) { $marker += '_CDC_REPORT_UNAVAILABLE' }
    $summary = [ordered]@{
        run_id = $RunId; marker = $marker; state = 'complete';
        efinity_version = '2026.1.132.3.9'; family = 'Titanium';
        device = 'Ti60F225'; flow = $(if ($RunPnr) { 'map+pnr' } else { 'map' });
        pnr_exit_code = $pnrExit; timing = $timing; pnr_resources = $pnrResources; metrics = $metrics; report_file_count = $reports.Count
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $watch.Stop(); Write-Status 'complete' 'done' 0 $marker $metrics
} catch {
    $watch.Stop()
    $message = $_.Exception.Message
    $failureLines = @()
    foreach ($logFile in (Get-ChildItem -LiteralPath $runRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.log', '.out', '.rpt') })) {
        if ($logFile.Length -le 16MB) {
            $failureLines += @(Get-Content -LiteralPath $logFile.FullName -Tail 80 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '(?i)error|fail|cannot|missing|not found|undefined|unconnected' })
        }
    }
    if ($failureLines.Count -gt 0) {
        $failureLines | Select-Object -Last 120 | Set-Content -LiteralPath (Join-Path $runLog 'failure_focus.log') -Encoding UTF8
        $tail = ($failureLines | Select-Object -Last 12) -join ' | '
        $message = "$message; failure_tail=$tail"
    }
    Write-Status 'failed' $script:step 1 $message
    exit 1
} finally {
    try {
        $resolvedResource = [IO.Path]::GetFullPath($runRoot)
        if (-not $resolvedResource.StartsWith($resourceTempRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $resolvedResource) -ne "c1_efinity_resource_${DesignName}_$RunId") { throw 'Unsafe Efinity private cleanup target' }
        if (Test-Path -LiteralPath $resolvedResource) { Remove-Item -LiteralPath $resolvedResource -Recurse -Force -ErrorAction Stop }
        if (Test-Path -LiteralPath $statusPath) {
            $finalStatus = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $finalStatus.run_directory_present = (Test-Path -LiteralPath $resolvedResource)
            $finalStatus | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statusPath -Encoding UTF8
            $finalStatus | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $latestPath -Encoding UTF8
        }
    } catch { Write-Status 'failed' 'cleanup' 1 $_.Exception.Message }
    finally { if ($budgetLease) { if ($budgetOwned) { $budgetLease.ReleaseMutex() }; $budgetLease.Dispose() } }
}
