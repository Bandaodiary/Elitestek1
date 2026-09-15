param([switch]$Worker, [string]$RunId = '', [switch]$TwoFrame, [switch]$TwoFrameTrace,
      [string]$Python = 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe',
      [ValidateSet('8x8','16x8','16x16','64x48','640x480')][string]$Frame = '8x8',
      [switch]$CompileOnly, [switch]$ClientTrafficGate,
      [switch]$SharedQosMonitor,
      [switch]$TrainedArtifact,
      [switch]$TensorBurstRefill,
      [switch]$TensorColumnReads,
      [switch]$ColumnReadOnLookup,
      [switch]$ColumnResponseBypass,
      [switch]$ReuseColumnRowMap,
      [switch]$PixelColumnPrefetch,
      [switch]$AllPixelGroups,
      [switch]$PipelinedSourceWrites,
      [switch]$SourceWriteAbort,
      [switch]$PixelPrefetchReadAbort,
      [switch]$ScalarReadBeatCache,
      [ValidateSet(1,2)][int]$ScalarReadCacheEntries=1,
      [switch]$PreciseWriteInvalidate,
      [switch]$VirtualUpsampleTensors,
      [switch]$VirtualUpsampleReadAbort,
      [switch]$StreamDwGroups,
      [switch]$StreamPointwiseReduction,
      [switch]$OverlapMacRequantization,
      [switch]$PipelineDotPixels,
      [switch]$AllDotGroups,
      [switch]$PackRgbReduction,
      [switch]$ElideViews,
      [switch]$FuseFinalOutput,
      [switch]$PipelineDwPixels,
      [switch]$StreamDwFrame,
      [switch]$DotPixelWriteAbort,
      [switch]$AllDotPixelWriteAbort,
      [switch]$DwPixelWriteAbort,
      [ValidateSet(1,2,4)][int]$TensorWriteOutstanding=1,
      [ValidateSet(1,2,4,8)][int]$PixelWriteBatchWords=1,
      [ValidateRange(1,255)][int]$TensorWriteBuildTimeout=8,
      [switch]$PointwiseReductionReadAbort,
      [switch]$ColumnWriteOverlap,
      [switch]$PointwiseColumnReads,
      [switch]$TensorBurstBeatMode,
      [switch]$DisplayResponseFifo, [switch]$RelaxedDescriptor,
       [switch]$FastAddress, [switch]$PipelinedAddress,
       [switch]$PipelinedPixelIndex, [switch]$PrefetchNextTapAddress,
       [switch]$ReuseHorizontalWindow,
       [switch]$PipelinedDescriptorValidation,
       [switch]$NarrowDescriptorSizeCheck,
       [switch]$PipelinedDescriptorSizeArith,
       [switch]$FixedDescriptorSizeLimits,
       [switch]$PipelinedDescriptorPixelCount,
       [switch]$IterativeDescriptorPixelCount,
       [switch]$PreclampedTapCoords,
       [switch]$RegisterAbortReset,
      [switch]$PipelinedStartConfig, [switch]$PipelinedDotTree,
      [switch]$PipelinedDotTreeFull, [switch]$PipelinedDescriptorReplay,
      [switch]$CacheDwWeightTiles, [switch]$MacPrefetchOverlap,
      [switch]$PrevalidateDescriptorReplay, [switch]$ReplicateAbortControl,
      [switch]$PipelinedDecoderValidation,
      [switch]$TableResponseFifo, [switch]$UnifiedOutputFifo,
      [switch]$UnifiedOutputSkid, [switch]$FabricReadResponseSkid,
      [switch]$RegisterFatalTicket, [switch]$ConcurrentDisplayPrefetch,
      [switch]$DisplayFaultRecovery, [switch]$PipelinedResultWrites,
      [switch]$TensorPackedWrites, [switch]$TensorWriteEnd, [switch]$NumericalTrace,
      [switch]$ColorFixture, [switch]$ResizeFixture, [switch]$SourceGeometry, [switch]$RejectGeometry,
      [switch]$QueuedWriteFabric, [switch]$ConcurrentCapture, [switch]$InflightWriteAbort,
      [switch]$SerializeWriteData, [switch]$RawRasterFault, [switch]$RawMissingEof, [switch]$RawIdleTimeout, [switch]$ExplicitCaptureRecovery, [switch]$RecoveryLateSourceAck, [switch]$ApbCaptureRecovery,
      [switch]$InflightReadAbort,
      [switch]$ScalarReadAbort,
      [switch]$ScalarAssocReadAbort,
      [switch]$CompactRefillFifos,
      [switch]$WideRefillWindow,
      [switch]$RefillRequestHandoff, [switch]$PreviewCapture, [switch]$PreviewBrespError, [switch]$PreviewBrespRecovery, [switch]$PreviewCancel, [switch]$PreviewCancelRecovery, [switch]$PreviewDisplay, [switch]$DistinctRecoveryFrame,
      [ValidateSet('none','legacy','separate')][string]$BoardlessGeometry='none',
      [ValidateRange(0,255)][int]$ReadFirstExtraCycles=0,
      [ValidateRange(0,255)][int]$ReadBeatExtraCycles=0,
      [ValidateRange(0,255)][int]$WriteResponseExtraCycles=0)

# The outer process is created through Win32_Process.Create so Vivado/xsim
# are outside the caller's Windows Job.  This is important for long xsim runs
# from the desktop agent and mirrors the other detached Case-1 runners.
$ErrorActionPreference = 'Stop'
if($TensorWriteOutstanding -ne 1 -and (-not $TensorPackedWrites -or -not $TensorColumnReads)){
    throw 'TensorWriteOutstanding >1 requires TensorPackedWrites and TensorColumnReads'
}
if($PixelWriteBatchWords -ne 1 -and ((-not $PipelineDotPixels -and -not $PipelineDwPixels) -or -not $TensorPackedWrites -or -not $TensorWriteEnd)){
    throw 'PixelWriteBatchWords >1 requires PipelineDotPixels or PipelineDwPixels, plus TensorPackedWrites and TensorWriteEnd'
}
if($TensorWriteBuildTimeout -ne 8 -and (-not $TensorPackedWrites -or -not $TensorColumnReads)){
    throw 'TensorWriteBuildTimeout requires TensorPackedWrites and TensorColumnReads'
}
if($TrainedArtifact -and $Frame -notin @('8x8','16x8','16x16','64x48')) { throw 'TrainedArtifact supports size-matched frames through 64x48 only' }
if($TrainedArtifact -and $Frame -ne '8x8' -and
   (-not $NumericalTrace -or $TwoFrame -or $SourceGeometry -or $ResizeFixture -or $PreviewCapture -or $ClientTrafficGate -or $SharedQosMonitor)) {
    throw 'Extended trained frames require a single normal NumericalTrace; geometry/preview/recovery and multi-job scoreboards remain 8x8'
}
if($TensorColumnReads -and $TensorBurstRefill){throw 'ColumnReads replaces the scalar burst client; do not combine the two test profiles'}
if($ColumnReadOnLookup -and -not $TensorColumnReads){throw 'ColumnReadOnLookup requires TensorColumnReads'}
if($ColumnResponseBypass -and -not $TensorColumnReads){throw 'ColumnResponseBypass requires TensorColumnReads'}
if($ReuseColumnRowMap -and -not $TensorColumnReads){throw 'ReuseColumnRowMap requires TensorColumnReads'}
if($PixelColumnPrefetch -and -not $ColumnWriteOverlap){throw 'PixelColumnPrefetch requires ColumnWriteOverlap'}
if($AllPixelGroups -and -not $PixelColumnPrefetch){throw 'AllPixelGroups requires PixelColumnPrefetch'}
if($PipelineDotPixels -and (-not $OverlapMacRequantization -or -not $ColumnWriteOverlap)){
    throw 'PipelineDotPixels requires OverlapMacRequantization and ColumnWriteOverlap'
}
if($AllDotGroups -and -not $PipelineDotPixels){throw 'AllDotGroups requires PipelineDotPixels'}
if($ElideViews -and (-not $VirtualUpsampleTensors -or -not $TensorColumnReads)){
    throw 'ElideViews requires VirtualUpsampleTensors and TensorColumnReads'
}
if($FuseFinalOutput -and $DotPixelWriteAbort){throw 'Final fusion has no stage20 tensor writes; use another actual write-abort target'}
if($AllDotPixelWriteAbort -and (-not $AllDotGroups -or -not $InflightWriteAbort -or
    $DotPixelWriteAbort -or $DwPixelWriteAbort -or $SourceWriteAbort -or $RawRasterFault)){
    throw 'AllDotPixelWriteAbort requires AllDotGroups and InflightWriteAbort without another abort selector'
}
if($PipelineDwPixels -and (-not $StreamDwGroups -or -not $CacheDwWeightTiles -or -not $ColumnWriteOverlap)){
    throw 'PipelineDwPixels requires StreamDwGroups, CacheDwWeightTiles and ColumnWriteOverlap'
}
if($StreamDwFrame -and -not $PipelineDwPixels){throw 'StreamDwFrame requires PipelineDwPixels'}
if($DotPixelWriteAbort -and (-not $PipelineDotPixels -or -not $InflightWriteAbort -or $SourceWriteAbort -or $RawRasterFault)){
    throw 'DotPixelWriteAbort requires PipelineDotPixels and InflightWriteAbort, without other write-abort selectors'
}
if($DwPixelWriteAbort -and (-not $PipelineDwPixels -or -not $InflightWriteAbort -or $DotPixelWriteAbort -or $SourceWriteAbort -or $RawRasterFault)){
    throw 'DwPixelWriteAbort requires PipelineDwPixels and InflightWriteAbort without other write-abort selectors'
}
if($SourceWriteAbort -and (-not $PipelinedSourceWrites -or -not $InflightWriteAbort -or $RawRasterFault)){
    throw 'SourceWriteAbort requires PipelinedSourceWrites and InflightWriteAbort, without RawRasterFault'
}
if($PixelPrefetchReadAbort -and (-not $PixelColumnPrefetch -or -not $VirtualUpsampleReadAbort)){
    throw 'PixelPrefetchReadAbort requires PixelColumnPrefetch and VirtualUpsampleReadAbort'
}
if($ScalarReadBeatCache -and -not $TensorColumnReads){throw 'ScalarReadBeatCache requires TensorColumnReads'}
if($ScalarReadCacheEntries -ne 1 -and (-not $ScalarReadBeatCache -or -not ($NumericalTrace -or $TwoFrameTrace))){
    throw 'Two scalar read entries require ScalarReadBeatCache and a numerical trace'
}
if($PreciseWriteInvalidate -and -not $ScalarReadBeatCache){throw 'PreciseWriteInvalidate requires ScalarReadBeatCache'}
if($VirtualUpsampleTensors -and -not $TensorColumnReads){throw 'VirtualUpsampleTensors requires TensorColumnReads'}
if($StreamDwGroups -and -not $CacheDwWeightTiles){throw 'StreamDwGroups requires CacheDwWeightTiles'}
if($PointwiseReductionReadAbort -and (-not $StreamPointwiseReduction -or -not $InflightReadAbort -or
    -not $TensorColumnReads -or $PointwiseColumnReads -or $ScalarReadBeatCache -or $VirtualUpsampleReadAbort)){
    throw 'PointwiseReductionReadAbort requires StreamPointwiseReduction, InflightReadAbort, TensorColumnReads; disable PointwiseColumnReads, ScalarReadBeatCache and VirtualUpsampleReadAbort'
}
if($ColumnWriteOverlap -and (-not $TensorColumnReads -or -not $PipelinedResultWrites)){throw 'ColumnWriteOverlap requires TensorColumnReads and PipelinedResultWrites'}
if($PointwiseColumnReads -and -not $TensorColumnReads){throw 'PointwiseColumnReads requires TensorColumnReads'}
if($VirtualUpsampleReadAbort -and (-not $VirtualUpsampleTensors -or -not $InflightReadAbort -or $ScalarReadAbort)) {
    throw 'VirtualUpsampleReadAbort requires virtual tensors and column InflightReadAbort, not ScalarReadAbort'
}
if($ScalarReadAbort -and (-not $InflightReadAbort -or -not $ScalarReadBeatCache -or -not $NumericalTrace)) {
    throw 'ScalarReadAbort requires InflightReadAbort, ScalarReadBeatCache and NumericalTrace'
}
if($ScalarAssocReadAbort -and (-not $ScalarReadAbort -or $ScalarReadCacheEntries -ne 2 -or -not $PreciseWriteInvalidate)){
    throw 'ScalarAssocReadAbort requires ScalarReadAbort, two cache entries and precise invalidation'
}
if($TwoFrameTrace -and (-not $TwoFrame -or -not $TrainedArtifact -or $Frame -ne '8x8' -or $NumericalTrace -or $DisplayFaultRecovery -or $ClientTrafficGate)) {
    throw 'TwoFrameTrace requires TwoFrame + TrainedArtifact 8x8 and excludes single-frame numerical/fault modes'
}
if($TwoFrameTrace -and ($PreviewCancel -or $PreviewBrespError -or $ConcurrentCapture -or $RejectGeometry -or (($SourceGeometry -or $PreviewCapture) -and -not $PreviewDisplay))) {
    throw 'TwoFrameTrace supports successful serialized jobs; source geometry requires PreviewDisplay'
}
if($BoardlessGeometry -ne 'none') {
    foreach($key in $PSBoundParameters.Keys) {
        if($key -notin @('Worker','RunId','BoardlessGeometry','CompileOnly','Python')) {
            throw "BoardlessGeometry cannot be combined with $key"
        }
    }
}
if ($ColorFixture -and -not ($NumericalTrace -or $TwoFrameTrace)) { throw 'ColorFixture requires a numerical trace mode' }
if ($PreviewBrespError -and (-not $PreviewCapture -or $ConcurrentCapture)) { throw 'PreviewBrespError requires PreviewCapture and excludes ConcurrentCapture' }
if ($PreviewBrespRecovery -and -not $PreviewBrespError) { throw 'PreviewBrespRecovery requires PreviewBrespError' }
if ($PreviewCancel -and (-not $PreviewCapture -or $PreviewBrespError -or $ConcurrentCapture)) { throw 'PreviewCancel requires PreviewCapture and excludes PreviewBrespError/ConcurrentCapture' }
if ($PreviewCancelRecovery -and -not $PreviewCancel) { throw 'PreviewCancelRecovery requires PreviewCancel' }
if ($DistinctRecoveryFrame -and (-not ($PreviewCancelRecovery -or $PreviewBrespRecovery) -or -not $ColorFixture)) { throw 'DistinctRecoveryFrame requires colored preview recovery' }
if ($PreviewDisplay -and (-not $PreviewCapture -or ($PreviewCancel -and -not $PreviewCancelRecovery) -or ($PreviewBrespError -and -not $PreviewBrespRecovery))) { throw 'PreviewDisplay requires PreviewCapture and complete recovery when cancel/fault is enabled' }
if ($PreviewCapture -and (-not $SourceGeometry -or -not $QueuedWriteFabric -or $InflightReadAbort -or $InflightWriteAbort)) { throw 'PreviewCapture requires SourceGeometry and QueuedWriteFabric, without abort modes' }
if ($QueuedWriteFabric -and -not ($NumericalTrace -or $TwoFrameTrace)) { throw 'QueuedWriteFabric requires a numerical trace mode' }
if ($ConcurrentCapture -and (-not $QueuedWriteFabric -or -not $SourceGeometry -or $RejectGeometry)) { throw 'ConcurrentCapture requires QueuedWriteFabric and SourceGeometry; excludes RejectGeometry' }
if ($InflightWriteAbort -and -not $ConcurrentCapture) { throw 'InflightWriteAbort requires ConcurrentCapture' }
if ($RawRasterFault -and (-not $InflightWriteAbort -or -not $TrainedArtifact -or -not $NumericalTrace)) { throw 'RawRasterFault requires InflightWriteAbort, TrainedArtifact and NumericalTrace' }
if ($RawMissingEof -and -not $RawRasterFault) { throw 'RawMissingEof requires RawRasterFault' }
if ($RawIdleTimeout -and (-not $RawRasterFault -or $RawMissingEof)) { throw 'RawIdleTimeout requires RawRasterFault and excludes RawMissingEof' }
if ($ExplicitCaptureRecovery -and -not $RawIdleTimeout) { throw 'ExplicitCaptureRecovery requires RawIdleTimeout' }
if ($RecoveryLateSourceAck -and -not $ExplicitCaptureRecovery) { throw 'RecoveryLateSourceAck requires ExplicitCaptureRecovery' }
if ($ApbCaptureRecovery -and -not $ExplicitCaptureRecovery) { throw 'ApbCaptureRecovery requires ExplicitCaptureRecovery' }
if ($SerializeWriteData -and ((-not $ConcurrentCapture -and -not $PreviewCancel) -or $InflightWriteAbort -or $InflightReadAbort)) { throw 'SerializeWriteData requires ConcurrentCapture or PreviewCancel and excludes inflight abort modes' }
if ($InflightReadAbort -and (-not $ConcurrentCapture -or (-not $TensorBurstRefill -and -not $TensorColumnReads) -or $InflightWriteAbort)) { throw 'InflightReadAbort requires ConcurrentCapture and a burst or column tensor path; excludes InflightWriteAbort' }
if ($CompactRefillFifos -and (-not $TensorBurstRefill -or -not $NumericalTrace -or $TensorBurstBeatMode)) { throw 'CompactRefillFifos requires numerical burst refill and excludes beat FIFO mode' }
if ($WideRefillWindow -and ((-not $TensorBurstRefill -and -not $TensorColumnReads) -or -not ($NumericalTrace -or $TwoFrameTrace) -or $CompactRefillFifos)) { throw 'WideRefillWindow requires a numerical burst/column path and excludes CompactRefillFifos' }
if ($RefillRequestHandoff -and ((-not $TensorBurstRefill -and -not $TensorColumnReads) -or -not ($NumericalTrace -or $TwoFrameTrace))) { throw 'RefillRequestHandoff requires a numerical burst/column path' }
if ($ResizeFixture -and -not $NumericalTrace) { throw 'ResizeFixture requires NumericalTrace' }
if ($SourceGeometry -and (-not ($NumericalTrace -or $TwoFrameTrace) -or $ResizeFixture)) { throw 'SourceGeometry requires a numerical trace mode and excludes ResizeFixture' }
if ($RejectGeometry -and (-not $SourceGeometry -or $DisplayFaultRecovery)) { throw 'RejectGeometry requires SourceGeometry and excludes DisplayFaultRecovery' }
if ($NumericalTrace -and (-not $TrainedArtifact -or $TwoFrame -or $Frame -notin @('8x8','16x8','16x16','64x48'))) {
    throw 'NumericalTrace requires a single-frame, size-matched TrainedArtifact run (through 64x48)'
}
if ($TensorWriteEnd -and -not $TensorPackedWrites) { throw 'TensorWriteEnd requires TensorPackedWrites' }
if ($TensorPackedWrites -and -not $TensorBurstRefill -and -not $TensorColumnReads) {
    throw 'TensorPackedWrites requires a burst or column tensor path'
}
if ($DisplayFaultRecovery -and ($TwoFrame -or $SharedQosMonitor -or $TrainedArtifact -or $ClientTrafficGate)) {
    throw 'DisplayFaultRecovery uses its own two-job/error/restart scoreboard; do not combine other lifecycle modes'
}
if ($ConcurrentDisplayPrefetch -and -not $DisplayResponseFifo) {
    throw 'ConcurrentDisplayPrefetch requires DisplayResponseFifo'
}
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
        '" -Worker -RunId ' + $RunId + ' -Python "' + $Python + '"' + $(if($TwoFrame){' -TwoFrame'}else{''}) +
        $(if($TwoFrameTrace){' -TwoFrameTrace'}else{''}) +
        ' -Frame ' + $Frame + $(if($CompileOnly){' -CompileOnly'}else{''}) +
        $(if($ClientTrafficGate){' -ClientTrafficGate'}else{''}) +
        $(if($SharedQosMonitor){' -SharedQosMonitor'}else{''}) +
        $(if($TrainedArtifact){' -TrainedArtifact'}else{''}) +
        $(if($TensorBurstRefill){' -TensorBurstRefill'}else{''}) +
        $(if($TensorBurstBeatMode){' -TensorBurstBeatMode'}else{''}) +
        $(if($DisplayResponseFifo){' -DisplayResponseFifo'}else{''}) +
        $(if($ConcurrentDisplayPrefetch){' -ConcurrentDisplayPrefetch'}else{''}) +
        $(if($DisplayFaultRecovery){' -DisplayFaultRecovery'}else{''}) +
        $(if($RelaxedDescriptor){' -RelaxedDescriptor'}else{''}) +
         $(if($FastAddress){' -FastAddress'}else{''}) +
         $(if($PipelinedAddress){' -PipelinedAddress'}else{''}) +
         $(if($PipelinedPixelIndex){' -PipelinedPixelIndex'}else{''}) +
         $(if($PrefetchNextTapAddress){' -PrefetchNextTapAddress'}else{''}) +
         $(if($ReuseHorizontalWindow){' -ReuseHorizontalWindow'}else{''}) +
         $(if($TensorColumnReads){' -TensorColumnReads'}else{''}) +
         $(if($ColumnReadOnLookup){' -ColumnReadOnLookup'}else{''}) +
         $(if($ColumnResponseBypass){' -ColumnResponseBypass'}else{''}) +
         $(if($ReuseColumnRowMap){' -ReuseColumnRowMap'}else{''}) +
         $(if($PixelColumnPrefetch){' -PixelColumnPrefetch'}else{''}) +
         $(if($AllPixelGroups){' -AllPixelGroups'}else{''}) +
         $(if($PipelinedSourceWrites){' -PipelinedSourceWrites'}else{''}) +
         $(if($SourceWriteAbort){' -SourceWriteAbort'}else{''}) +
         $(if($PixelPrefetchReadAbort){' -PixelPrefetchReadAbort'}else{''}) +
         $(if($ScalarReadBeatCache){' -ScalarReadBeatCache'}else{''}) +
         " -ScalarReadCacheEntries $ScalarReadCacheEntries" +
         $(if($PreciseWriteInvalidate){' -PreciseWriteInvalidate'}else{''}) +
         $(if($VirtualUpsampleTensors){' -VirtualUpsampleTensors'}else{''}) +
         $(if($VirtualUpsampleReadAbort){' -VirtualUpsampleReadAbort'}else{''}) +
         $(if($StreamDwGroups){' -StreamDwGroups'}else{''}) +
         $(if($StreamPointwiseReduction){' -StreamPointwiseReduction'}else{''}) +
         $(if($OverlapMacRequantization){' -OverlapMacRequantization'}else{''}) +
         $(if($PipelineDotPixels){' -PipelineDotPixels'}else{''}) +
         $(if($AllDotGroups){' -AllDotGroups'}else{''}) +
         $(if($PackRgbReduction){' -PackRgbReduction'}else{''}) +
         $(if($ElideViews){' -ElideViews'}else{''}) +
         $(if($FuseFinalOutput){' -FuseFinalOutput'}else{''}) +
         $(if($AllDotPixelWriteAbort){' -AllDotPixelWriteAbort'}else{''}) +
         $(if($PipelineDwPixels){' -PipelineDwPixels'}else{''}) +
         $(if($StreamDwFrame){' -StreamDwFrame'}else{''}) +
         $(if($DotPixelWriteAbort){' -DotPixelWriteAbort'}else{''}) +
         $(if($DwPixelWriteAbort){' -DwPixelWriteAbort'}else{''}) +
         (' -TensorWriteOutstanding '+$TensorWriteOutstanding) +
         (' -PixelWriteBatchWords '+$PixelWriteBatchWords) +
         (' -TensorWriteBuildTimeout '+$TensorWriteBuildTimeout) +
         $(if($PointwiseReductionReadAbort){' -PointwiseReductionReadAbort'}else{''}) +
         $(if($ColumnWriteOverlap){' -ColumnWriteOverlap'}else{''}) +
         $(if($PointwiseColumnReads){' -PointwiseColumnReads'}else{''}) +
        $(if($PipelinedDescriptorValidation){' -PipelinedDescriptorValidation'}else{''}) +
        $(if($NarrowDescriptorSizeCheck){' -NarrowDescriptorSizeCheck'}else{''}) +
        $(if($PipelinedDescriptorSizeArith){' -PipelinedDescriptorSizeArith'}else{''}) +
          $(if($FixedDescriptorSizeLimits){' -FixedDescriptorSizeLimits'}else{''}) +
          $(if($PipelinedDescriptorPixelCount){' -PipelinedDescriptorPixelCount'}else{''}) +
          $(if($IterativeDescriptorPixelCount){' -IterativeDescriptorPixelCount'}else{''}) +
          $(if($PreclampedTapCoords){' -PreclampedTapCoords'}else{''}) +
          $(if($RegisterAbortReset){' -RegisterAbortReset'}else{''}) +
        $(if($PipelinedStartConfig){' -PipelinedStartConfig'}else{''}) +
        $(if($PipelinedDotTree){' -PipelinedDotTree'}else{''}) +
        $(if($PipelinedDotTreeFull){' -PipelinedDotTreeFull'}else{''}) +
        $(if($CacheDwWeightTiles){' -CacheDwWeightTiles'}else{''}) +
        $(if($MacPrefetchOverlap){' -MacPrefetchOverlap'}else{''}) +
        $(if($PipelinedDescriptorReplay){' -PipelinedDescriptorReplay'}else{''}) +
        $(if($PrevalidateDescriptorReplay){' -PrevalidateDescriptorReplay'}else{''}) +
        $(if($PipelinedDecoderValidation){' -PipelinedDecoderValidation'}else{''}) +
        $(if($ReplicateAbortControl){' -ReplicateAbortControl'}else{''}) +
        $(if($TableResponseFifo){' -TableResponseFifo'}else{''}) +
        $(if($UnifiedOutputFifo){' -UnifiedOutputFifo'}else{''}) +
        $(if($UnifiedOutputSkid){' -UnifiedOutputSkid'}else{''}) +
        $(if($FabricReadResponseSkid){' -FabricReadResponseSkid'}else{''}) +
        $(if($RegisterFatalTicket){' -RegisterFatalTicket'}else{''}) +
        $(if($PipelinedResultWrites){' -PipelinedResultWrites'}else{''}) +
        $(if($TensorPackedWrites){' -TensorPackedWrites'}else{''}) +
        $(if($TensorWriteEnd){' -TensorWriteEnd'}else{''}) +
        $(if($NumericalTrace){' -NumericalTrace'}else{''}) +
        $(if($ColorFixture){' -ColorFixture'}else{''}) +
        $(if($ResizeFixture){' -ResizeFixture'}else{''}) +
        $(if($SourceGeometry){' -SourceGeometry'}else{''}) +
        $(if($RejectGeometry){' -RejectGeometry'}else{''}) +
        $(if($QueuedWriteFabric){' -QueuedWriteFabric'}else{''}) +
        $(if($ConcurrentCapture){' -ConcurrentCapture'}else{''}) +
        $(if($InflightWriteAbort){' -InflightWriteAbort'}else{''}) +
        $(if($RawRasterFault){' -RawRasterFault'}else{''}) +
        $(if($RawMissingEof){' -RawMissingEof'}else{''}) +
        $(if($RawIdleTimeout){' -RawIdleTimeout'}else{''}) +
        $(if($ExplicitCaptureRecovery){' -ExplicitCaptureRecovery'}else{''}) +
        $(if($RecoveryLateSourceAck){' -RecoveryLateSourceAck'}else{''}) +
        $(if($ApbCaptureRecovery){' -ApbCaptureRecovery'}else{''}) +
        $(if($SerializeWriteData){' -SerializeWriteData'}else{''}) +
        $(if($InflightReadAbort){' -InflightReadAbort'}else{''}) +
        $(if($ScalarReadAbort){' -ScalarReadAbort'}else{''}) +
        $(if($ScalarAssocReadAbort){' -ScalarAssocReadAbort'}else{''}) +
        $(if($CompactRefillFifos){' -CompactRefillFifos'}else{''}) +
        $(if($WideRefillWindow){' -WideRefillWindow'}else{''}) +
        $(if($RefillRequestHandoff){' -RefillRequestHandoff'}else{''}) +
        $(if($PreviewCapture){' -PreviewCapture'}else{''}) +
        $(if($PreviewBrespError){' -PreviewBrespError'}else{''}) +
        $(if($PreviewBrespRecovery){' -PreviewBrespRecovery'}else{''}) +
        $(if($PreviewCancel){' -PreviewCancel'}else{''}) +
        $(if($PreviewCancelRecovery){' -PreviewCancelRecovery'}else{''}) +
        $(if($PreviewDisplay){' -PreviewDisplay'}else{''}) +
        $(if($DistinctRecoveryFrame){' -DistinctRecoveryFrame'}else{''}) +
        ' -ReadFirstExtraCycles '+$ReadFirstExtraCycles+
        ' -ReadBeatExtraCycles '+$ReadBeatExtraCycles+
        ' -WriteResponseExtraCycles '+$WriteResponseExtraCycles
    if($BoardlessGeometry -ne 'none') {
        $commandLine='"'+$powerShell+'" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$PSCommandPath+'" -Worker -RunId '+$RunId+' -BoardlessGeometry '+$BoardlessGeometry+$(if($CompileOnly){' -CompileOnly'}else{''})
    }
    # Prefer WMI because it creates the worker outside the caller's Windows
    # Job.  Some managed desktops deny Win32_Process.Create, so fall back to
    # a tiny CreateProcess(CREATE_BREAKAWAY_FROM_JOB) helper.  The fallback
    # still leaves Vivado/xsim independent of this shell/job.
    $workerPid = $null
    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{CommandLine=$commandLine; CurrentDirectory=$caseRoot}
        if ($result.ReturnValue -eq 0) { $workerPid = [int]$result.ProcessId }
    } catch {
        $result = $null
    }
    if ($null -eq $workerPid) {
        $launcher = Join-Path $PSScriptRoot 'start_detached_process.ps1'
        $launcherOutput = & $powerShell -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $launcher -CommandLine $commandLine `
            -CurrentDirectory $caseRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "detached process fallback failed: $($launcherOutput -join ' ')"
        }
        try { $workerPid = [int](($launcherOutput | Select-Object -Last 1).ToString().Trim()) }
        catch { throw "detached process fallback returned invalid pid: $($launcherOutput -join ' ')" }
    }
    [ordered]@{ run_id=$RunId; worker_pid=$workerPid;
        status_path=(Join-Path $logRoot "portable_soc_cache_ddr_bfm_runs\$RunId\status.json") } |
        ConvertTo-Json
    return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'bad RunId' }
$runRoot = Join-Path $simRoot "portable_soc_cache_ddr_bfm_run_$RunId"
$runLogRoot = Join-Path $logRoot "portable_soc_cache_ddr_bfm_runs\$RunId"
$statusPath = Join-Path $runLogRoot 'status.json'
$latestStatusPath = Join-Path $logRoot 'portable_soc_cache_ddr_bfm_status.json'
$trainedArtifactRoot = Join-Path $caseRoot 'model\microstyle24_starry_functional'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$watch = [Diagnostics.Stopwatch]::StartNew(); $script:currentStep='setup'
New-Item -ItemType Directory -Force -Path $runRoot,$runLogRoot | Out-Null

function Set-StatusContent([string]$Path,[string]$Value) {
    # Publish one complete JSON record under an exclusive file handle. Native
    # Windows ReplaceFile can expose a transient missing path across writers;
    # keep the pathname stable instead. Readers must retry sharing conflicts,
    # never interpret them as simulator termination. Per-run status is primary.
    $statusTarget=[IO.Path]::GetFullPath($Path)
    [byte[]]$statusBytes=[Text.Encoding]::UTF8.GetPreamble()+[Text.Encoding]::UTF8.GetBytes($Value)
    for($statusAttempt=0;$statusAttempt -lt 8;$statusAttempt++) {
        $statusStream=$null
        try {
            $statusStream=[IO.File]::Open($statusTarget,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $statusStream.Write($statusBytes,0,$statusBytes.Length)
            $statusStream.Flush()
            return
        } catch {
            $statusCause=$_.Exception.GetBaseException()
            if($statusAttempt -eq 7 -or (-not ($statusCause -is [IO.IOException]) -and
                -not ($statusCause -is [UnauthorizedAccessException]))){throw}
        } finally {
            if($null -ne $statusStream){$statusStream.Dispose()}
        }
        Start-Sleep -Milliseconds 25
    }
}
function Write-Status([string]$State,[string]$Step,[int]$ExitCode,[string]$Message) {
    $value=[ordered]@{run_id=$RunId;frame=$Frame;state=$State;step=$Step;exit_code=$ExitCode;
        numerical_trace_schema=$(if($NumericalTrace){2}else{0});
        message=$Message;process_id=$PID;
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);
        updated=(Get-Date).ToString('o');log_directory=$runLogRoot;run_directory=$runRoot} |
        ConvertTo-Json
    Set-StatusContent $statusPath $value
    try {Set-StatusContent $latestStatusPath $value}
    catch {Write-Warning 'Latest-status pointer unavailable; per-run status remains authoritative.'}
}
function Save-CompactLog([string]$Source,[string]$Destination,[string]$Marker='') {
    # Keep persistent diagnostics bounded even when a native xsim emits one
    # line per pixel.  The complete stream lives only below runRoot and is
    # removed by the worker's finally block.
    $lines=@()
    $retainedPattern=$null
    if(Test-Path -LiteralPath $Source){
        if($Marker){
            # Keep bounded numeric traces and cancellation evidence exactly,
            # including duplicates: the checker must be able to reject them.
            $retainedPattern=([regex]::Escape($Marker)) + '|^C1_PERF_|^C1_NUM_|^C1_VIEW_|^C1_FINAL_FUSION_|^C1_SOC_RAW_|^C1_SOC_EXPLICIT_RECOVERY_|^C1_SOC_INFLIGHT_(WRITE|READ)_ABORT_|^C1_SOC_SCALAR_READ_ABORT_|^C1_SOC_PREVIEW_(BRESP|CANCEL)_'
            $lines += @(Select-String -LiteralPath $Source -Pattern $retainedPattern -AllMatches -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Line })
        }
        $lines += @(Get-Content -LiteralPath $Source -Tail 80 -ErrorAction SilentlyContinue |
                    Where-Object { !$retainedPattern -or $_ -notmatch $retainedPattern })
    }
    if($lines.Count -eq 0){$lines=@('(empty)')}
    $lines | Set-Content -LiteralPath $Destination -Encoding UTF8
}
function Invoke-XsimStep {
    param([string]$Name,[string]$Tool,[string[]]$Arguments,[string]$ExpectedPass='')
    $script:currentStep=$Name; Write-Status running $Name 0 "starting $Name"
    $rawOut=Join-Path $runRoot "$Name.stdout.raw.log"; $rawErr=Join-Path $runRoot "$Name.stderr.raw.log"
    $out=Join-Path $runLogRoot "$Name.stdout.log"; $err=Join-Path $runLogRoot "$Name.stderr.log"
    try {
        $p=Start-Process -FilePath $Tool -ArgumentList $Arguments -WorkingDirectory $runRoot `
            -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $rawOut -RedirectStandardError $rawErr
        if($p.ExitCode -ne 0){throw "$Name exit $($p.ExitCode)"}
        # Do not load an entire Vivado/xsim log into the worker process.  Native
        # frame runs can produce hundreds of megabytes of stdout; stream the
        # checks line-by-line and retain only a short tail in a failure message.
        $badPattern='(?i)^\s*(ERROR|FATAL):|\bFAIL\b|_[Ff][Aa][Ii][Ll]\b|cannot be opened|\$\s*fatal'
        if(Select-String -LiteralPath $rawErr -Pattern '\S' -Quiet -ErrorAction SilentlyContinue){
            $tail=((Get-Content -LiteralPath $rawErr -Tail 12 -ErrorAction SilentlyContinue) -join ' ')
            throw "$Name unexpected stderr: $tail"
        }
        if(Select-String -LiteralPath $rawOut -Pattern $badPattern -Quiet -ErrorAction SilentlyContinue){
            $tail=((Get-Content -LiteralPath $rawOut -Tail 12 -ErrorAction SilentlyContinue) -join ' ')
            throw "$Name log contains ERROR/FATAL/FAIL: $tail"
        }
        if($ExpectedPass){
            $n=0
            foreach($hit in @(Select-String -LiteralPath $rawOut -Pattern ([regex]::Escape($ExpectedPass)) -AllMatches -ErrorAction SilentlyContinue)){
                if($hit.Matches){$n += $hit.Matches.Count}else{$n++}
            }
            if($n -ne 1){throw "$Name missing unique marker count=$n"}
        }
    } finally {
        Save-CompactLog $rawOut $out $ExpectedPass
        Save-CompactLog $rawErr $err
    }
}

try {
    Write-Status running setup 0 'detached portable SoC cache DDR BFM started'
    $packageSources=@(
        (Join-Path $rtlRoot 'common\c1_fixed_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_descriptor_decoder_pkg.sv'),
        (Join-Path $rtlRoot 'control\c1_frame_buffer_pkg.sv'))
    $packageSet=@{}; foreach($s in $packageSources){$packageSet[$s]=$true}
    $remaining=Get-ChildItem -LiteralPath $rtlRoot -Recurse -File -Filter '*.sv' |
        Where-Object {-not $packageSet.ContainsKey($_.FullName)} |
        Sort-Object FullName | Select-Object -ExpandProperty FullName
    $testTop=if($BoardlessGeometry -eq 'none'){'tb_c1_r1_portable_soc_cache_ddr_bfm'}else{'tb_c1_r1_boardless_frame_system'}
    $sources=@($packageSources)+@($remaining)+@((Join-Path $simRoot ($testTop+'.sv')))
    if ($ClientTrafficGate) {
        $sources += (Join-Path $simRoot 'c1_axi_client_traffic_monitor.sv')
    }
    # Native-shape elaboration now includes more than one hundred RTL files.
    # Passing every absolute path through Start-Process can exceed the
    # Windows command-line limit and is reported by xvlog as "access denied".
    # Keep the command line short with a private xvlog file list; the worker
    # removes the complete runRoot (including this manifest) on exit.
    $sourceListPath = Join-Path $runRoot 'xvlog_sources.f'
    $sources | Set-Content -LiteralPath $sourceListPath -Encoding ASCII
    $xvlogArgs=@('-sv')
    if($PreviewCapture){$xvlogArgs+=@('-d','C1_PREVIEW_CAPTURE')}
    if($PreviewBrespError){$xvlogArgs+=@('-d','C1_PREVIEW_BRESP_ERROR')}
    if($PreviewBrespRecovery){$xvlogArgs+=@('-d','C1_PREVIEW_BRESP_RECOVERY')}
    if($PreviewCancel){$xvlogArgs+=@('-d','C1_PREVIEW_CANCEL')}
    if($PreviewCancelRecovery){$xvlogArgs+=@('-d','C1_PREVIEW_CANCEL_RECOVERY')}
    if($PreviewDisplay){$xvlogArgs+=@('-d','C1_PREVIEW_DISPLAY')}
    if($DistinctRecoveryFrame){$xvlogArgs+=@('-d','C1_DISTINCT_RECOVERY_FRAME')}
    if($BoardlessGeometry -eq 'separate') { $xvlogArgs+=@('-d','C1_SEPARATE_INPUT_GEOMETRY') }
    # Keep NAME=VALUE quoted through xvlog.bat/cmd.exe; an unquoted equals
    # sign can split off VALUE and make xvlog interpret it as a source file.
    $xvlogArgs += @('-d',('"C1_BFM_READ_FIRST_EXTRA='+$ReadFirstExtraCycles+'"'),
        '-d',('"C1_BFM_READ_BEAT_EXTRA='+$ReadBeatExtraCycles+'"'),
        '-d',('"C1_BFM_WRITE_RESPONSE_EXTRA='+$WriteResponseExtraCycles+'"'))
    if($TwoFrame){$xvlogArgs += @('-d','C1_TWO_FRAME')}
    if($TwoFrameTrace){$xvlogArgs += @('-d','C1_TWO_FRAME_TRACE')}
    if($SharedQosMonitor){$xvlogArgs += @('-d','C1_SHARED_QOS_MONITOR')}
    if($TrainedArtifact){$xvlogArgs += @('-d','C1_TRAINED_ARTIFACT')}
    if($TensorBurstRefill){$xvlogArgs += @('-d','C1_TENSOR_BURST_REFILL')}
    if($TensorBurstBeatMode){$xvlogArgs += @('-d','C1_TENSOR_BURST_BEAT_MODE')}
    if($DisplayResponseFifo){$xvlogArgs += @('-d','C1_DISPLAY_RESPONSE_FIFO')}
    if($ConcurrentDisplayPrefetch){$xvlogArgs += @('-d','C1_CONCURRENT_DISPLAY_PREFETCH')}
    if($DisplayFaultRecovery){$xvlogArgs += @('-d','C1_DISPLAY_FAULT_RECOVERY')}
    if($RelaxedDescriptor){$xvlogArgs += @('-d','C1_RELAXED_DESCRIPTOR')}
    if($FastAddress){$xvlogArgs += @('-d','C1_FAST_ADDRESS')}
    if($PipelinedAddress){$xvlogArgs += @('-d','C1_PIPELINED_ADDRESS')}
    if($PipelinedPixelIndex){$xvlogArgs += @('-d','C1_PIPELINED_TENSOR_PIXEL_INDEX')}
    if($PrefetchNextTapAddress){$xvlogArgs += @('-d','C1_PREFETCH_NEXT_TAP_ADDRESS')}
    if($ReuseHorizontalWindow){$xvlogArgs += @('-d','C1_REUSE_HORIZONTAL_WINDOW')}
    if($TensorColumnReads){$xvlogArgs += @('-d','C1_TENSOR_COLUMN_READS')}
    if($ColumnReadOnLookup){$xvlogArgs += @('-d','C1_COLUMN_READ_ON_LOOKUP')}
    if($ColumnResponseBypass){$xvlogArgs += @('-d','C1_COLUMN_RESPONSE_BYPASS')}
    if($ReuseColumnRowMap){$xvlogArgs += @('-d','C1_COLUMN_REUSE_ROW_MAP')}
    if($PixelColumnPrefetch){$xvlogArgs += @('-d','C1_PIXEL_COLUMN_PREFETCH')}
    if($AllPixelGroups){$xvlogArgs += @('-d','C1_ALL_PIXEL_GROUPS')}
    if($PipelinedSourceWrites){$xvlogArgs += @('-d','C1_PIPELINED_SOURCE_WRITES')}
    if($SourceWriteAbort){$xvlogArgs += @('-d','C1_SOURCE_WRITE_ABORT')}
    if($PixelPrefetchReadAbort){$xvlogArgs += @('-d','C1_PIXEL_PREFETCH_READ_ABORT')}
    if($ScalarReadBeatCache){$xvlogArgs += @('-d','C1_SCALAR_READ_BEAT_CACHE')}
    if($ScalarReadCacheEntries -eq 2){$xvlogArgs += @('-d','C1_SCALAR_READ_CACHE_TWO')}
    if($PreciseWriteInvalidate){$xvlogArgs += @('-d','C1_PRECISE_WRITE_INVALIDATION')}
    if($VirtualUpsampleTensors){$xvlogArgs += @('-d','C1_VIRTUAL_UPSAMPLE_TENSORS')}
    if($VirtualUpsampleReadAbort){$xvlogArgs += @('-d','C1_VIRTUAL_UPSAMPLE_READ_ABORT')}
    if($StreamDwGroups){$xvlogArgs += @('-d','C1_STREAM_DW_GROUPS')}
    if($StreamPointwiseReduction){$xvlogArgs += @('-d','C1_STREAM_POINTWISE_REDUCTION')}
    if($OverlapMacRequantization){$xvlogArgs += @('-d','C1_OVERLAP_MAC_REQUANTIZATION')}
    if($PipelineDotPixels){$xvlogArgs += @('-d','C1_PIPELINE_DOT_PIXELS')}
    if($AllDotGroups){$xvlogArgs += @('-d','C1_PIPELINE_ALL_DOT_GROUPS')}
    if($PackRgbReduction){$xvlogArgs += @('-d','C1_PACK_RGB_CONV_REDUCTION')}
    if($ElideViews){$xvlogArgs += @('-d','C1_ELIDE_VIRTUAL_UPSAMPLE')}
    if($FuseFinalOutput){$xvlogArgs += @('-d','C1_FUSE_FINAL_OUTPUT')}
    if($AllDotPixelWriteAbort){$xvlogArgs += @('-d','C1_ALL_DOT_PIXEL_WRITE_ABORT')}
    if($PipelineDwPixels){$xvlogArgs += @('-d','C1_PIPELINE_DW_PIXELS')}
    if($StreamDwFrame){$xvlogArgs += @('-d','C1_STREAM_DW_FRAME')}
    if($TensorWriteOutstanding -eq 2){$xvlogArgs += @('-d','C1_TENSOR_WRITE_MLP2')}
    if($TensorWriteOutstanding -eq 4){$xvlogArgs += @('-d','C1_TENSOR_WRITE_MLP4')}
    $xvlogArgs += @('-d',('"C1_PIXEL_WRITE_BATCH_WORDS='+$PixelWriteBatchWords+'"'))
    $xvlogArgs += @('-d',('"C1_TENSOR_WRITE_BUILD_TIMEOUT='+$TensorWriteBuildTimeout+'"'))
    if($DotPixelWriteAbort){$xvlogArgs += @('-d','C1_DOT_PIXEL_WRITE_ABORT')}
    if($DwPixelWriteAbort){$xvlogArgs += @('-d','C1_DW_PIXEL_WRITE_ABORT')}
    if($PointwiseReductionReadAbort){$xvlogArgs += @('-d','C1_POINTWISE_REDUCTION_READ_ABORT')}
    if($ColumnWriteOverlap){$xvlogArgs += @('-d','C1_COLUMN_WRITE_OVERLAP')}
    if($PointwiseColumnReads){$xvlogArgs += @('-d','C1_POINTWISE_COLUMN_READS')}
    if($PipelinedDescriptorValidation){$xvlogArgs += @('-d','C1_PIPELINED_DESCRIPTOR_VALIDATION')}
    if($NarrowDescriptorSizeCheck){$xvlogArgs += @('-d','C1_NARROW_DESCRIPTOR_SIZE_CHECK')}
    if($PipelinedDescriptorSizeArith){$xvlogArgs += @('-d','C1_PIPELINED_DESCRIPTOR_SIZE_ARITH')}
    if($FixedDescriptorSizeLimits){$xvlogArgs += @('-d','C1_FIXED_DESCRIPTOR_SIZE_LIMITS')}
    if($PipelinedDescriptorPixelCount){$xvlogArgs += @('-d','C1_PIPELINED_DESCRIPTOR_PIXEL_COUNT')}
    if($IterativeDescriptorPixelCount){$xvlogArgs += @('-d','C1_ITERATIVE_DESCRIPTOR_PIXEL_COUNT')}
    if($PreclampedTapCoords){$xvlogArgs += @('-d','C1_PRECLAMPED_TAP_COORDS')}
    if($PipelinedResultWrites){$xvlogArgs += @('-d','C1_PIPELINED_RESULT_WRITES')}
    if($TensorPackedWrites){$xvlogArgs += @('-d','C1_TENSOR_PACKED_WRITES')}
    if($TensorWriteEnd){$xvlogArgs += @('-d','C1_TENSOR_WRITE_END')}
    if($NumericalTrace){$xvlogArgs += @('-d','C1_NUMERICAL_TRACE')}
    if($ColorFixture){$xvlogArgs += @('-d','C1_COLOR_FIXTURE')}
    if($ResizeFixture){$xvlogArgs += @('-d','C1_RESIZE_FIXTURE')}
    if($SourceGeometry){$xvlogArgs += @('-d','C1_SOURCE_GEOMETRY')}
    if($QueuedWriteFabric){$xvlogArgs += @('-d','C1_QUEUED_WRITE_FABRIC')}
    if($ConcurrentCapture){$xvlogArgs += @('-d','C1_CONCURRENT_CAPTURE')}
    if($InflightWriteAbort -or $InflightReadAbort){$xvlogArgs += @('-d','C1_INFLIGHT_ABORT')}
    if($RawRasterFault){$xvlogArgs += @('-d','C1_RAW_RASTER_FAULT')}
    if($RawMissingEof){$xvlogArgs += @('-d','C1_RAW_MISSING_EOF')}
    if($RawIdleTimeout){$xvlogArgs += @('-d','C1_RAW_IDLE_TIMEOUT')}
    if($ExplicitCaptureRecovery){$xvlogArgs += @('-d','C1_EXPLICIT_CAPTURE_RECOVERY')}
    if($RecoveryLateSourceAck){$xvlogArgs += @('-d','C1_RECOVERY_LATE_SOURCE_ACK')}
    if($ApbCaptureRecovery){$xvlogArgs += @('-d','C1_APB_CAPTURE_RECOVERY')}
    if($InflightReadAbort){$xvlogArgs += @('-d','C1_INFLIGHT_READ_ABORT')}
    if($ScalarReadAbort){$xvlogArgs += @('-d','C1_SCALAR_READ_ABORT')}
    if($ScalarAssocReadAbort){$xvlogArgs += @('-d','C1_SCALAR_ASSOC_READ_ABORT')}
    if($CompactRefillFifos){$xvlogArgs += @('-d','C1_COMPACT_REFILL_FIFOS')}
    if($WideRefillWindow){$xvlogArgs += @('-d','C1_WIDE_REFILL_WINDOW')}
    if($RefillRequestHandoff){$xvlogArgs += @('-d','C1_REFILL_REQUEST_HANDOFF')}
    if($SerializeWriteData){$xvlogArgs += @('-d','C1_SERIALIZE_WRITE_DATA')}
    if($RejectGeometry){$xvlogArgs += @('-d','C1_REJECT_GEOMETRY')}
    if($RegisterAbortReset){$xvlogArgs += @('-d','C1_REGISTER_ABORT_RESET')}
    if($PipelinedStartConfig){$xvlogArgs += @('-d','C1_PIPELINED_START_CONFIG')}
    if($PipelinedDotTree){$xvlogArgs += @('-d','C1_PIPELINED_DOT_TREE')}
    if($PipelinedDotTreeFull){$xvlogArgs += @('-d','C1_PIPELINED_DOT_TREE_FULL')}
    if($CacheDwWeightTiles){$xvlogArgs += @('-d','C1_CACHE_DW_WEIGHT_TILES')}
    if($MacPrefetchOverlap){$xvlogArgs += @('-d','C1_MAC_PREFETCH_OVERLAP')}
    if($PipelinedDescriptorReplay){$xvlogArgs += @('-d','C1_PIPELINED_DESCRIPTOR_REPLAY')}
    if($PrevalidateDescriptorReplay){$xvlogArgs += @('-d','C1_PREVALIDATE_DESCRIPTOR_REPLAY')}
    if($PipelinedDecoderValidation){$xvlogArgs += @('-d','C1_PIPELINED_DECODER_VALIDATION')}
    if($ReplicateAbortControl){$xvlogArgs += @('-d','C1_REPLICATE_ABORT_CONTROL')}
    if($TableResponseFifo){$xvlogArgs += @('-d','C1_TABLE_RESPONSE_FIFO')}
    if($UnifiedOutputFifo){$xvlogArgs += @('-d','C1_UNIFIED_OUTPUT_FIFO')}
    if($UnifiedOutputSkid){$xvlogArgs += @('-d','C1_UNIFIED_OUTPUT_SKID')}
    if($FabricReadResponseSkid){$xvlogArgs += @('-d','C1_FABRIC_READ_RESPONSE_SKID')}
    if($RegisterFatalTicket){$xvlogArgs += @('-d','C1_REGISTER_FATAL_TICKET')}
    switch($Frame) {
        '16x8'  { $xvlogArgs += @('-d','C1_FRAME_16X8') }
        '16x16' { $xvlogArgs += @('-d','C1_FRAME_16X16') }
        '64x48' { $xvlogArgs += @('-d','C1_FRAME_64X48') }
        '640x480' { $xvlogArgs += @('-d','C1_FRAME_640X480') }
    }
    $xvlogArgs += @('-f', $sourceListPath)
    if($TrainedArtifact) {
        $shapeParts=$Frame.Split('x')
        $viewFixtureArgs=@(); if($ElideViews){$viewFixtureArgs+='--elide-views'}
        if($FuseFinalOutput){$viewFixtureArgs+='--fuse-final'}
        $fixtureOutput = @(& $Python -B (Join-Path $caseRoot 'golden\prepare_portable_soc_trained_fixture.py') `
            --artifact $trainedArtifactRoot --output-dir $runRoot --width $shapeParts[0] --height $shapeParts[1] @viewFixtureArgs 2>&1)
        if($LASTEXITCODE -ne 0){throw "trained fixture preparation failed: $fixtureOutput"}
        $fixtureOutput | Set-Content -LiteralPath (Join-Path $runLogRoot 'trained_fixture.stdout.log') -Encoding UTF8
        Copy-Item -LiteralPath (Join-Path $runRoot 'trained_fixture.json') -Destination $runLogRoot
    }
    Invoke-XsimStep xvlog (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
    $elabArgs=@($testTop,'-s',($testTop+'_sim'))
    Invoke-XsimStep xelab (Join-Path $vivadoBin 'xelab.bat') $elabArgs
    if ($CompileOnly) {
        $watch.Stop()
        Write-Status complete elaboration 0 "C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS top=$testTop frame=$Frame geometry=$BoardlessGeometry"
        return
    }
    $expectedPass = if($DisplayFaultRecovery){
        'C1_PORTABLE_SOC_DISPLAY_FAULT_RECOVERY_PASS'
    } elseif($ClientTrafficGate){
        'C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_PASS'
    } elseif($TwoFrame){
        'C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_TWO_FRAME_PASS'
    } else {
        'C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS'
    }
    if($TrainedArtifact) {
        # The normal lifecycle marker is still required; the additional
        # artifact marker proves the parameter arena was actually addressed.
        $expectedPass = 'C1_R1_PORTABLE_SOC_TRAINED_ARTIFACT_'+$Frame.ToUpperInvariant()+'_PASS'
    }
    if($TwoFrameTrace) { $expectedPass='C1_NUM_TWO_PASS frames=2' }
    if($BoardlessGeometry -ne 'none') { $expectedPass='C1_R1_BOARDLESS_FRAME_SYSTEM_PASS' }
    if($InflightWriteAbort) { $expectedPass='C1_SOC_INFLIGHT_WRITE_ABORT_PASS' }
    if($RawRasterFault) { $expectedPass='C1_SOC_RAW_RASTER_FAULT_PASS' }
    if($RawMissingEof) { $expectedPass='C1_SOC_RAW_MISSING_EOF_PASS' }
    if($RawIdleTimeout) { $expectedPass='C1_SOC_RAW_IDLE_TIMEOUT_PASS' }
    if($ExplicitCaptureRecovery) { $expectedPass='C1_SOC_EXPLICIT_RECOVERY_PASS' }
    if($InflightReadAbort) { $expectedPass='C1_SOC_INFLIGHT_READ_ABORT_PASS' }
    if($PreviewBrespError) { $expectedPass='C1_SOC_PREVIEW_BRESP_ERROR_PASS' }
    if($PreviewBrespRecovery) { $expectedPass='C1_SOC_PREVIEW_BRESP_RECOVERY_PASS' }
    if($PreviewCancel) { $expectedPass='C1_SOC_PREVIEW_CANCEL_PASS' }
    if($PreviewCancelRecovery) { $expectedPass='C1_SOC_PREVIEW_CANCEL_RECOVERY_PASS' }
    Invoke-XsimStep xsim (Join-Path $vivadoBin 'xsim.bat') @(
        ($testTop+'_sim'),'-runall') $expectedPass
    if($NumericalTrace) {
        $fixtureMetadata=Get-Content -LiteralPath (Join-Path $runLogRoot 'trained_fixture.json') -Raw | ConvertFrom-Json
        $shapeMarker='^C1_NUM_SHAPE width='+$fixtureMetadata.width+' height='+$fixtureMetadata.height+' C8_results='+$fixtureMetadata.C8_results+'$'
        foreach($traceMarker in @($shapeMarker,'^C1_NUM_DDR_STORE address_keyed collision_pair=02800100:02000500 byte_strobes=1$')) {
            if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $traceMarker).Count -ne 1) {
                throw 'Missing, duplicate or mismatched trained shape / DDR self-test evidence'
            }
        }
    }
    if($QueuedWriteFabric -and -not (Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_SOC_QUEUED_WRITE_NUMERIC_PASS ' -Quiet)) {
        throw 'Missing queued-write retirement marker'
    }
    if($BoardlessGeometry -eq 'none') {
        $pointwiseMarker='^C1_NUM_POINTWISE_COLUMN_READS enabled='+[int]$PointwiseColumnReads.IsPresent+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $pointwiseMarker).Count -ne 1) {
            throw 'Missing or duplicate actual pointwise column-read mode'
        }
        $columnOverlapMarker='^C1_NUM_COLUMN_WRITE_OVERLAP enabled='+[int]$ColumnWriteOverlap.IsPresent+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $columnOverlapMarker).Count -ne 1) {
            throw 'Missing or duplicate actual column/write overlap mode'
        }
        $dwStreamMarker='^C1_NUM_DW_STREAM enabled='+[int]$StreamDwGroups.IsPresent+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $dwStreamMarker).Count -ne 1) {
            throw 'Missing or duplicate actual DW group streaming mode'
        }
        if($VirtualUpsampleReadAbort -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_NUM_VIRTUAL_UPSAMPLE_ABORT stage=18 width=4 height=4 input_bank=0 output_bank=1$').Count -ne 1) {
            throw 'Missing virtual upsample stage18 physical refill abort evidence'
        }
        $virtualMarker='^C1_NUM_VIRTUAL_UPSAMPLE enabled='+[int]$VirtualUpsampleTensors.IsPresent+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $virtualMarker).Count -ne 1) {
            throw 'Missing or duplicate actual virtual upsample tensor option evidence'
        }
        $preciseMarker='^C1_NUM_PRECISE_WRITE_INVALIDATION enabled='+[int]$PreciseWriteInvalidate.IsPresent+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $preciseMarker).Count -ne 1) {
            throw 'Missing or duplicate actual precise write-invalidation option evidence'
        }
        $scalarReadMarker='^C1_NUM_SCALAR_READ_CACHE enabled='+[int]$ScalarReadBeatCache.IsPresent+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $scalarReadMarker).Count -ne 1) {
            throw 'Missing or duplicate actual scalar read-cache option evidence'
        }
        $scalarEntriesMarker='^C1_NUM_SCALAR_CACHE_ENTRIES entries='+$ScalarReadCacheEntries+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $scalarEntriesMarker).Count -ne 1){
            throw 'Missing or duplicate actual scalar read-cache capacity evidence'
        }
        if($ScalarAssocReadAbort -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_NUM_SCALAR_ASSOC_ABORT stage=5 entries=2 surviving_valid=1 hits=2 reads=5 pending=1$').Count -ne 1){
            throw 'Missing warm two-way replacement-read cancellation witness'
        }
        $latencyMarker='^C1_NUM_BFM_DELAY first_extra='+$ReadFirstExtraCycles+
            ' beat_extra='+$ReadBeatExtraCycles+' write_extra='+$WriteResponseExtraCycles+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $latencyMarker).Count -ne 1) {
            throw 'Missing or duplicate actual BFM delay configuration evidence'
        }
    }
    if($CacheDwWeightTiles -or $MacPrefetchOverlap) {
        $engineMarker='^C1_NUM_ENGINE_OPTIONS dw_cache='+[int]$CacheDwWeightTiles.IsPresent+' mac_overlap='+[int]$MacPrefetchOverlap.IsPresent+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $engineMarker).Count -ne 1) {
            throw 'Missing or duplicate actual engine-option evidence'
        }
    }
    $tapMarker='^C1_NUM_TAP_ADDRESS_OPTIONS prefetch='+[int]$PrefetchNextTapAddress.IsPresent+
        ' pipeline='+[int]$PipelinedAddress.IsPresent+' pixel_pipeline='+[int]$PipelinedPixelIndex.IsPresent+'$'
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $tapMarker).Count -ne 1) {
        throw 'Missing or duplicate actual tap-address option evidence'
    }
    $reuseMarker='^C1_NUM_HORIZONTAL_REUSE_OPTION enabled='+[int]$ReuseHorizontalWindow.IsPresent+'$'
    $columnMarker='^C1_NUM_COLUMN_OPTION enabled='+[int]$TensorColumnReads.IsPresent+' clients=\d+$'
    $lookupMarker='^C1_NUM_COLUMN_LOOKUP enabled='+[int]$ColumnReadOnLookup.IsPresent+'$'
    $responseBypassMarker='^C1_NUM_COLUMN_RESPONSE_BYPASS enabled='+[int]$ColumnResponseBypass.IsPresent+'$'
    $rowMapMarker='^C1_NUM_COLUMN_ROW_MAP enabled='+[int]$ReuseColumnRowMap.IsPresent+'$'
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^C1_NUM_FINAL_FUSION enabled='+[int]$FuseFinalOutput.IsPresent+'$')).Count -ne 1){
        throw 'Final fusion actual mode missing/duplicate/mismatch'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $rowMapMarker).Count -ne 1){
        throw 'Column row-map actual mode missing/duplicate/mismatch'
    }
    $pixelPrefetchMarker='^C1_NUM_PIXEL_COLUMN_PREFETCH enabled='+[int]$PixelColumnPrefetch.IsPresent+'$'
    $allPixelGroupsMarker='^C1_NUM_ALL_PIXEL_GROUPS enabled='+[int]$AllPixelGroups.IsPresent+'$'
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $allPixelGroupsMarker).Count -ne 1){
        throw 'All-group prefetch actual mode missing/duplicate/mismatch'
    }
    $sourcePipelineMarker='^C1_NUM_SOURCE_PIPELINE enabled='+[int]$PipelinedSourceWrites.IsPresent+'$'
    $pwReductionMarker='^C1_NUM_POINTWISE_REDUCTION enabled='+[int]$StreamPointwiseReduction.IsPresent+'$'
    $requantOverlapMarker='^C1_NUM_MAC_REQUANT_OVERLAP enabled='+[int]$OverlapMacRequantization.IsPresent+'$'
    $pixelPipelineMarker='^C1_NUM_DOT_PIXEL_PIPELINE enabled='+[int]$PipelineDotPixels.IsPresent+'$'
    $allDotMarker='^C1_NUM_ALL_DOT_GROUPS enabled='+[int]([bool]$AllDotGroups)+'$'
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^C1_NUM_VIEW_ELISION enabled='+[int]([bool]$ElideViews)+'$')).Count -ne 1){
        throw 'Missing/duplicate actual view elision option'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^C1_NUM_RGB_REDUCTION enabled='+[int]([bool]$PackRgbReduction)+'$')).Count -ne 1){
        throw 'Missing/duplicate actual RGB reduction mode witness'
    }
    if($AllDotPixelWriteAbort -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_NUM_ALL_DOT_PIXEL_ABORT stage=0 pending=([2-9]|1[0-5])$').Count -ne 1){
        throw 'Missing actual stage0 multi-group pixel writer abort witness'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $allDotMarker).Count -ne 1){
        throw 'Missing/duplicate actual all-dot-group mode witness'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^C1_NUM_TENSOR_WRITE_MLP outstanding='+$TensorWriteOutstanding+'$')).Count -ne 1){
        throw 'Missing/duplicate/mismatched actual tensor write outstanding selection'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern ('^C1_NUM_PIXEL_WRITE_BATCH words='+$PixelWriteBatchWords+' build_timeout='+$TensorWriteBuildTimeout+'$')).Count -ne 1){
        throw 'Actual pixel batching/build timeout did not match requested configuration'
    }
    if($DotPixelWriteAbort -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_NUM_DOT_PIXEL_ABORT stage=20 pending=([2-9]|1[0-5])$').Count -ne 1){
        throw 'Missing/duplicate actual stage20 pixel writer multiple-debt abort witness'
    }
    if($DwPixelWriteAbort -and @(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_NUM_DW_PIXEL_ABORT stage=18 pending=([2-9]|1[0-5])$').Count -ne 1){
        throw 'Missing/duplicate actual stage18 DW writer multiple-debt abort witness'
    }
    $dwPixelModeMarker='^C1_NUM_DW_PIXEL_PIPELINE enabled='+[int]([bool]$PipelineDwPixels)+'$'
    $dwFrameModeMarker='^C1_NUM_DW_FRAME_STREAM enabled='+[int]([bool]$StreamDwFrame)+'$'
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $dwFrameModeMarker).Count -ne 1){
        throw 'Missing/duplicate/mismatched actual DW frame stream mode'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $dwPixelModeMarker).Count -ne 1){
        throw 'Missing/duplicate/mismatched actual DW pixel pipeline mode'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $pixelPipelineMarker).Count -ne 1){
        throw 'Missing/duplicate/mismatched actual dot pixel pipeline mode'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $requantOverlapMarker).Count -ne 1){
        throw 'Missing or duplicate actual MAC/requant overlap option'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $pwReductionMarker).Count -ne 1){
        throw 'Missing or duplicate actual pointwise reduction option'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $sourcePipelineMarker).Count -ne 1){
        throw 'Missing or duplicate actual source write pipeline option'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $pixelPrefetchMarker).Count -ne 1){
        throw 'Missing or duplicate actual next-pixel column prefetch option'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $responseBypassMarker).Count -ne 1){
        throw 'Missing or duplicate actual column response bypass option'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $lookupMarker).Count -ne 1){
        throw 'Missing or duplicate actual column lookup option'
    }
    $writeOptionMarker='^C1_NUM_TENSOR_WRITE_OPTIONS packed='+[int]$TensorPackedWrites.IsPresent+
        ' pipeline='+[int]$PipelinedResultWrites.IsPresent+' end='+[int]$TensorWriteEnd.IsPresent+'$'
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $writeOptionMarker).Count -ne 1){
        throw 'Missing or duplicate actual tensor write-option evidence'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $columnMarker).Count -ne 1){
        throw 'Missing or duplicate actual SoC column-option evidence'
    }
    if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $reuseMarker).Count -ne 1) {
        throw 'Missing or duplicate horizontal reuse option evidence'
    }
    if($PreviewCapture -and -not $PreviewBrespError -and -not $PreviewCancel -and -not (Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_NUM_PREVIEW_CAPTURE_PASS ' -Quiet)) {
        throw 'Missing physical preview DDR verification marker'
    }
    if($PreviewBrespRecovery) {
        foreach($recoveryMarker in '^C1_SOC_PREVIEW_BRESP_ERROR_PASS ','^C1_NUM_PREVIEW_CAPTURE_PASS ') {
            if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $recoveryMarker).Count -ne 1) {
                throw 'Missing or duplicate preview fault/recovery phase evidence'
            }
        }
    }
    if($PreviewCancelRecovery) {
        foreach($cancelMarker in '^C1_SOC_PREVIEW_CANCEL_PASS ','^C1_NUM_PREVIEW_CAPTURE_PASS ') {
            if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $cancelMarker).Count -ne 1) {
                throw 'Missing or duplicate preview cancel/recovery evidence'
            }
        }
    }
    if($CompactRefillFifos -and -not (Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_NUM_REFILL_CAPACITY req_depth=16 rsp_depth=16 beat_mode=0 ' -Quiet)) {
        throw 'Missing actual compact-refill capacity evidence'
    }
    if($WideRefillWindow -and -not $TensorColumnReads -and -not (Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_NUM_REFILL_WINDOW 32$' -Quiet)) {
        throw 'Missing actual 32-request refill window evidence'
    }
    if($TensorColumnReads) {
        $columnWindow=if($WideRefillWindow){32}else{16}
        $columnRefillMarker='^C1_NUM_COLUMN_REFILL version=2 window='+$columnWindow+' req_depth=32 rsp_depth=128 beat_mode=0 handoff='+[int]([bool]$RefillRequestHandoff)+'$'
        if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $columnRefillMarker).Count -ne 1){
            throw 'Missing/duplicate/mismatched actual column refill configuration'
        }
    }
    if($ConcurrentCapture -and -not $InflightWriteAbort -and -not $InflightReadAbort -and -not (Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern '^C1_SOC_CONCURRENT_CAPTURE_PASS ' -Quiet)) {
        throw 'Missing concurrent capture coverage marker'
    }
    if($InflightReadAbort) {
        $readOwner=if($ScalarReadAbort -or $PointwiseReductionReadAbort){6}elseif($TensorColumnReads){7}else{6}
        if($ScalarReadAbort) {
            foreach($scalarEvidence in @('^C1_NUM_READ_ABORT_TARGET scalar$',
                '^C1_SOC_SCALAR_READ_ABORT_CACHE_PASS before=1 after=0 valid=0 pending=0$')) {
                if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $scalarEvidence).Count -ne 1) {
                    throw 'Missing unique scalar read-cache cancellation evidence'
                }
            }
        }
        foreach($readEvidence in @(
            "^C1_SOC_INFLIGHT_READ_ABORT_DRAIN_PASS pending_beats=\d+ held_cycles=64 owner=$readOwner no_restart=1$",
            "^C1_SOC_INFLIGHT_READ_ABORT_PASS pending_beats=\d+ held_cycles=64 captures=3 done=1 owner=$readOwner reset=0$")) {
            if(@(Select-String -LiteralPath (Join-Path $runLogRoot 'xsim.stdout.log') -Pattern $readEvidence).Count -ne 1){
                throw 'Missing unique actual read owner/drain/restart evidence'
            }
        }
    }
    $watch.Stop(); Write-Status complete done 0 $expectedPass
} catch {
    $failure=$_
    # Keep a bounded exception/stack record; the message alone is insufficient
    # to distinguish a process-launch failure from a compact-log read failure.
    @($failure.Exception.ToString(),$failure.ScriptStackTrace,$failure.InvocationInfo.PositionMessage) |
        Set-Content -LiteralPath (Join-Path $runLogRoot 'worker_failure.log') -Encoding UTF8
    $watch.Stop(); Write-Status failed $script:currentStep 1 $failure.Exception.Message; exit 1
} finally {
    # Never leave a native Vivado/xsim run tree behind, including the failure
    # path.  Status/stdout/stderr remain under case1/logs for diagnosis.
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
