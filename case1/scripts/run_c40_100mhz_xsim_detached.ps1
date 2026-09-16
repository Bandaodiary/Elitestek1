[CmdletBinding()]
param([switch]$Worker,[string]$RunId='c40_100mhz_xsim_production_20260916a',
      [string]$RegressionRun='c40_production_20260916a')
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($RunId -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RunId'}
if($RegressionRun -notmatch '^[A-Za-z0-9_-]+$'){throw 'invalid RegressionRun'}
$simRoot=(Resolve-Path (Join-Path $caseRoot 'sim')).Path
$work=Join-Path $simRoot $RunId
$log=Join-Path $caseRoot "logs\c40_100mhz_xsim_runs\$RunId"
if(-not $Worker){
    if((Test-Path -LiteralPath $work) -or (Test-Path -LiteralPath $log)){throw 'run already exists'}
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $line="`"$ps`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker -RunId $RunId -RegressionRun $RegressionRun"
    $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$line;CurrentDirectory=$caseRoot}
    if($r.ReturnValue -ne 0){throw 'WMI xsim worker launch failed'}
    [ordered]@{run_id=$RunId;worker_pid=$r.ProcessId;status_path=(Join-Path $log 'status.json')}|ConvertTo-Json -Compress
    exit 0
}
$python='D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'
$vivado='D:\vivado\vivado\Vivado\2023.1\bin'
$watch=[Diagnostics.Stopwatch]::StartNew();$history=@();$state='starting';$step='prepare';$exitCode=1
$child=$null;$safeCleanup=$true
New-Item -ItemType Directory -Path $work,$log -Force|Out-Null
function Save-State {
    [ordered]@{run_id=$RunId;state=$state;step=$step;exit_code=$exitCode;worker_pid=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,1);heartbeat=(Get-Date).ToString('o');
        work_directory=$work;work_directory_present=(Test-Path -LiteralPath $work);completed_steps=$history;
        core_hz=100000000;nn_target=6;actual_CPU_IP=$false;simulator='Vivado xsim 2023.1'}|
        ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $log 'status.json') -Encoding UTF8
}
function Invoke-Step([string]$Name,[string]$Exe,[string[]]$Arguments,[int]$Limit) {
    $script:state='running';$script:step=$Name;Save-State
    $stdout=Join-Path $log "$Name.stdout.log";$stderr=Join-Path $log "$Name.stderr.log"
    $quoted=@($Arguments|ForEach-Object {if($_.Contains('"')){throw 'quote in argument'};'"'+$_+'"'})
    $p=Start-Process -FilePath $Exe -ArgumentList $quoted -WorkingDirectory $work -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $script:child=$p;$timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        $handle=$p.Handle;$inJob=$false
        if(-not [C40XsimJob]::IsProcessInJob($handle,[IntPtr]::Zero,[ref]$inJob)){throw 'child Job query failed'}
        if($inJob){throw 'xsim child inherited Windows Job'}
        while(-not $p.WaitForExit(10000)){
            Save-State
            if($timer.Elapsed.TotalSeconds -gt $Limit){throw "$Name exceeded limit"}
        }
        $p.WaitForExit();$code=$p.ExitCode
        $script:history += [ordered]@{name=$Name;pid=$p.Id;exit_code=$code;seconds=[math]::Round($timer.Elapsed.TotalSeconds,2);in_windows_job=$false}
        if($code -ne 0){throw "$Name failed with exit $code"}
    } finally {
        if(-not $p.WaitForExit(0)){$script:safeCleanup=$false}
        $p.Dispose();$script:child=$null
    }
}
try {
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class C40XsimJob {[DllImport("kernel32.dll",SetLastError=true)] public static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool result);}
'@
    $me=[Diagnostics.Process]::GetCurrentProcess();$workerInJob=$false
    if(-not [C40XsimJob]::IsProcessInJob($me.Handle,[IntPtr]::Zero,[ref]$workerInJob) -or $workerInJob){throw 'worker must be outside Windows Job'}
    if(Get-Process vvp,xsim,xelab,xvlog -ErrorAction SilentlyContinue){throw 'another simulator process is active'}
    Invoke-Step 'matrix100' $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\run_c40_production_regression.py'),'--run-id',"${RegressionRun}_matrix100",'--matrix100-only') 3600
    Invoke-Step 'prepare' $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\prepare_c40_100mhz_xsim.py'),'--work-dir',$work,'--log-dir',$log,'--regression-run',$RegressionRun) 900
    $manifest=Get-Content -LiteralPath (Join-Path $work 'manifest.json') -Raw|ConvertFrom-Json
    $allSources=@($manifest.sources)+@($manifest.support_sources)+@($manifest.testbench)
    Invoke-Step 'xvlog' (Join-Path $vivado 'xvlog.bat') (@('-sv')+$allSources) 900
    $generic=@();foreach($property in $manifest.options.psobject.Properties){$generic+=@('-generic_top',"$($property.Name)=$($property.Value)")}
    Invoke-Step 'xelab' (Join-Path $vivado 'xelab.bat') (@($manifest.top,'-s',$manifest.snapshot,'-mt','2')+$generic) 1800
    $plus=@();foreach($arg in $manifest.plusargs){$plus+=@('-testplusarg',[string]$arg)}
    Invoke-Step 'xsim' (Join-Path $vivado 'xsim.bat') (@($manifest.snapshot,'-runall')+$plus) 21600
    $text=Get-Content -LiteralPath (Join-Path $log 'xsim.stdout.log') -Raw
    if($text -notmatch '(?m)^C1_R2_FUSED_RGB2_HOST_SYSTEM_PASS ' -or $text -notmatch '(?m)^C40_CLOCK_PASS core_hz=100000000 ' -or $text -match '(?im)FATAL|ERROR:'){throw 'xsim terminal evidence failed'}
    @($text -split '\r?\n'|Where-Object {$_ -match '^(C1_R2_FUSED_RGB2_HOST_SYSTEM_|C40_)'})|Set-Content -LiteralPath (Join-Path $log 'xsim.result.log') -Encoding UTF8
    $state='complete';$step='done';$exitCode=0;Save-State
} catch {
    $state='failed';$step='failed';$exitCode=1
    $_|Out-String|Set-Content -LiteralPath (Join-Path $log 'failure.log') -Encoding UTF8
    Save-State
} finally {
    if($safeCleanup -and (Test-Path -LiteralPath $work)){
        $resolved=(Resolve-Path -LiteralPath $work).Path
        if(-not $resolved.StartsWith($simRoot+[IO.Path]::DirectorySeparatorChar)){throw 'refusing unsafe cleanup'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    Save-State
}
exit $exitCode
