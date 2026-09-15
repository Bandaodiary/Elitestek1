<##
.SYNOPSIS
  Reproduce the verified board-independent column-refill throughput profile.
.DESCRIPTION
  This is configuration only: it does not change production RTL defaults.
  Every real run goes through the existing Win32_Process.Create outer runner,
  never its Worker entry. No GUI or FPGA toolchain-specific IP is required.
  Wide means 32 scheduler C8 credits, NOT 32 physical AXI transactions.
  DryRun prints the resolved argument object without dispatching any process.
##>
[CmdletBinding()]
param(
    [ValidateSet('Single','ReadAbort','WriteAbort','TwoFrame')]
    [string]$Scenario='Single',
    [ValidateSet('Baseline','Handoff','WindowOnly','Wide')]
    [string]$RefillMode='Wide',
    [ValidateSet('8x8','64x48')][string]$Frame='64x48',
    [ValidateSet(1,2)][int]$ScalarReadCacheEntries=1,
    [switch]$WarmScalarAbort,
    [string]$RunId='',
    [switch]$DryRun
)
$ErrorActionPreference='Stop'
if($WarmScalarAbort -and ($Scenario -ne 'ReadAbort' -or $ScalarReadCacheEntries -ne 2)){
    throw 'WarmScalarAbort requires ReadAbort and two scalar cache entries'
}
if($Scenario -ne 'Single' -and $PSBoundParameters.ContainsKey('Frame') -and $Frame -ne '8x8'){
    throw 'Recovery and two-frame evidence currently support 8x8 only'
}
$c1Options=@{
    Frame=$(if($Scenario -eq 'Single'){$Frame}else{'8x8'})
    TrainedArtifact=$true; ColorFixture=$true
    TensorWriteOutstanding=1; PixelWriteBatchWords=8; TensorWriteBuildTimeout=64
    ScalarReadCacheEntries=$ScalarReadCacheEntries
}
foreach($c1Flag in @(
    'QueuedWriteFabric','PipelineDwPixels','PipelineDotPixels','AllDotGroups','AllPixelGroups',
    'TensorColumnReads','ColumnReadOnLookup','ColumnResponseBypass','PixelColumnPrefetch',
    'PipelinedSourceWrites','StreamPointwiseReduction','OverlapMacRequantization',
    'ScalarReadBeatCache','PreciseWriteInvalidate','VirtualUpsampleTensors','StreamDwGroups',
    'ReuseHorizontalWindow','CacheDwWeightTiles','MacPrefetchOverlap','PipelinedResultWrites',
    'TensorPackedWrites','TensorWriteEnd','ColumnWriteOverlap','PointwiseColumnReads',
    'PackRgbReduction','ElideViews','ReuseColumnRowMap','FuseFinalOutput','StreamDwFrame')){
    $c1Options[$c1Flag]=$true
}
if($Scenario -eq 'TwoFrame'){
    $c1Options.TwoFrame=$true; $c1Options.TwoFrameTrace=$true
} else {$c1Options.NumericalTrace=$true}
if($Scenario -in @('ReadAbort','WriteAbort')){
    $c1Options.ConcurrentCapture=$true; $c1Options.SourceGeometry=$true
    if($Scenario -eq 'ReadAbort'){
        $c1Options.InflightReadAbort=$true; $c1Options.VirtualUpsampleReadAbort=$true
        $c1Options.PixelPrefetchReadAbort=$true
    }else{
        $c1Options.InflightWriteAbort=$true; $c1Options.DwPixelWriteAbort=$true
    }
}
if($RefillMode -in @('Handoff','Wide')){$c1Options.RefillRequestHandoff=$true}
if($WarmScalarAbort){
    $c1Options.Remove('VirtualUpsampleReadAbort')
    $c1Options.Remove('PixelPrefetchReadAbort')
    $c1Options.ScalarReadAbort=$true; $c1Options.ScalarAssocReadAbort=$true
}
if($RefillMode -in @('WindowOnly','Wide')){$c1Options.WideRefillWindow=$true}
if($RunId){$c1Options.RunId=$RunId}
if($DryRun){$c1Options | ConvertTo-Json; return}
& (Join-Path $PSScriptRoot 'run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1') @c1Options
