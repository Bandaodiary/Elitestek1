[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'efinity_final_timing.ps1')
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$folder=Join-Path $caseRoot 'logs/efinity_resource_runs/c39_native_acceptance_20260915a_joint_s2_native'
$text=(Get-Content -LiteralPath (Join-Path $folder 'timing_max_paths.sample.log') -TotalCount 260) -join "`n"
$actual=Get-EfinityFinalTiming $text
if($actual.final_slack_ns -ne -0.845 -or $actual.final_hold_slack_ns -ne 0.011 -or
   $actual.geomean_period_ns -ne 3.471 -or $actual.setup_rows -ne 19 -or $actual.hold_rows -ne 19 -or
   $actual.timing_pass -ne $false){throw 'actual joint final STA was parsed incorrectly'}
$mutants=@(
    $text.Replace('status : final','status : preliminary'),
    $text.Replace('---------- Clock Relationship Summary (end) ---------------',''),
    $text.Replace('Hold (Min) Clock Relationship',''),
    $text.Replace('-0.845','N/A'),
    $text.Replace('Geomean max period: 3.471','Geomean max period: 0'),
    $text.Replace('Setup (Max) Clock Relationship',"Setup (Max) Clock Relationship`nSetup (Max) Clock Relationship")
)
$rejected=0
foreach($bad in $mutants){
    $caught=$false
    try{$null=Get-EfinityFinalTiming $bad}catch{$caught=$true}
    if(-not $caught){throw 'malformed timing evidence accepted'}
    $rejected++
}
$good=$text.Replace('-0.845','0.845').Replace('-0.428','0.428')
if(-not (Get-EfinityFinalTiming $good).timing_pass){throw 'synthetic all-positive table rejected'}
foreach($entry in @(
    @{run='c39_host_native_pnr_20260915a';setup=0.377},
    @{run='c37_resource24_pnr_20260915b';setup=0.267}
)){
    $path=Join-Path $caseRoot ('logs/efinity_resource_runs/'+$entry.run+'/timing_max_paths.sample.log')
    $positive=Get-EfinityFinalTiming ((Get-Content -LiteralPath $path -TotalCount 260) -join "`n")
    if(-not $positive.timing_pass -or $positive.final_slack_ns -ne $entry.setup -or
       $positive.final_hold_slack_ns -ne 0.026 -or $positive.setup_rows -ne 4){throw 'actual passing host report parsed incorrectly'}
}
[ordered]@{actual_report_pass=$true; actual_design_timing_pass=$false; setup_ns=$actual.final_slack_ns;
    hold_ns=$actual.final_hold_slack_ns; rejected_evidence_mutations=$rejected;
    actual_passing_host_reports=2; synthetic_positive_pass=$true; source_files_modified=$false}|ConvertTo-Json
