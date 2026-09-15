[CmdletBinding()]
param([string]$IcarusHome = 'D:\iverilog', [string]$Python = 'python',
      [string]$TestTop = '', [string]$TestFlagsMatch = '',
      [ValidateRange(1,60)][int]$SimulationTimeoutSeconds = 30)
$ErrorActionPreference = 'Stop'
# Keep a bounded diagnostic in the exception itself: callers may filter or
# buffer the success stream and lose the output emitted immediately before
# throw. This retains evidence without preserving simulator projects/waves.
function Format-C1RegressionFailure {
    param([string]$Reason,[string]$Top,[object[]]$Flags,[object[]]$Lines)
    $important=@($Lines | Where-Object { "$_" -match '(?i)fatal|error|unable|timeout|mismatch|failed' } | Select-Object -First 8)
    $tail=@($Lines | Select-Object -Last 8)
    $brief=@(($important+$tail) | ForEach-Object {
        $line="$_"
        if($line.Length -gt 240) {$line.Substring(0,240)+' [truncated]'} else {$line}
    })
    return "$Reason`: $Top flags=[$($Flags -join ' ')]`n$($brief -join "`n")"
}
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$compiler = Join-Path $IcarusHome 'bin\iverilog.exe'
$simulator = Join-Path $IcarusHome 'bin\vvp.exe'
$packages = @('c1_fixed_pkg.sv','c1_descriptor_pkg.sv',
              'c1_descriptor_decoder_pkg.sv','c1_frame_buffer_pkg.sv')
$all = @(Get-ChildItem (Join-Path $caseRoot 'rtl') -Recurse -Filter '*.sv')
$sources = @()
foreach ($package in $packages) {
    $found = @($all | Where-Object Name -eq $package)
    if ($found.Count -ne 1) { throw "Expected exactly one package: $package" }
    $sources += $found[0].FullName
}
$sources += @($all | Where-Object { $_.Name -notin $packages } |
              Sort-Object FullName | ForEach-Object FullName)
$sources += Join-Path $caseRoot 'efinity\c1_ti60_cnn_top_packed_wrapper.sv'
$tests = @()
foreach($assocSlots in @(2,4)){foreach($assocWFirst in @(0,1)){
    $tests+=@{Top='tb_c1_tensor_read_cache_associative';Flags=@(
        '-Ptb_c1_tensor_read_cache_associative.ENTRIES=2',
        '-Ptb_c1_tensor_read_cache_associative.PACKED=1',
        '-Ptb_c1_tensor_read_cache_associative.PRECISE=1',
        "-Ptb_c1_tensor_read_cache_associative.W_FIRST=$assocWFirst",
        "-Ptb_c1_tensor_read_cache_associative.WRITE_OUTSTANDING=$assocSlots");
        ExtraSources=@('tb_c1_tensor_packing_memory.sv');
        RequiredPassMarkers=@('C1_SCALAR_ASSOC_CACHE_PASS entries=2 packed=1 precise=1',
            'C1_SCALAR_ASSOC_B_FENCE_PASS held_cycles=10 physical_and_logical=1 entries=2 logical_writes=2')}
}}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
    '-Ptb_c1_r1_portable_soc_smoke.READ_CACHE_ENTRIES=3',
    '-Ptb_c1_r1_portable_soc_smoke.SCALAR_READ_CACHE=1',
    '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1');ExpectedFailure='cache entries must be 1 or 2'}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
    '-Ptb_c1_r1_portable_soc_smoke.READ_CACHE_ENTRIES=2',
    '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1');ExpectedFailure='two scalar read entries require the scalar read-beat cache'}
foreach($assocEntries in @(1,2)){foreach($assocPacked in @(0,1)){foreach($assocPrecise in @(0,1)){foreach($assocWFirst in @(0,1)){
    $tests+=@{Top='tb_c1_tensor_read_cache_associative';Flags=@(
        "-Ptb_c1_tensor_read_cache_associative.ENTRIES=$assocEntries",
        "-Ptb_c1_tensor_read_cache_associative.PACKED=$assocPacked",
        "-Ptb_c1_tensor_read_cache_associative.PRECISE=$assocPrecise",
        "-Ptb_c1_tensor_read_cache_associative.W_FIRST=$assocWFirst");
        ExtraSources=@('tb_c1_tensor_packing_memory.sv');
        RequiredPassMarkers=@("C1_SCALAR_ASSOC_CACHE_PASS entries=$assocEntries packed=$assocPacked precise=$assocPrecise w_first=$assocWFirst",
            "C1_SCALAR_ASSOC_RESIDUAL_PASS entries=$assocEntries precise=$assocPrecise words=24 reads=48 writes=24 ar=$(if($assocEntries -eq 1){48}elseif($assocPrecise){24}else{32})")}
}}}}
foreach($assocEntries in @(1,2)){foreach($assocPacked in @(0,1)){foreach($assocPrecise in @(0,1)){
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        "-Ptb_c1_r1_portable_soc_smoke.READ_CACHE_ENTRIES=$assocEntries",
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
        '-Ptb_c1_r1_portable_soc_smoke.SCALAR_READ_CACHE=1',
        "-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=$assocPacked",
        "-Ptb_c1_r1_portable_soc_smoke.PRECISE_INVALIDATION=$assocPrecise")}
}}}
foreach($columnWindow in @(16,32)){foreach($columnHandoff in @(0,1)){
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
        "-Ptb_c1_r1_portable_soc_smoke.REFILL_WINDOW=$columnWindow",
        "-Ptb_c1_r1_portable_soc_smoke.REFILL_HANDOFF=$columnHandoff");
        RequiredPassMarkers=@("C1_SOC_COLUMN_REFILL_CONFIG_PASS window=$columnWindow handoff=$columnHandoff")}
}}
foreach($fusionCase in 1..10) {foreach($fusionColumns in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=@(
        '-Ptb_c1_r1_microstyle_tensor_adapter.FUSE_FINAL=1',
        "-Ptb_c1_r1_microstyle_tensor_adapter.FUSION_CASE=$fusionCase",
        "-Ptb_c1_r1_microstyle_tensor_adapter.COLUMN_READS=$fusionColumns");TimeoutSeconds=60;
        RequiredPassMarkers=@($(if($fusionCase -le 2){'C1_ADAPTER_FINAL_CANCEL_PASS'}else{'C1_ADAPTER_FINAL_FAULT_PASS'}))}
}}
foreach($fuseColumns in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=@(
        '-Ptb_c1_r1_microstyle_tensor_adapter.FUSE_FINAL=1',
        '-Ptb_c1_r1_microstyle_tensor_adapter.RUN_WRITE_DRAIN_SCENARIOS=0',
        "-Ptb_c1_r1_microstyle_tensor_adapter.COLUMN_READS=$fuseColumns");TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_ADAPTER_FINAL_FUSION_PASS enabled=1')}
}
foreach($fusePipe in @(0,1)) {foreach($fuseViews in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        '-Ptb_c1_r1_microstyle_engine.FUSE_FINAL=1',
        "-Ptb_c1_r1_microstyle_engine.ELIDE_VIEWS=$fuseViews",
        "-Ptb_c1_r1_microstyle_engine.ALL_DOT_GROUPS=$fusePipe",
        "-Ptb_c1_r1_microstyle_engine.DOT_PIXELS=$fusePipe",
        "-Ptb_c1_r1_microstyle_engine.REQUANT_OVERLAP=$fusePipe",
        "-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=$fusePipe");TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_ENGINE_FINAL_FUSION_PASS enabled=1 final_data_results=0',
            'C1_ENGINE_VIEW_REJECT_PASS field=0 code=07 stage=21',
            'C1_ENGINE_VIEW_REJECT_PASS field=1 code=07 stage=21',
            'C1_ENGINE_FINAL_CANCEL_PASS stage=21 accepted=0 reset=0','C1_ENGINE_VIEW_RESTART_PASS')}
}}
foreach($fuseColumns in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.FUSE_FINAL=1',
        "-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=$fuseColumns")}
}
foreach($viewPipe in @(0,1)) {foreach($viewTree in @('','C1_PIPELINED_DOT_TREE_FULL')) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@('-Ptb_c1_r1_microstyle_engine.ELIDE_VIEWS=1',
        '-Ptb_c1_r1_microstyle_engine.PACK_RGB=1','-Ptb_c1_r1_microstyle_engine.DENSE_RGB=1',
        "-Ptb_c1_r1_microstyle_engine.ALL_DOT_GROUPS=$viewPipe","-Ptb_c1_r1_microstyle_engine.DOT_PIXELS=$viewPipe",
        "-Ptb_c1_r1_microstyle_engine.REQUANT_OVERLAP=$viewPipe","-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=$viewPipe",
        '-DC1_MAC_PREFETCH_OVERLAP')+$(if($viewTree){@("-D$viewTree")}else{@()});TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_ENGINE_VIEW_COMMIT_PASS enabled=1 commits=2',
            'C1_ENGINE_VIEW_REJECT_PASS field=0','C1_ENGINE_VIEW_REJECT_PASS field=1',
            'C1_ENGINE_VIEW_CANCEL_PASS accepted=0','C1_ENGINE_VIEW_RESTART_PASS')}
}}
foreach($viewVirtual in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.ELIDE_VIEWS=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',"-Ptb_c1_r1_portable_soc_smoke.VIRTUAL_UPSAMPLE=$viewVirtual");
        ExpectedFailure=$(if($viewVirtual){''}else{'view elision requires virtual tensors'})}
}
foreach($rgbSmokeColumns in @(0,1)) {foreach($rgbSmokeOverlap in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.PACK_RGB=1',
        "-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=$rgbSmokeColumns",
        "-Ptb_c1_r1_portable_soc_smoke.MAC_PREFETCH_OVERLAP=$rgbSmokeOverlap")}
}}
foreach($rgbPack in @(0,1)) {foreach($rgbOverlap in @(0,1)) {foreach($rgbTree in @('','C1_PIPELINED_DOT_TREE','C1_PIPELINED_DOT_TREE_FULL')) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        "-Ptb_c1_r1_microstyle_engine.PACK_RGB=$rgbPack",'-Ptb_c1_r1_microstyle_engine.DENSE_RGB=1')+
        $(if($rgbOverlap){@('-DC1_MAC_PREFETCH_OVERLAP')}else{@()})+
        $(if($rgbTree){@("-D$rgbTree")}else{@()});TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_ENGINE_RGB_REDUCTION_PASS')}
}}}
foreach($rgbPack in @(0,1)) {foreach($rgbPw in @(0,1)) {foreach($rgbTree in @('','C1_PIPELINED_DOT_TREE_FULL')) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        "-Ptb_c1_r1_microstyle_engine.PACK_RGB=$rgbPack",'-Ptb_c1_r1_microstyle_engine.DENSE_RGB=1',
        '-Ptb_c1_r1_microstyle_engine.ALL_DOT_GROUPS=1','-Ptb_c1_r1_microstyle_engine.DOT_PIXELS=1',
        '-Ptb_c1_r1_microstyle_engine.REQUANT_OVERLAP=1',"-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=$rgbPw",
        '-DC1_MAC_PREFETCH_OVERLAP')+$(if($rgbTree){@("-D$rgbTree")}else{@()});TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_ENGINE_RGB_REDUCTION_PASS','C1_ENGINE_ALL_DOT_NEXT_HOLD_PASS','C1_ENGINE_RGB_COLLECT_MASK_PASS')}
}}}
foreach($allDotDw in @(0,1)) {foreach($allDotPwColumn in @(0,1)) {foreach($allDotSlots in @(1,4)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.ALL_DOT_GROUPS=1',
        '-Ptb_c1_r1_portable_soc_smoke.DOT_PIXELS=1','-Ptb_c1_r1_portable_soc_smoke.REQUANT_OVERLAP=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1','-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1',
        '-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1','-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=1',
        '-Ptb_c1_r1_portable_soc_smoke.WRITE_END=1','-Ptb_c1_r1_portable_soc_smoke.PIXEL_BATCH=8',
        "-Ptb_c1_r1_portable_soc_smoke.DW_PIXELS=$allDotDw","-Ptb_c1_r1_portable_soc_smoke.STREAM_DW=$allDotDw",
        "-Ptb_c1_r1_portable_soc_smoke.CACHE_DW_WEIGHT_TILES=$allDotDw",
        "-Ptb_c1_r1_portable_soc_smoke.POINTWISE_COLUMNS=$allDotPwColumn",
        "-Ptb_c1_r1_portable_soc_smoke.WRITE_OUTSTANDING=$allDotSlots")}
}}}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.ALL_DOT_GROUPS=1');
    ExpectedFailure='all dot groups requires dot pixel pipeline'}
foreach($dotAllPw in @(0,1)) {foreach($dotAllNext in @(0,1)) {foreach($dotAllTree in @('','C1_PIPELINED_DOT_TREE','C1_PIPELINED_DOT_TREE_FULL')) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@('-Ptb_c1_r1_microstyle_engine.ALL_DOT_GROUPS=1',
        '-Ptb_c1_r1_microstyle_engine.DOT_PIXELS=1','-Ptb_c1_r1_microstyle_engine.REQUANT_OVERLAP=1',
        "-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=$dotAllPw","-Ptb_c1_r1_microstyle_engine.DOT_NEXT_ALL_INPUTS=$dotAllNext",
        '-DC1_CACHE_DW_WEIGHT_TILES','-DC1_STREAM_DW_GROUPS','-Ptb_c1_r1_microstyle_engine.DW_PIXELS=1',
        '-DC1_MAC_PREFETCH_OVERLAP')+$(if($dotAllTree){@("-D$dotAllTree")}else{@()});TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_ENGINE_ALL_DOT_NEXT_HOLD_PASS')}
}}}
$tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@('-Ptb_c1_r1_microstyle_engine.ALL_DOT_GROUPS=1');
    ExpectedFailure='all dot groups requires dot pixel pipeline'}
foreach($dwDynamicBatch in @(1,8)) {
    $tests+=@{Top='tb_c1_pixel_result_writer';Flags=@('-Ptb_c1_pixel_result_writer.DYNAMIC_GROUPS=1',
        "-Ptb_c1_pixel_result_writer.BATCH=$dwDynamicBatch");
        RequiredPassMarkers=@('C1_PIXEL_RESULT_WRITER_PASS','C1_PIXEL_WRITER_GROUP_REJECT_PASS groups=0',
            'C1_PIXEL_WRITER_GROUP_REJECT_PASS groups=9','C1_PIXEL_WRITER_HELD_ERROR_PASS')}
}
foreach($dwSmokeDot in @(0,1)) {foreach($dwSmokePf in @(0,1)) {foreach($dwSmokeMlp in @(1,4)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.DW_PIXELS=1',"-Ptb_c1_r1_portable_soc_smoke.DOT_PIXELS=$dwSmokeDot",
        '-Ptb_c1_r1_portable_soc_smoke.STREAM_DW=1','-Ptb_c1_r1_portable_soc_smoke.CACHE_DW_WEIGHT_TILES=1',
        '-Ptb_c1_r1_portable_soc_smoke.REQUANT_OVERLAP=1','-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
        '-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=1','-Ptb_c1_r1_portable_soc_smoke.WRITE_END=1',
        '-Ptb_c1_r1_portable_soc_smoke.PIXEL_BATCH=8',"-Ptb_c1_r1_portable_soc_smoke.WRITE_OUTSTANDING=$dwSmokeMlp",
        "-Ptb_c1_r1_portable_soc_smoke.PIXEL_PREFETCH=$dwSmokePf","-Ptb_c1_r1_portable_soc_smoke.ALL_PIXEL_GROUPS=$dwSmokePf",
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1','-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1')}
}}}
$tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@('-Ptb_c1_r1_microstyle_engine.DW_PIXELS=1');
    ExpectedFailure='DW pixel pipeline requires group streaming and cached weights'}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.DW_PIXELS=1',
    '-Ptb_c1_r1_portable_soc_smoke.STREAM_DW=1','-Ptb_c1_r1_portable_soc_smoke.CACHE_DW_WEIGHT_TILES=1');
    ExpectedFailure='DW pixel pipeline requires column writeback overlap'}
foreach($dwEngineDot in @(0,1)) {foreach($dwEnginePw in @(0,1)) {foreach($dwEngineTree in @('','C1_PIPELINED_DOT_TREE','C1_PIPELINED_DOT_TREE_FULL')) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@('-Ptb_c1_r1_microstyle_engine.DW_PIXELS=1',
        "-Ptb_c1_r1_microstyle_engine.DOT_PIXELS=$dwEngineDot","-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=$dwEnginePw",
        '-Ptb_c1_r1_microstyle_engine.REQUANT_OVERLAP=1','-DC1_STREAM_DW_GROUPS','-DC1_CACHE_DW_WEIGHT_TILES',
        '-DC1_MAC_PREFETCH_OVERLAP')+$(if($dwEngineTree){@("-D$dwEngineTree")}else{@()});TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_ENGINE_DW_PIXEL_NEXT_HOLD_PASS')}
}}}
foreach($dwPhysicalGroups in @(2,3,6,8)) {foreach($dwPhysicalSlots in @(1,4)) {foreach($dwPhysicalOrder in @(0,1)) {
    $tests+=@{Top='tb_c1_pixel_writer_packing';Flags=@(
        "-Ptb_c1_pixel_writer_packing.GROUPS=$dwPhysicalGroups",
        "-Ptb_c1_pixel_writer_packing.SLOT_COUNT=$dwPhysicalSlots",
        "-Ptb_c1_pixel_writer_packing.W_FIRST=$dwPhysicalOrder");ExtraSources=@('tb_c1_tensor_packing_memory.sv');
        RequiredPassMarkers=@('C1_PIXEL_WRITER_PACKING_PASS','C1_PIXEL_PACKING_PARTIAL_PASS mode=2',
            'C1_PIXEL_PACKING_HELD_PASS','C1_PIXEL_PACKING_EOF_PASS mode=2')}
}}}
foreach($dwNextGroups in @(1,2)) {
    foreach($dwFrame in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        '-Ptb_c1_r1_microstyle_engine.DW_PIXELS=1',"-Ptb_c1_r1_microstyle_engine.DW_PREFETCH_GROUPS=$dwNextGroups",
        "-Ptb_c1_r1_microstyle_engine.DW_FRAME=$dwFrame",
        '-DC1_STREAM_DW_GROUPS','-DC1_CACHE_DW_WEIGHT_TILES');TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_ENGINE_DW_PIXEL_NEXT_HOLD_PASS')}
    }
}
$tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@('-Ptb_c1_r1_microstyle_engine.DW_FRAME=1');
    ExpectedFailure='DW frame streaming requires DW pixel pipeline'}
foreach($dwFrameSmall in @(0,1)) {foreach($dwFramePacked in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        '-Ptb_c1_r1_microstyle_engine.DW_PIXELS=1','-Ptb_c1_r1_microstyle_engine.DW_FRAME=1',
        "-Ptb_c1_r1_microstyle_engine.SMALL_FRAME=$dwFrameSmall",
        '-DC1_STREAM_DW_GROUPS','-DC1_CACHE_DW_WEIGHT_TILES','-DC1_MAC_PREFETCH_OVERLAP')+
        $(if($dwFramePacked){@('-DC1_PACKED_AFFINE_CACHE','-DC1_PIPELINED_DOT_TREE_FULL')}else{@()});
        TimeoutSeconds=60;RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_ENGINE_DW_FRAME_BATCH_PASS',
            'C1_ENGINE_DW_FRAME_HELD_PASS','C1_ENGINE_WARM_RESTART_PASS')}
}}
foreach($dwFrameSlots in @(1,4)) {foreach($dwFrameViews in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.DW_FRAME=1','-Ptb_c1_r1_portable_soc_smoke.DW_PIXELS=1',
        '-Ptb_c1_r1_portable_soc_smoke.STREAM_DW=1','-Ptb_c1_r1_portable_soc_smoke.CACHE_DW_WEIGHT_TILES=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1','-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1',
        '-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1','-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=1',
        '-Ptb_c1_r1_portable_soc_smoke.WRITE_END=1','-Ptb_c1_r1_portable_soc_smoke.PIXEL_BATCH=8',
        "-Ptb_c1_r1_portable_soc_smoke.WRITE_OUTSTANDING=$dwFrameSlots",
        "-Ptb_c1_r1_portable_soc_smoke.VIRTUAL_UPSAMPLE=$dwFrameViews",
        "-Ptb_c1_r1_portable_soc_smoke.ELIDE_VIEWS=$dwFrameViews",
        "-Ptb_c1_r1_portable_soc_smoke.FUSE_FINAL=$dwFrameViews")}
}}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.DW_FRAME=1');
    ExpectedFailure='DW frame streaming requires DW pixel pipeline'}
foreach($dwSinkGroups in @(2,3,6,8)) {foreach($dwSinkBatch in @(1,8)) {
    $tests+=@{Top='tb_c1_pixel_result_writer';Flags=@(
        "-Ptb_c1_pixel_result_writer.GROUPS=$dwSinkGroups","-Ptb_c1_pixel_result_writer.BATCH=$dwSinkBatch");
        RequiredPassMarkers=@('C1_PIXEL_RESULT_WRITER_PASS','C1_PIXEL_WRITER_HELD_ERROR_PASS',
            'C1_PIXEL_WRITER_METADATA_PASS field=6','C1_PIXEL_WRITER_EOF_FENCE_PASS mode=2')}
}}
foreach($batchTimeout in @(8,64)) {foreach($batchSize in @(2,4,8)) {foreach($batchSlots in @(1,2,4)) {foreach($batchWFirst in @(0,1)) {
    $tests+=@{Top='tb_c1_pixel_writer_packing';Flags=@(
        "-Ptb_c1_pixel_writer_packing.BATCH=$batchSize","-Ptb_c1_pixel_writer_packing.SLOT_COUNT=$batchSlots",
        "-Ptb_c1_pixel_writer_packing.W_FIRST=$batchWFirst","-Ptb_c1_pixel_writer_packing.TIMEOUT=$batchTimeout");ExtraSources=@('tb_c1_tensor_packing_memory.sv');
        RequiredPassMarkers=@('C1_PIXEL_WRITER_PACKING_PASS','C1_PIXEL_PACKING_PARTIAL_PASS mode=0',
            'C1_PIXEL_PACKING_PARTIAL_PASS mode=1','C1_PIXEL_PACKING_PARTIAL_PASS mode=2',
            'C1_PIXEL_PACKING_HELD_PASS','C1_PIXEL_PACKING_EOF_PASS mode=0',
            'C1_PIXEL_PACKING_EOF_PASS mode=1','C1_PIXEL_PACKING_EOF_PASS mode=2')}
}}}}
foreach($batchExtreme in @(1,255)) {
    $tests+=@{Top='tb_c1_pixel_writer_packing';Flags=@(
        '-Ptb_c1_pixel_writer_packing.BATCH=8','-Ptb_c1_pixel_writer_packing.SLOT_COUNT=2',
        "-Ptb_c1_pixel_writer_packing.TIMEOUT=$batchExtreme");ExtraSources=@('tb_c1_tensor_packing_memory.sv');
        RequiredPassMarkers=@('C1_PIXEL_WRITER_PACKING_PASS','C1_PIXEL_PACKING_PARTIAL_PASS mode=2',
            'C1_PIXEL_PACKING_HELD_PASS','C1_PIXEL_PACKING_EOF_PASS mode=2')}
}
foreach($batchSmoke in @(2,4,8)) {foreach($batchSmokeSlots in @(1,4)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        "-Ptb_c1_r1_portable_soc_smoke.PIXEL_BATCH=$batchSmoke",
        "-Ptb_c1_r1_portable_soc_smoke.WRITE_OUTSTANDING=$batchSmokeSlots",
        '-Ptb_c1_r1_portable_soc_smoke.WRITE_BUILD_TIMEOUT=64','-Ptb_c1_r1_portable_soc_smoke.WRITE_END=1',
        '-Ptb_c1_r1_portable_soc_smoke.DOT_PIXELS=1','-Ptb_c1_r1_portable_soc_smoke.REQUANT_OVERLAP=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1','-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1','-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1')}
}}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.PIXEL_BATCH=2');
    ExpectedFailure='pixel write batching requires dot or DW pixels, packing and end markers'}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.WRITE_BUILD_TIMEOUT=64');
    ExpectedFailure='tensor write build timeout requires packed column branch'}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
    '-Ptb_c1_r1_portable_soc_smoke.PIXEL_BATCH=2','-Ptb_c1_r1_portable_soc_smoke.WRITE_END=0',
    '-Ptb_c1_r1_portable_soc_smoke.DOT_PIXELS=1','-Ptb_c1_r1_portable_soc_smoke.REQUANT_OVERLAP=1',
    '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1','-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=1',
    '-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1','-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1');
    ExpectedFailure='pixel write batching requires dot or DW pixels, packing and end markers'}
foreach($batchIllegal in @(@(0,15),@(3,15),@(16,15),@(8,3))) {
    $tests+=@{Top='tb_c1_pixel_result_writer';Flags=@(
        "-Ptb_c1_pixel_result_writer.BATCH=$($batchIllegal[0])",
        "-Ptb_c1_pixel_result_writer.CAPACITY=$($batchIllegal[1])");
        ExpectedFailure='pixel writer batch must be 1, 2, 4 or 8 and fit reservations'}
}
foreach($writeBackendFlags in @('', '-Ptb_c1_axi128_write_mlp.DEPENDENT_FIRST_AW=1','-DC1_WRITE_RSP_POP_REFILL_TB')){
    $tests+=@{Top='tb_c1_axi128_write_mlp';Flags=@('-Ptb_c1_axi128_write_mlp.PIPELINE_W=1')+
        @($writeBackendFlags | Where-Object {$_})}
}
$tests+=@{Top='tb_c1_axi128_write_mlp_aw_before_payload';Flags=@('-Ptb_c1_axi128_write_mlp_aw_before_payload.PIPELINE_W=1')}
foreach($mlpSlots in @(2,4)) {foreach($mlpPixels in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        "-Ptb_c1_r1_portable_soc_smoke.WRITE_OUTSTANDING=$mlpSlots",
        "-Ptb_c1_r1_portable_soc_smoke.DOT_PIXELS=$mlpPixels",'-Ptb_c1_r1_portable_soc_smoke.REQUANT_OVERLAP=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1','-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1','-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1')}
}}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.WRITE_OUTSTANDING=2');
    ExpectedFailure='tensor write MLP requires packed column branch'}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.WRITE_OUTSTANDING=3');
    ExpectedFailure='tensor write outstanding must be 1, 2 or 4'}
foreach($orderedSlots in @(2,3,4)) {foreach($orderedDependent in @(0,1)) {foreach($orderedEnd in @(0,1)) {
    $tests+=@{Top='tb_c1_tensor_ordered_write';Flags=@(
        "-Ptb_c1_tensor_ordered_write.SLOTS=$orderedSlots","-Ptb_c1_tensor_ordered_write.DEPENDENT_AW=$orderedDependent",
        "-Ptb_c1_tensor_ordered_write.USE_END=$orderedEnd");
        RequiredPassMarkers=@('C1_ORDERED_WRITE_MLP_PASS','C1_ORDERED_WRITE_RESPONSE_FENCE_PASS','C1_TENSOR_ORDERED_WRITE_PASS')}
}}}
foreach($pixelSmokePw in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.DOT_PIXELS=1','-Ptb_c1_r1_portable_soc_smoke.REQUANT_OVERLAP=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1','-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1',
        '-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1',"-Ptb_c1_r1_portable_soc_smoke.POINTWISE_COLUMNS=$pixelSmokePw")}
}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
    '-Ptb_c1_r1_portable_soc_smoke.DOT_PIXELS=1','-Ptb_c1_r1_portable_soc_smoke.REQUANT_OVERLAP=1',
    '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1','-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1',
    '-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1','-Ptb_c1_r1_portable_soc_smoke.POINTWISE_COLUMNS=1',
    '-Ptb_c1_r1_portable_soc_smoke.PIXEL_PREFETCH=1','-Ptb_c1_r1_portable_soc_smoke.ALL_PIXEL_GROUPS=1')}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
    '-Ptb_c1_r1_portable_soc_smoke.DOT_PIXELS=1','-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
    '-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1','-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1');
    ExpectedFailure='dot pixel pipeline requires MAC requant overlap'}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
    '-Ptb_c1_r1_portable_soc_smoke.DOT_PIXELS=1','-Ptb_c1_r1_portable_soc_smoke.REQUANT_OVERLAP=1');
    ExpectedFailure='dot pixel pipeline requires column writeback overlap'}
foreach($pixelWriterConfig in @(@(1,1,5,4),@(3,1,5,4),@(15,1,5,4),
                              @(3,2,5,4),@(15,2,5,4),@(15,4,17,2),@(15,8,17,2))) {
    $pixelWriterCapacity=$pixelWriterConfig[0]
    $tests+=@{Top='tb_c1_pixel_result_writer';Flags=@("-Ptb_c1_pixel_result_writer.CAPACITY=$pixelWriterCapacity",
        "-Ptb_c1_pixel_result_writer.BATCH=$($pixelWriterConfig[1])",
        "-Ptb_c1_pixel_result_writer.FRAME_W=$($pixelWriterConfig[2])",
        "-Ptb_c1_pixel_result_writer.FRAME_H=$($pixelWriterConfig[3])");
        RequiredPassMarkers=@('C1_PIXEL_RESULT_WRITER_PASS','C1_PIXEL_WRITER_ABORT_PASS',
            'C1_PIXEL_WRITER_CREDIT_ERROR_PASS','C1_PIXEL_WRITER_METADATA_PASS field=6',
            'C1_PIXEL_WRITER_EOF_FENCE_PASS mode=0','C1_PIXEL_WRITER_EOF_FENCE_PASS mode=1',
            'C1_PIXEL_WRITER_EOF_FENCE_PASS mode=2')+
            $(if($pixelWriterCapacity -gt 1){@('C1_PIXEL_WRITER_HELD_ERROR_PASS')}else{@()})}
}
foreach($pixelDotTree in @('','C1_PIPELINED_DOT_TREE','C1_PIPELINED_DOT_TREE_FULL')) {foreach($pixelPw in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        '-Ptb_c1_r1_microstyle_engine.DOT_PIXELS=1','-Ptb_c1_r1_microstyle_engine.REQUANT_OVERLAP=1',
        "-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=$pixelPw",
        '-DC1_CACHE_DW_WEIGHT_TILES','-DC1_STREAM_DW_GROUPS','-DC1_MAC_PREFETCH_OVERLAP')+
        $(if($pixelDotTree){@("-D$pixelDotTree")}else{@()});TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_POINTWISE_PARTIAL_RESTART_PASS')}
}}
foreach($allPfSlowVirtual in @(0,1)) {
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
        '-Ptb_c1_adapter_virtual_upsample.ALL_PIXEL_GROUPS=1',
        '-Ptb_c1_adapter_virtual_upsample.PIXEL_PREFETCH=1','-Ptb_c1_adapter_virtual_upsample.POINTWISE=1',
        "-Ptb_c1_adapter_virtual_upsample.VIRTUAL=$allPfSlowVirtual",
        '-Ptb_c1_adapter_virtual_upsample.SOURCE_PIPELINE=1',
        '-Ptb_c1_adapter_virtual_upsample.OVERLAP=1','-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=1',
        '-Ptb_c1_adapter_virtual_upsample.WRITE_DEPTH=3',
        '-Ptb_c1_adapter_virtual_upsample.WIDTH=12','-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS','C1_PIXEL_PREFETCH_BUDGET_PASS',
            'C1_PIXEL_GROUP_PREFETCH_CANCEL_PASS group=1 held=1 column_first=1',
            'C1_PIXEL_BUFFERED_DEMAND_WRITE_ERROR_PASS held=1','C1_PIXEL_BLOCKED_DEMAND_CANCEL_PASS')}
}
foreach($allPfSmokePw in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.ALL_PIXEL_GROUPS=1',
        '-Ptb_c1_r1_portable_soc_smoke.PIXEL_PREFETCH=1','-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1','-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1',
        "-Ptb_c1_r1_portable_soc_smoke.POINTWISE_COLUMNS=$allPfSmokePw")}
}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.ALL_PIXEL_GROUPS=1');
    ExpectedFailure='all-group pixel prefetch requires next-pixel prefetch'}
foreach($allPfPw in @(0,1)) {foreach($allPfReuse in @(0,1)) {foreach($allPfVirtual in @(0,1)) {
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
        '-Ptb_c1_adapter_virtual_upsample.ALL_PIXEL_GROUPS=1',
        '-Ptb_c1_adapter_virtual_upsample.PIXEL_PREFETCH=1',
        "-Ptb_c1_adapter_virtual_upsample.POINTWISE=$allPfPw",
        "-Ptb_c1_adapter_virtual_upsample.REUSE=$allPfReuse",
        "-Ptb_c1_adapter_virtual_upsample.VIRTUAL=$allPfVirtual",
        '-Ptb_c1_adapter_virtual_upsample.RESPONSE_BYPASS=1','-Ptb_c1_adapter_virtual_upsample.LOOKUP_READS=1',
        '-Ptb_c1_adapter_virtual_upsample.OVERLAP=1','-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=1',
        '-Ptb_c1_adapter_virtual_upsample.WIDTH=8','-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS','C1_PIXEL_PREFETCH_BUDGET_PASS',
            'C1_PIXEL_GROUP_PREFETCH_CANCEL_PASS group=1 held=1 column_first=1',
            'C1_PIXEL_BUFFERED_DEMAND_CANCEL_PASS held=1',
            'C1_PIXEL_BUFFERED_DEMAND_WRITE_ERROR_PASS held=1','C1_PIXEL_BLOCKED_DEMAND_CANCEL_PASS',
            'C1_PIXEL_PREFETCH_CANCEL_PASS held=1 column_first=1','C1_PIXEL_PREFETCH_ERROR_PASS',
            'C1_PIXEL_PREFETCH_WRITE_ERROR_PASS held=1 column_first=1')}
}}}
foreach($rqEngineTree in @('','C1_PIPELINED_DOT_TREE','C1_PIPELINED_DOT_TREE_FULL')) {
  foreach($rqPw in @(0,1)) {foreach($rqMac in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        '-Ptb_c1_r1_microstyle_engine.REQUANT_OVERLAP=1',"-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=$rqPw",
        '-DC1_CACHE_DW_WEIGHT_TILES','-DC1_STREAM_DW_GROUPS')+
        $(if($rqMac){@('-DC1_MAC_PREFETCH_OVERLAP')}else{@()})+
        $(if($rqEngineTree){@("-D$rqEngineTree")}else{@()});TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_ENGINE_REQUANT_FULL_HOLD_PASS groups=6',
            'C1_POINTWISE_PARTIAL_RESTART_PASS')}
  }}
}
foreach($rqTree in @(0,1,2)) {
    $tests+=@{Top='tb_c1_dot8x8_requant_overlap';Flags=@("-Ptb_c1_dot8x8_requant_overlap.TREE=$rqTree");
        RequiredPassMarkers=@('C1_DOT_REQUANT_RESET_PASS discarded=6',
            'C1_DOT_REQUANT_FULL_DRAIN_PASS outputs=160 peak=6','C1_DOT_REQUANT_OVERLAP_PASS')}
}
foreach($rqSmokePw in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.REQUANT_OVERLAP=1',
        "-Ptb_c1_r1_portable_soc_smoke.POINTWISE_REDUCTION=$rqSmokePw")}
}
foreach($pwSmokeColumns in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.POINTWISE_REDUCTION=1',
        "-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=$pwSmokeColumns")}
}
foreach($pwBase in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        "-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=$pwBase",'-DC1_NONZERO_CYCLE_BUDGET');TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS')+
            $(if($pwBase){@('C1_POINTWISE_PARTIAL_RESTART_PASS','C1_POINTWISE_OUTPUT_HOLD_PASS')}else{@()})}
}
foreach($pwStream in @(0,1)) {foreach($pwOverlap in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        "-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=$pwStream",
        '-DC1_CACHE_DW_WEIGHT_TILES','-DC1_STREAM_DW_GROUPS')+
        $(if($pwOverlap){@('-DC1_MAC_PREFETCH_OVERLAP')}else{@()});TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_ENGINE_WARM_RESTART_PASS')+
            $(if($pwStream){@('C1_POINTWISE_PARTIAL_DRAIN_PASS fault=2','C1_POINTWISE_PARTIAL_RESTART_PASS','C1_POINTWISE_OUTPUT_HOLD_PASS')}else{@()})}
}}
foreach($pwTree in @('C1_PIPELINED_DOT_TREE','C1_PIPELINED_DOT_TREE_FULL')) {foreach($pwOverlap in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_engine';Flags=@(
        '-Ptb_c1_r1_microstyle_engine.POINTWISE_STREAM=1',"-D$pwTree",
        '-DC1_CACHE_DW_WEIGHT_TILES','-DC1_STREAM_DW_GROUPS')+
        $(if($pwOverlap){@('-DC1_MAC_PREFETCH_OVERLAP')}else{@()});TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_ENGINE_PASS','C1_POINTWISE_PARTIAL_RESTART_PASS','C1_POINTWISE_OUTPUT_HOLD_PASS')}
}}
foreach($sourceSmokeColumns in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.SOURCE_PIPELINE=1',
        "-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=$sourceSmokeColumns")}
}
foreach($sourceDepth in @(1,3,16)) {foreach($sourceResult in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=@(
        '-Ptb_c1_r1_microstyle_tensor_adapter.SOURCE_PIPELINE=1',
        "-Ptb_c1_r1_microstyle_tensor_adapter.RESPONSE_DEPTH=$sourceDepth",
        "-Ptb_c1_r1_microstyle_tensor_adapter.PIPELINED_WRITES=$sourceResult",
        '-Ptb_c1_r1_microstyle_tensor_adapter.RUN_WRITE_DRAIN_SCENARIOS=0');
        TimeoutSeconds=60;RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS',
        'C1_SOURCE_PIPELINE_PROTOCOL_PASS bad_field=2','C1_SOURCE_PIPELINE_EOF_PASS fault=0',
        'C1_SOURCE_PIPELINE_EOF_PASS fault=1')+
        $(if($sourceDepth>=3){@('C1_SOURCE_PIPELINE_DRAIN_PASS fault=1 held=1')}else{@()})+
        $(if($sourceDepth>=15){@('C1_SOURCE_PIPELINE_CREDIT_PASS peak=15')}else{@()})}
}}
foreach($sourcePixel in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=@(
        '-Ptb_c1_r1_microstyle_tensor_adapter.SOURCE_PIPELINE=1',
        '-Ptb_c1_r1_microstyle_tensor_adapter.RESPONSE_DEPTH=3',
        '-Ptb_c1_r1_microstyle_tensor_adapter.FRAME_W=12',
        '-DC1_PIPELINED_TENSOR_ADDRESS') + $(if($sourcePixel){@('-DC1_PIPELINED_TENSOR_PIXEL_INDEX')}else{@()});
        TimeoutSeconds=60;RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS',
            'C1_SOURCE_PIPELINE_DRAIN_PASS fault=1 held=1','C1_SOURCE_PIPELINE_EOF_PASS fault=0')}
}
foreach($sourceWidth in @(8,12)) {
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
        '-Ptb_c1_adapter_virtual_upsample.SOURCE_PIPELINE=1',
        '-Ptb_c1_adapter_virtual_upsample.PIXEL_PREFETCH=1','-Ptb_c1_adapter_virtual_upsample.POINTWISE=1',
        '-Ptb_c1_adapter_virtual_upsample.RESPONSE_BYPASS=1','-Ptb_c1_adapter_virtual_upsample.LOOKUP_READS=1',
        '-Ptb_c1_adapter_virtual_upsample.WRITE_DEPTH=3',
        '-Ptb_c1_adapter_virtual_upsample.OVERLAP=1','-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=1',
        "-Ptb_c1_adapter_virtual_upsample.WIDTH=$sourceWidth",'-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS',
            'C1_SOURCE_PIPELINE_DRAIN_PASS fault=1 held=1','C1_PIXEL_PREFETCH_BUDGET_PASS')}
}
$tests+=@{Top='tb_c1_r1_microstyle_bridge_fault_boundary';Flags=@();
    RequiredPassMarkers=@('C1_R1_MICROSTYLE_BRIDGE_FAULT_BOUNDARY_PASS',
        'C1_BRIDGE_LATE_ABORT_ERROR_PASS delay=0','C1_BRIDGE_LATE_ABORT_ERROR_PASS delay=3',
        'C1_BRIDGE_LATE_ABORT_ERROR_PASS delay=6')}
foreach($pixelPfPointwise in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.PIXEL_PREFETCH=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1','-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1',
        '-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1',
        "-Ptb_c1_r1_portable_soc_smoke.POINTWISE_COLUMNS=$pixelPfPointwise")}
}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.PIXEL_PREFETCH=1');
    ExpectedFailure='pixel column prefetch requires column writeback overlap'}
foreach($pixelPfPointwise in @(0,1)) {foreach($pixelPfVirtual in @(0,1)) {
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
        '-Ptb_c1_adapter_virtual_upsample.PIXEL_PREFETCH=1',
        "-Ptb_c1_adapter_virtual_upsample.POINTWISE=$pixelPfPointwise",
        "-Ptb_c1_adapter_virtual_upsample.VIRTUAL=$pixelPfVirtual",
        '-Ptb_c1_adapter_virtual_upsample.RESPONSE_BYPASS=1','-Ptb_c1_adapter_virtual_upsample.LOOKUP_READS=1',
        '-Ptb_c1_adapter_virtual_upsample.OVERLAP=1','-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=1',
        '-Ptb_c1_adapter_virtual_upsample.WIDTH=8','-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS','C1_PIXEL_PREFETCH_BUDGET_PASS',
            'C1_PIXEL_PREFETCH_CANCEL_PASS held=1 column_first=1','C1_PIXEL_PREFETCH_ERROR_PASS',
            'C1_PIXEL_PREFETCH_WRITE_ERROR_PASS held=1 column_first=1')}
}}
foreach($pixelPfVirtual in @(0,1)) {
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
        '-Ptb_c1_adapter_virtual_upsample.PIXEL_PREFETCH=1','-Ptb_c1_adapter_virtual_upsample.POINTWISE=1',
        "-Ptb_c1_adapter_virtual_upsample.VIRTUAL=$pixelPfVirtual",'-Ptb_c1_adapter_virtual_upsample.REUSE=0',
        '-Ptb_c1_adapter_virtual_upsample.OVERLAP=1','-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=1',
        '-Ptb_c1_adapter_virtual_upsample.WIDTH=12','-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS','C1_PIXEL_PREFETCH_BUDGET_PASS',
            'C1_PIXEL_PREFETCH_CANCEL_PASS held=1 column_first=1','C1_PIXEL_PREFETCH_ERROR_PASS',
            'C1_PIXEL_PREFETCH_WRITE_ERROR_PASS held=1 column_first=1')}
}
foreach($bypassLookup in @(0,1)) {foreach($bypassPointwise in @(0,1)) {
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
        '-Ptb_c1_adapter_virtual_upsample.RESPONSE_BYPASS=1',
        "-Ptb_c1_adapter_virtual_upsample.LOOKUP_READS=$bypassLookup",
        "-Ptb_c1_adapter_virtual_upsample.POINTWISE=$bypassPointwise",
        '-Ptb_c1_adapter_virtual_upsample.OVERLAP=1','-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=1',
        '-Ptb_c1_adapter_virtual_upsample.WIDTH=8','-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS',
            'C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=1 write_fault=1 column_first=1') +
            $(if($bypassPointwise){@('C1_POINTWISE_COLUMN_DUAL_DRAIN_PASS stage=19 held=1 fault=1 column_first=1')}else{@()})}
}}
foreach($rowMapColumns in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_ROW_MAP=1',
        "-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=$rowMapColumns");
        ExpectedFailure=$(if($rowMapColumns){$null}else{'column row-map reuse requires tensor column reads'})}
}
foreach($bypassLookup in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_RESPONSE_BYPASS=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
        "-Ptb_c1_r1_portable_soc_smoke.COLUMN_LOOKUP_READS=$bypassLookup")}
}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.COLUMN_RESPONSE_BYPASS=1');
    ExpectedFailure='column response bypass requires tensor column reads'}
foreach($pointwiseOverlap in @(0,1)) {foreach($pointwiseVirtual in @(0,1)) {
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
        '-Ptb_c1_adapter_virtual_upsample.POINTWISE=1',
        "-Ptb_c1_adapter_virtual_upsample.OVERLAP=$pointwiseOverlap",
        "-Ptb_c1_adapter_virtual_upsample.VIRTUAL=$pointwiseVirtual",
        '-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=1',
        '-Ptb_c1_adapter_virtual_upsample.WIDTH=8','-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');
        TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS','C1_POINTWISE_COLUMN_BUDGET_PASS',
            'C1_POINTWISE_COLUMN_ERROR_PASS stage=19','C1_POINTWISE_COLUMN_ABORT_PASS stage=19 held=1 fault=1') +
            $(if($pointwiseOverlap){@('C1_POINTWISE_COLUMN_DUAL_DRAIN_PASS stage=19 held=1 fault=1 column_first=1')}else{@()})}
}}
foreach($pointwiseVirtual in @(0,1)) {
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
        '-Ptb_c1_adapter_virtual_upsample.POINTWISE=1',
        "-Ptb_c1_adapter_virtual_upsample.VIRTUAL=$pointwiseVirtual",
        '-Ptb_c1_adapter_virtual_upsample.REUSE=0',
        '-Ptb_c1_adapter_virtual_upsample.WIDTH=12','-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');TimeoutSeconds=60;
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS','C1_POINTWISE_COLUMN_BUDGET_PASS',
            'C1_POINTWISE_COLUMN_ERROR_PASS stage=19','C1_POINTWISE_COLUMN_ABORT_PASS stage=19 held=1 fault=1')}
}
foreach($pointwisePipeline in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.POINTWISE_COLUMNS=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
        "-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=$pointwisePipeline",
        "-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=$pointwisePipeline")}
}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.POINTWISE_COLUMNS=1');
    ExpectedFailure='pointwise column reads require the column interface'}
foreach($overlapPacked in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1',
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1','-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1',
        "-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=$overlapPacked")}
}
foreach($overlapMissing in @('COLUMN_READS','PIPE_RESULT_WRITES')) {
    $overlapFlags=@('-Ptb_c1_r1_portable_soc_smoke.COLUMN_WRITE_OVERLAP=1')
    if($overlapMissing -eq 'COLUMN_READS') {$overlapFlags+='-Ptb_c1_r1_portable_soc_smoke.PIPE_RESULT_WRITES=1'}
    else {$overlapFlags+='-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1'}
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=$overlapFlags;
        ExpectedFailure='column writeback overlap requires columns and pipelined writes'}
}
foreach($overlapVirtual in @(0,1)) {foreach($overlapReuse in @(0,1)) {
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
        '-Ptb_c1_adapter_virtual_upsample.OVERLAP=1','-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=1',
        "-Ptb_c1_adapter_virtual_upsample.VIRTUAL=$overlapVirtual",
        "-Ptb_c1_adapter_virtual_upsample.REUSE=$overlapReuse",
        '-Ptb_c1_adapter_virtual_upsample.WIDTH=8','-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS','C1_ADAPTER_PIPELINED_WRITES_PASS',
            'C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=0 write_fault=0 column_first=0',
            'C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=0 write_fault=0 column_first=1',
            'C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=0 write_fault=1 column_first=0',
            'C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=0 write_fault=1 column_first=1',
            'C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=1 write_fault=0 column_first=0',
            'C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=1 write_fault=0 column_first=1',
            'C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=1 write_fault=1 column_first=0',
            'C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=1 write_fault=1 column_first=1')}
}}
$tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=@(
    '-Ptb_c1_adapter_virtual_upsample.OVERLAP=1','-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=1',
    '-Ptb_c1_adapter_virtual_upsample.WRITE_DEPTH=20',
    '-Ptb_c1_adapter_virtual_upsample.WIDTH=8','-Ptb_c1_adapter_virtual_upsample.HEIGHT=8');
    ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');
    RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS','C1_COLUMN_WRITE_CREDIT_PASS')}
$tests+=@{Top='tb_c1_tensor_mem_axi128_bridge';Flags=@();
    RequiredPassMarkers=@('C1_TENSOR_MEM_AXI128_BRIDGE_PASS')}
foreach($precisePreview in @(0,1)) { foreach($precisePack in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
        '-Ptb_c1_r1_portable_soc_smoke.SCALAR_READ_CACHE=1',
        '-Ptb_c1_r1_portable_soc_smoke.PRECISE_INVALIDATION=1',
        "-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=$precisePack",
        "-Ptb_c1_r1_portable_soc_smoke.PREVIEW_CAPTURE=$precisePreview")}
} }
foreach($preciseEntries in @(1,2)){foreach($precise in @(0,1)) { foreach($precisePacked in @(0,1)) { foreach($preciseWFirst in @(0,1)) {
    $tests+=@{Top='tb_c1_tensor_read_cache_invalidation';Flags=@(
        "-Ptb_c1_tensor_read_cache_invalidation.PRECISE=$precise",
        "-Ptb_c1_tensor_read_cache_invalidation.ENTRIES=$preciseEntries",
        "-Ptb_c1_tensor_read_cache_invalidation.PACKED=$precisePacked",
        "-Ptb_c1_tensor_read_cache_invalidation.W_FIRST=$preciseWFirst");
        ExtraSources=@('tb_c1_tensor_packing_memory.sv');
        RequiredPassMarkers=@('C1_PRECISE_TAG_QUERY_PASS tag_bits=28 offsets=16 raw_during_fence=1',
            "C1_PRECISE_INVALIDATION_PASS precise=$precise packed=$precisePacked w_first=$preciseWFirst masks=1024")}
} } } }
foreach($readEntries in @(1,2)){foreach($readCache in @(0,1)) { foreach($readPacked in @(0,1)) { foreach($readWFirst in @(0,1)) { foreach($readPrecise in @(0,1)) {
    $tests+=@{Top='tb_c1_tensor_read_beat_cache';Flags=@(
        "-Ptb_c1_tensor_read_beat_cache.CACHE=$readCache",
        "-Ptb_c1_tensor_read_beat_cache.ENTRIES=$readEntries",
        "-Ptb_c1_tensor_read_beat_cache.PACKED=$readPacked",
        "-Ptb_c1_tensor_read_beat_cache.W_FIRST=$readWFirst",
        "-Ptb_c1_tensor_read_beat_cache.PRECISE=$readPrecise");
        ExtraSources=@('tb_c1_tensor_packing_memory.sv');
        RequiredPassMarkers=@("C1_READ_BEAT_CACHE_PASS cache=$readCache packed=$readPacked w_first=$readWFirst precise=$readPrecise checked_reads=24")}
} } } } }
foreach($columnPreview in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
        "-Ptb_c1_r1_portable_soc_smoke.PREVIEW_CAPTURE=$columnPreview")}
}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.VIRTUAL_UPSAMPLE=1');
    ExpectedFailure='virtual upsample tensors require'}
$tests+=@{Top='tb_c1_dwconv3x3_c8_requant_core';Flags=@();RequiredPassMarkers=@('C1_DWCONV3X3_C8_REQUANT_CORE_PASS')}
$tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.STREAM_DW=1');
    ExpectedFailure='STREAM_DW_GROUPS requires cached DW weight tiles'}
foreach($dwColumns in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.STREAM_DW=1',
        '-Ptb_c1_r1_portable_soc_smoke.CACHE_DW_WEIGHT_TILES=1',
        "-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=$dwColumns")}
}
foreach($dwRandom in @(0,1)) {
    $tests+=@{Top='tb_c1_dwconv_stream_config';Flags=@("-Ptb_c1_dwconv_stream_config.RANDOM_STALLS=$dwRandom");
        RequiredPassMarkers=@('C1_DW_STREAM_CONFIG_PASS','C1_DW_STREAM_WITNESS_PASS')}
}
foreach($virtualPacked in @(0,1)) {foreach($virtualPreview in @(0,1)) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@('-Ptb_c1_r1_portable_soc_smoke.COLUMN_READS=1',
        '-Ptb_c1_r1_portable_soc_smoke.VIRTUAL_UPSAMPLE=1',
        "-Ptb_c1_r1_portable_soc_smoke.PACKED_TENSOR_WRITES=$virtualPacked",
        "-Ptb_c1_r1_portable_soc_smoke.PREVIEW_CAPTURE=$virtualPreview")}
}}
foreach($virtualMode in @(0,1)) { foreach($virtualCase in @(@(4,4,0,0),@(4,4,1,0),@(12,8,1,0),@(20,12,1,1))) {
    $virtualFlags=@("-Ptb_c1_adapter_virtual_upsample.VIRTUAL=$virtualMode",
        "-Ptb_c1_adapter_virtual_upsample.WIDTH=$($virtualCase[0])",
        "-Ptb_c1_adapter_virtual_upsample.HEIGHT=$($virtualCase[1])",
        "-Ptb_c1_adapter_virtual_upsample.REUSE=$($virtualCase[2])",
        "-Ptb_c1_adapter_virtual_upsample.PIPE_WRITES=$($virtualCase[3])")
    if($virtualCase[3]){$virtualFlags+=@('-DC1_PIPELINED_TENSOR_ADDRESS','-DC1_PIPELINED_TENSOR_PIXEL_INDEX')}
    $virtualMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS',
        "C1_VIRTUAL_UPSAMPLE_BUDGET_PASS enabled=$virtualMode",
        'C1_ADAPTER_COLUMN_OWNER_STALL_PASS','C1_ADAPTER_COLUMN_ERROR_PASS')
    if($virtualMode){$virtualMarkers+=@('C1_VIRTUAL_UPSAMPLE_ABORT_PASS stage=15 held=0 fault=0 full_restart=1',
        'C1_VIRTUAL_UPSAMPLE_ABORT_PASS stage=18 held=1 fault=1 full_restart=1',
        'C1_VIRTUAL_UPSAMPLE_RESULT_ABORT_PASS stage=14 eof=0 no_stage_advance=1 full_restart=1 reset=0',
        'C1_VIRTUAL_UPSAMPLE_RESULT_ABORT_PASS stage=17 eof=1 no_stage_advance=1 full_restart=1 reset=0')}
    $tests+=@{Top='tb_c1_adapter_virtual_upsample';Flags=$virtualFlags;
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');RequiredPassMarkers=$virtualMarkers;
        # Includes numerous full no-reset restarts, including two late-stage
        # result cancellation boundaries. Measured ~39 s for the largest
        # case; all other configurations keep the 30 s watchdog.
        TimeoutSeconds=$(if($virtualCase[0] -eq 20){60}else{30})}
}}
foreach($ownerReuse in @(0,1)) {
    $tests+=@{Top='tb_c1_adapter_column_cache';Flags=@('-Ptb_c1_adapter_column_cache.OWNER=1',
        "-Ptb_c1_adapter_column_cache.REUSE=$ownerReuse");
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');
        RequiredPassMarkers=@('C1_ADAPTER_COLUMN_BUDGET_PASS','C1_ADAPTER_COLUMN_ERROR_PASS',
            'C1_ADAPTER_COLUMN_ABORT_PASS held_request=0 fault=0',
            'C1_ADAPTER_COLUMN_ABORT_PASS held_request=0 fault=1',
            'C1_ADAPTER_COLUMN_ABORT_PASS held_request=1 fault=0',
            'C1_ADAPTER_COLUMN_ABORT_PASS held_request=1 fault=1',
            'C1_ADAPTER_COLUMN_OWNER_STALL_PASS deferred_fence=1 real_cache=1 full_restart=1')}
}
$tests+=@{Top='tb_c1_column_transaction_owner';Flags=@();
    RequiredPassMarkers=@('C1_COLUMN_OWNER_PASS')}
foreach($columnShape in @(@(0,8,4),@(1,8,4),@(0,4,4),@(1,4,4),@(0,12,8),@(1,12,8),@(1,20,12),@(1,8,8))) {
    $tests+=@{Top='tb_c1_adapter_column_cache';Flags=@(
        "-Ptb_c1_adapter_column_cache.REUSE=$($columnShape[0])",
        "-Ptb_c1_adapter_column_cache.WIDTH=$($columnShape[1])",
        "-Ptb_c1_adapter_column_cache.HEIGHT=$($columnShape[2])");
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');
        RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS','C1_ADAPTER_COLUMN_BUDGET_PASS',
            'C1_ADAPTER_COLUMN_ABORT_PASS held_request=0 fault=0',
            'C1_ADAPTER_COLUMN_ABORT_PASS held_request=0 fault=1',
            'C1_ADAPTER_COLUMN_ABORT_PASS held_request=1 fault=0',
            'C1_ADAPTER_COLUMN_ABORT_PASS held_request=1 fault=1','C1_ADAPTER_COLUMN_ERROR_PASS')}
}
$tests+=@{Top='tb_c1_adapter_column_cache';Flags=@(
    '-Ptb_c1_adapter_column_cache.PIPE_WRITES=1','-Ptb_c1_adapter_column_cache.PREFETCH=1',
    '-Ptb_c1_adapter_column_cache.PRECLAMPED=1',
    '-DC1_PIPELINED_TENSOR_ADDRESS','-DC1_PIPELINED_TENSOR_PIXEL_INDEX');
    ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');
    RequiredPassMarkers=@('C1_ADAPTER_COLUMN_BUDGET_PASS','C1_ADAPTER_COLUMN_ERROR_PASS',
        'C1_ADAPTER_PIPELINED_WRITES_PASS','C1_ADAPTER_WRITE_DRAIN_PASS fault=0',
        'C1_ADAPTER_WRITE_DRAIN_PASS fault=1','C1_ADAPTER_COLUMN_ABORT_PASS held_request=1 fault=1')}
# The real exact scheduler/AXI column composition is run with the detached
# xsim runner (-ColumnCache); its first Icarus attempt exceeded the wall limit.
# Do not count a simulator timeout as a regression pass or include an
# unverified scheduler composition in this default portable suite.
foreach($columnReuse in @(0,1)) {foreach($columnBypass in @(0,1)) {foreach($columnFast in @(0,1)) { foreach($columnShape in @(@(3,13),@(4,13),@(3,1280))) {
    $tests+=@{Top='tb_c1_column_line_cache_c8';Flags=@(
        "-Ptb_c1_column_line_cache_c8.ROWS=$($columnShape[0])",
        "-Ptb_c1_column_line_cache_c8.CAPACITY=$($columnShape[1])",
        "-Ptb_c1_column_line_cache_c8.READ_ON_LOOKUP=$columnFast",
        "-Ptb_c1_column_line_cache_c8.RESPONSE_BYPASS=$columnBypass",
        "-Ptb_c1_column_line_cache_c8.REUSE_ROW_MAP=$columnReuse");
        RequiredPassMarkers=@('C1_COLUMN_CACHE_PASS',
            "C1_COLUMN_CACHE_HIT_RATE_PASS columns=12 initiation_interval=$($(if($columnReuse){3}else{5-$columnFast})-$columnBypass) words_per_column=3",
            "C1_COLUMN_ROW_MAP_CONTRACT_PASS enabled=$columnReuse",
            'C1_COLUMN_CACHE_FAULT_PASS mode=1',
            'C1_COLUMN_CACHE_FAULT_PASS mode=2',
            'C1_COLUMN_CACHE_FAULT_PASS mode=3',
            'C1_COLUMN_CACHE_CANCEL_PASS phase=0 kind=1',
            'C1_COLUMN_CACHE_CANCEL_PASS phase=1 kind=3',
            'C1_COLUMN_CACHE_CANCEL_PASS phase=2 kind=3',
            'C1_COLUMN_CACHE_CANCEL_PASS phase=3 kind=3',
            'C1_COLUMN_CACHE_CANCEL_PASS phase=4 kind=3',
            'C1_COLUMN_CACHE_CANCEL_PASS phase=5 kind=3') +
            $(if($columnBypass){@('C1_COLUMN_CACHE_BYPASS_RETIRE_FENCE_PASS kind=1',
                'C1_COLUMN_CACHE_BYPASS_RETIRE_FENCE_PASS kind=2',
                'C1_COLUMN_CACHE_BYPASS_RETIRE_FENCE_PASS kind=3')}else{@()}) +
            $(if($columnReuse){@('C1_COLUMN_ROW_MAP_FENCE_PASS kind=1',
                'C1_COLUMN_ROW_MAP_FENCE_PASS kind=2','C1_COLUMN_ROW_MAP_FENCE_PASS kind=3')}else{@()})}
}
}
}
}
foreach($rowShape in @(@(1,1),@(3,5),@(4,16),@(3,1280))) {
    $tests+=@{Top='tb_c1_row_banked_ram';Flags=@(
        "-Ptb_c1_row_banked_ram.ROWS=$($rowShape[0])",
        "-Ptb_c1_row_banked_ram.WORDS=$($rowShape[1])");
        RequiredPassMarkers=@('C1_ROW_BANKED_RAM_PASS')}
}
foreach($rowFault in @(1,2,3,4,5,6)) {
    $rowDiagnostic = switch ($rowFault) {
        1 {'read address out of range'}
        2 {'write address out of range'}
        3 {'read address out of range'}
        4 {'write address out of range'}
        5 {'read enable unknown'}
        6 {'write enable unknown'}
    }
    $tests+=@{Top='tb_c1_row_banked_ram';Flags=@("-Ptb_c1_row_banked_ram.FAULT=$rowFault");
        ExpectedFailure=('row-banked RAM '+$rowDiagnostic)}
}
$tests += @{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
    '-Ptb_c1_r1_portable_soc_smoke.PREFETCH_NEXT_TAP_ADDRESS=1');
    RequiredPassMarkers=@('C1_SOC_TAP_ADDRESS_OPTION_PASS enabled=1')}
foreach($irqWidth in @(1,8)) {
    for($irqIndex=0; $irqIndex -lt $irqWidth; $irqIndex++) {
        $tests += @{Top='tb_c1_sapphire_irq_adapter';Flags=@(
            "-Ptb_c1_sapphire_irq_adapter.COUNT=$irqWidth",
            "-Ptb_c1_sapphire_irq_adapter.INDEX=$irqIndex");
            RequiredPassMarkers=@('C1_SAPPHIRE_IRQ_ADAPTER_PASS')}
    }
}
foreach($irqBad in @(@(1,1),@(8,8),@(8,-1))) {
    $tests += @{Top='tb_c1_sapphire_irq_adapter';Flags=@(
        "-Ptb_c1_sapphire_irq_adapter.COUNT=$($irqBad[0])",
        "-Ptb_c1_sapphire_irq_adapter.INDEX=$($irqBad[1])");
        ExpectedFailure='USER_INTERRUPT_INDEX must fit USER_INTERRUPT_COUNT'}
}
$tests += @{Top='tb_c1_sapphire_irq_adapter';Flags=@(
    '-Ptb_c1_sapphire_irq_adapter.COUNT=9');
    ExpectedFailure='USER_INTERRUPT_COUNT must be in the range 1..8'}
$tests += @{Top='tb_c1_apb_irq_events';Flags=@();RequiredPassMarkers=@('C1_APB_IRQ_EVENTS_PASS','C1_APB_ERROR_SNAPSHOT_PASS')}
$tests += @{Top='tb_c1_apb_recovery_events';Flags=@();RequiredPassMarkers=@('C1_APB_RECOVERY_EVENTS_PASS')}
foreach($recoverSocQueued in @(0,1)) {
    foreach($recoverSocTicket in @(0,1)) {
        $tests += @{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
            '-Ptb_c1_r1_portable_soc_smoke.EXPLICIT_RECOVERY=1',
            "-Ptb_c1_r1_portable_soc_smoke.QUEUED_WRITE=$recoverSocQueued",
            "-Ptb_c1_r1_portable_soc_smoke.FATAL_TICKET=$recoverSocTicket");
            RequiredPassMarkers=@('C1_SOC_EXPLICIT_RECOVERY_SMOKE_PASS','C1_SOC_APB_RECOVERY_PASS','C1_SOC_APB_RECOVERY_RACE_PASS')}
    }
}
foreach($recoveryWriterStall in @(0,1,2)) {
    foreach($recoveryTableFifo in @(0,1)) {
    foreach($recoveryTable in @(0,1,2)) {
    foreach($recoveryWriterHalf in @(3,7)) {
        $tests += @{Top='tb_c1_capture_raster_writer_drain';Flags=@(
            '-Ptb_c1_capture_raster_writer_drain.EXPLICIT_RECOVERY=1',
            "-Ptb_c1_capture_raster_writer_drain.TABLE_INFLIGHT=$recoveryTable",
            "-Ptb_c1_capture_raster_writer_drain.TABLE_FIFO=$recoveryTableFifo",
            "-Ptb_c1_capture_raster_writer_drain.STALL=$recoveryWriterStall",
            "-Ptb_c1_capture_raster_writer_drain.CAMERA_HALF=$recoveryWriterHalf");
            ExtraSources=@('c1_rv_hold_checker.sv');
            RequiredPassMarkers=@('C1_CAPTURE_SUBSYSTEM_RECOVERY_PASS')}
    }
    }
    }
}
foreach($explicitMode in @(0,1,2)) {
    foreach($explicitHalf in @(3,7)) {
        $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
            '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
            '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
            '-Ptb_c1_r1_capture_frontend.FLOW_FIFO_DEPTH=128',
            '-Ptb_c1_r1_capture_frontend.IDLE_TIMEOUT=16',
            '-Ptb_c1_r1_capture_frontend.RASTER_CASE=8',
            "-Ptb_c1_r1_capture_frontend.MAINTENANCE_MODE=$explicitMode",
            "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$explicitHalf");
            RequiredPassMarkers=@('C1_CAPTURE_EXPLICIT_RECOVERY_PASS')}
    }
}
foreach($recoveryCameraHalf in @(3,7,17)) {
    $tests += @{Top='tb_c1_capture_recovery_fence';Flags=@(
        "-Ptb_c1_capture_recovery_fence.CAMERA_HALF=$recoveryCameraHalf");
        RequiredPassMarkers=@('C1_CAPTURE_RECOVERY_FENCE_PASS')}
}
foreach($invalidIdleTimeout in @(-1,16)) {
    $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
        "-Ptb_c1_r1_capture_frontend.IDLE_TIMEOUT=$invalidIdleTimeout");
        ExpectedFailure='RAW idle timeout requires nonnegative cycles and raster checking'}
}
foreach($timeoutFlowHalf in @(3,7)) {
    $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
        '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
        '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
        '-Ptb_c1_r1_capture_frontend.CHECK_RASTER=1',
        '-Ptb_c1_r1_capture_frontend.IDLE_TIMEOUT=16',
        "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$timeoutFlowHalf");
        RequiredPassMarkers=@('C1_CAPTURE_PAUSABLE_FRAMES_PASS')}
}
foreach($rawTimeout in @(16,33)) {
    foreach($timeoutAbort in @(1,0)) {
    foreach($timeoutHalf in @(3,7)) {
        $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
            '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
            '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
            '-Ptb_c1_r1_capture_frontend.FLOW_FIFO_DEPTH=128',
            '-Ptb_c1_r1_capture_frontend.RASTER_CASE=7',
            "-Ptb_c1_r1_capture_frontend.RASTER_ABORT=$timeoutAbort",
            "-Ptb_c1_r1_capture_frontend.IDLE_TIMEOUT=$rawTimeout",
            "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$timeoutHalf");
            RequiredPassMarkers=@('C1_RAW_IDLE_TIMEOUT_HOLD_PASS','C1_CAPTURE_RASTER_RECOVERY_PASS')}
    }
    }
}
foreach($maintenanceHalf in @(3,7)) {
    foreach($maintenanceMode in @(0,1,2)) {
    $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
        '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
        '-Ptb_c1_r1_capture_frontend.FLOW_FIFO_DEPTH=128',
        '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
        '-Ptb_c1_r1_capture_frontend.RASTER_CASE=6',
        "-Ptb_c1_r1_capture_frontend.MAINTENANCE_MODE=$maintenanceMode",
        "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$maintenanceHalf");
        RequiredPassMarkers=@('C1_CAPTURE_MAINTENANCE_SOF_PASS')}
    }
}
foreach($clearCollision in @(5,6)) {
    foreach($clearCameraHalf in @(3,7)) {
        $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
            "-Ptb_c1_r1_capture_frontend.BACKPRESSURE_CASE=$clearCollision",
            "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$clearCameraHalf");
            RequiredPassMarkers=@('C1_CAMERA_CLEAR_COLLISION_PASS')}
    }
}
foreach($captureFaultOrder in @(1,2)) {
    foreach($captureFaultTicket in @(0,1)) {
        $captureFaultFlags=@("-Ptb_c1_r1_soc_control.CAPTURE_FAULT_DRAIN=$captureFaultOrder")
        if($captureFaultTicket) {$captureFaultFlags+='-DC1_REGISTER_FATAL_TICKET'}
        $tests += @{Top='tb_c1_r1_soc_control';Flags=$captureFaultFlags;
            RequiredPassMarkers=@('C1_SOC_CAPTURE_FAULT_DRAIN_PASS')}
    }
}
foreach($captureBits in @(3,4)) {
    foreach($captureAxis in @(0,1)) {
    foreach($captureStall in @(0,1,2)) {
        foreach($captureHalf in @(3,7)) {
            $tests += @{Top='tb_c1_capture_raster_writer_drain';Flags=@(
                "-Ptb_c1_capture_raster_writer_drain.COORD_BITS=$captureBits",
                "-Ptb_c1_capture_raster_writer_drain.FAULT_AXIS=$captureAxis",
                "-Ptb_c1_capture_raster_writer_drain.STALL=$captureStall",
                "-Ptb_c1_capture_raster_writer_drain.CAMERA_HALF=$captureHalf");
                ExtraSources=@('c1_rv_hold_checker.sv');
                RequiredPassMarkers=@('C1_CAPTURE_RASTER_WRITER_DRAIN_PASS')}
        }
    }
    }
}
foreach($rasterFault in 1..5) {
    foreach($rasterAbort in @(0,1)) {
    foreach($rasterHalf in @(3,7)) {
        $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
            '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
            '-Ptb_c1_r1_capture_frontend.FLOW_FIFO_DEPTH=128',
            '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
            "-Ptb_c1_r1_capture_frontend.RASTER_CASE=$rasterFault",
            "-Ptb_c1_r1_capture_frontend.RASTER_ABORT=$rasterAbort",
            "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$rasterHalf");
            RequiredPassMarkers=@('C1_CAPTURE_RASTER_RECOVERY_PASS')}
    }
    }
}
foreach($guardRecovery in @(0,2,3,5)) {
    $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
        '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
        '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
        '-Ptb_c1_r1_capture_frontend.CHECK_RASTER=1',
        "-Ptb_c1_r1_capture_frontend.RECOVERY_CASE=$guardRecovery");
        RequiredPassMarkers=@('C1_CAPTURE_PAUSABLE_FRAMES_PASS')}
}
foreach($flushHold in @(1,4)) {
    $tests += @{Top='tb_c1_isp_frame_flush';Flags=@("-Ptb_c1_isp_frame_flush.HOLD=$flushHold");
        RequiredPassMarkers=@('C1_ISP_FRAME_FLUSH_PASS')}
}
foreach($rasterShape in @(@(1,1),@(4,3),@(5,2))) {
    $tests += @{Top='tb_c1_raw_raster_guard';Flags=@(
        "-Ptb_c1_raw_raster_guard.W=$($rasterShape[0])",
        "-Ptb_c1_raw_raster_guard.H=$($rasterShape[1])");
        ExtraSources=@('c1_rv_hold_checker.sv');RequiredPassMarkers=@('C1_RAW_RASTER_GUARD_PASS')}
}
foreach($badEof in @(3,4)) {
    $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
        '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
        "-Ptb_c1_r1_capture_frontend.VERIFY_UNKNOWN=$badEof");
        ExpectedFailure='R1 ISP EOF does not match frame dimensions'}
}
foreach($pauseDepth in @(16,32)) {
    foreach($pauseHalf in @(3,7)) {
        $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
            '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
            '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
            '-Ptb_c1_r1_capture_frontend.RECOVERY_CASE=5',
            "-Ptb_c1_r1_capture_frontend.FLOW_FIFO_DEPTH=$pauseDepth",
            "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$pauseHalf");
            RequiredPassMarkers=@('C1_CAPTURE_EOF_WAIT_PASS','C1_CAPTURE_ACTIVE_ABORT_PASS','C1_CAPTURE_PAUSABLE_FRAMES_PASS')}
    }
}
foreach($overflowDepth in @(16,32)) {
    foreach($overflowHalf in @(3,7)) {
        $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
            '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
            '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
            '-Ptb_c1_r1_capture_frontend.RECOVERY_CASE=4',
            "-Ptb_c1_r1_capture_frontend.FLOW_FIFO_DEPTH=$overflowDepth",
            "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$overflowHalf");
            RequiredPassMarkers=@('C1_CAPTURE_OVERFLOW_EOF_PASS','C1_CAPTURE_PAUSABLE_FRAMES_PASS')}
    }
}
$tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
    '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1','-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
    '-Ptb_c1_r1_capture_frontend.RECOVERY_CASE=3',
    '-Ptb_c1_r1_capture_frontend.CAMERA_HALF=3');
    RequiredPassMarkers=@('C1_CAPTURE_ACTIVE_ABORT_PASS','C1_CAPTURE_PAUSABLE_FRAMES_PASS')}
foreach($activeDepth in @(16,32)) {
    foreach($activeHalf in @(3,7)) {
        $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
            '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
            '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
            '-Ptb_c1_r1_capture_frontend.RECOVERY_CASE=2',
            "-Ptb_c1_r1_capture_frontend.FLOW_FIFO_DEPTH=$activeDepth",
            "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$activeHalf");
            RequiredPassMarkers=@('C1_CAPTURE_ACTIVE_ABORT_PASS','C1_CAPTURE_PAUSABLE_FRAMES_PASS')}
    }
}
foreach($unknownCase in @(1,2)) {
    $unknownDiagnostic=if($unknownCase -eq 1) {'unknown CCM output at Gamma input'} else {'Gamma LUT read before initialization'}
    $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
        '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
        "-Ptb_c1_r1_capture_frontend.VERIFY_UNKNOWN=$unknownCase");
        ExpectedFailure=$unknownDiagnostic}
}
foreach($recoveryDepth in @(16,32)) {
    foreach($recoveryHalf in @(3,7)) {
        $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
            '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
            '-Ptb_c1_r1_capture_frontend.FLOW_RAMP=1',
            '-Ptb_c1_r1_capture_frontend.RECOVERY_CASE=1',
            "-Ptb_c1_r1_capture_frontend.FLOW_FIFO_DEPTH=$recoveryDepth",
            "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$recoveryHalf");
            RequiredPassMarkers=@('C1_CAPTURE_SOURCE_RECOVERY_PASS','C1_CAPTURE_PAUSABLE_FRAMES_PASS')}
    }
}
foreach($cameraDepth in @(16,32)) {
    foreach($cameraHalf in @(3,7)) {
      foreach($cameraRamp in @(0,1)) {
        $tests += @{Top='tb_c1_r1_capture_frontend';Flags=@(
            '-Ptb_c1_r1_capture_frontend.FLOW_CASE=1',
            "-Ptb_c1_r1_capture_frontend.FLOW_RAMP=$cameraRamp",
            "-Ptb_c1_r1_capture_frontend.FLOW_FIFO_DEPTH=$cameraDepth",
            "-Ptb_c1_r1_capture_frontend.CAMERA_HALF=$cameraHalf");
            RequiredPassMarkers=@('C1_CAPTURE_PAUSABLE_FRAMES_PASS')}
      }
    }
}
$tests += @{Top='tb_c1_r1_portable_soc_smoke';
    Flags=@('-Ptb_c1_r1_portable_soc_smoke.CAMERA_READY_VALID_SOURCE=1');
    RequiredPassMarkers=@('C1_SOC_CAMERA_SOURCE_MODE_PASS')}
foreach($cameraCase in 1..4) {
    $tests += @{Top='tb_c1_r1_capture_frontend';
        Flags=@("-Ptb_c1_r1_capture_frontend.BACKPRESSURE_CASE=$cameraCase");
        RequiredPassMarkers=@('C1_CAPTURE_SOURCE_CONTRACT_PASS')}
}
$tests += @{Top='tb_c1_r1_capture_frontend';Flags=@();RequiredPassMarkers=@('C1_CAPTURE_FRONTEND_PASS')}
$tests += @{Top='tb_c1_apb_r1_mux';Flags=@();RequiredPassMarkers=@('C1_APB_R1_MUX_PASS')}
$tests += @{Top='tb_c1_apb_isp_config';Flags=@();RequiredPassMarkers=@('C1_APB_ISP_CONFIG_PASS')}
foreach($apbSourceWidth in @(8,12,16)) {
    $tests += @{Top='tb_c1_sapphire_apb_master_adapter';
        Flags=@("-Ptb_c1_sapphire_apb_master_adapter.SOURCE_WIDTH=$apbSourceWidth");
        RequiredPassMarkers=@('C1_SAPPHIRE_APB_ADAPTER_PASS')}
}
foreach($holdFault in 0..3) {
    $holdTest=@{Top='tb_c1_rv_hold_checker';
        Flags=@("-Ptb_c1_rv_hold_checker.FAULT=$holdFault");
        ExtraSources=@('c1_rv_hold_checker.sv')}
    if($holdFault) {$holdTest.ExpectedFailure='C1_RV_HOLD_VIOLATION'}
    else {$holdTest.RequiredPassMarkers=@('C1_RV_HOLD_CHECKER_PASS')}
    $tests+=$holdTest
}
foreach($engineOptions in @(@(0,1),@(1,0),@(1,1))) {
    $tests+=@{Top='tb_c1_r1_portable_soc_smoke';Flags=@(
        "-Ptb_c1_r1_portable_soc_smoke.CACHE_DW_WEIGHT_TILES=$($engineOptions[0])",
        "-Ptb_c1_r1_portable_soc_smoke.MAC_PREFETCH_OVERLAP=$($engineOptions[1])");
        RequiredPassMarkers=@('C1_R1_PORTABLE_SOC_SMOKE_PASS',
            "C1_SOC_ENGINE_OPTIONS_PASS dw_cache=$($engineOptions[0]) mac_overlap=$($engineOptions[1])")}
}
foreach($parameterAbortFinal in 0..1) {
    $tests+=@{Top='tb_c1_r1_parameter_bank';Flags=@("-Ptb_c1_r1_parameter_bank.ABORT_FINAL=$parameterAbortFinal");
        RequiredPassMarkers=@('C1_R1_PARAMETER_BANK_PASS',"C1_PARAMETER_ABORT_BOUNDARY_PASS final=$parameterAbortFinal")}
}
$tests+=@{Top='tb_c1_r1_stage_config_bank';Flags=@();
    RequiredPassMarkers=@('C1_R1_STAGE_CONFIG_BANK_PASS',
        'C1_STAGE_ABORT_COMMIT_BOUNDARY_PASS prepared=0',
        'C1_STAGE_ABORT_COMMIT_BOUNDARY_PASS prepared=1',
        'C1_STAGE_ABORT_COMMIT_RESTART_PASS')}
foreach($ramDepth in @(1,3,8)) {
    $tests+=@{Top='tb_c1_ram_sdp_contract';Flags=@("-Ptb_c1_ram_sdp_contract.DEPTH=$ramDepth");
        RequiredPassMarkers=@('C1_RAM_SDP_CONTRACT_PASS')}
}
foreach($ramBad in @(@('DEPTH=0','DEPTH must be positive'),
    @('DATA_WIDTH=0','DATA_WIDTH must be positive'),
    @('ADDR_WIDTH=1','ADDR_WIDTH cannot address DEPTH'),
    @('ADDR_WIDTH=0','ADDR_WIDTH cannot address DEPTH'))) {
    $tests+=@{Top='tb_c1_ram_sdp_contract';Flags=@("-Ptb_c1_ram_sdp_contract.$($ramBad[0])");
        ExpectedFailure="c1_ram_sdp_read_first $($ramBad[1])"}
}
foreach($snapshotPeriods in @(@(3,7),@(11,3),@(3,19))) {
    $tests += @{Top='tb_c1_cdc_latest_snapshot';Flags=@(
        "-Ptb_c1_cdc_latest_snapshot.SH=$($snapshotPeriods[0])",
        "-Ptb_c1_cdc_latest_snapshot.DH=$($snapshotPeriods[1])");
        RequiredPassMarkers=@('C1_CDC_LATEST_SNAPSHOT_PASS','C1_CDC_SOURCE_STOP_PASS','C1_CDC_PENDING_RESET_PASS')}
}
foreach($snapshotPixel in @(3,7,19)) {
    $tests += @{Top='tb_c1_display_snapshot';
        Flags=@("-Ptb_c1_display_snapshot.PH=$snapshotPixel",'-Ptb_c1_display_snapshot.EVENT_CASE=1');
        RequiredPassMarkers=@('C1_DISPLAY_UNDERFLOW_BOUNDARY_PASS')}
    $tests += @{Top='tb_c1_display_snapshot';
        Flags=@("-Ptb_c1_display_snapshot.PH=$snapshotPixel");
        RequiredPassMarkers=@('C1_DISPLAY_SNAPSHOT_PASS')}
}
$tests += @{Top='tb_c1_event_cdc';Flags=@();RequiredPassMarkers=@('C1_EVENT_CDC_PASS')}
foreach($cdcPeriods in @(@(11,3),@(3,19))) {
    $tests += @{Top='tb_c1_event_cdc';Flags=@(
        "-Ptb_c1_event_cdc.SRC_HALF=$($cdcPeriods[0])",
        "-Ptb_c1_event_cdc.DST_HALF=$($cdcPeriods[1])");
        RequiredPassMarkers=@('C1_EVENT_CDC_PASS')}
}
foreach($pixelHalf in @(3,7,17)) {
    $tests += @{Top='tb_c1_display_flush_reset';
        Flags=@("-Ptb_c1_display_flush_reset.PIXEL_HALF=$pixelHalf");
        RequiredPassMarkers=@('C1_DISPLAY_FLUSH_RESET_PASS')}
}
foreach($sharedDrain in @(2,1,3,4)) {
    foreach($sharedTicket in 0..1) {
        $sharedWriteCase=if($sharedDrain -eq 4) {14} else {7}
        $sharedFlags=@("-Ptb_c1_r1_soc_control.WRITE_REGION_CASE=$sharedWriteCase",
            "-Ptb_c1_r1_soc_control.DRAIN_CASE=$sharedDrain")
        if($sharedTicket) {$sharedFlags+='-DC1_REGISTER_FATAL_TICKET'}
        $tests+=@{Top='tb_c1_r1_soc_control';Flags=$sharedFlags;
            RequiredPassMarkers=@('C1_SOC_SHARED_DRAIN_PASS')}
    }
}
foreach($staticTensor in 0..1) {
    $tests += @{Top='tb_c1_frame_write_region_guard';Flags=@(
        '-Ptb_c1_frame_write_region_guard.STATIC_CASES=1',
        "-Ptb_c1_frame_write_region_guard.TENSOR_CASES=$staticTensor");
        RequiredPassMarkers=@('C1_STATIC_REGION_GUARD_PASS')}
}
$tests += @{Top='tb_c1_frame_write_region_guard';Flags=@('-Ptb_c1_frame_write_region_guard.TENSOR_CASES=1');
    RequiredPassMarkers=@('C1_TENSOR_REGION_GUARD_PASS')}
$tests += @{Top='tb_c1_frames_arena_check';Flags=@();
    RequiredPassMarkers=@('C1_FRAMES_ARENA_PASS')}
foreach($admissionGeometry in 0..1) {
    foreach($admissionPreview in 0..1) {
        foreach($admissionCase in 1..5) {
            $tests+=@{Top='tb_c1_r1_job_frontend';Flags=@(
                "-Ptb_c1_r1_job_frontend.REGION_CASE=$admissionCase",
                "-Ptb_c1_r1_job_frontend.SEPARATE_INPUT_GEOMETRY=$admissionGeometry",
                "-Ptb_c1_r1_job_frontend.SNAPSHOT_PREVIEW=$admissionPreview");
                RequiredPassMarkers=@('C1_FRONTEND_REGION_PASS')}
        }
    }
}
foreach($writeRegionTicket in 0..1) {
    foreach($writeRegionCase in 1..40) {
        $writeRegionFlags=@("-Ptb_c1_r1_soc_control.WRITE_REGION_CASE=$writeRegionCase")
        if($writeRegionTicket) {$writeRegionFlags+='-DC1_REGISTER_FATAL_TICKET'}
        $writeRegionMarkers=@('C1_SOC_WRITE_REGION_PASS')
        if($writeRegionCase -eq 39) {
            $writeRegionMarkers+='C1_STATIC_CONFIG_SNAPSHOT_PASS live_bad_ignored=1 fields=12 held_cycles=5'
        }
        $tests+=@{Top='tb_c1_r1_soc_control';Flags=$writeRegionFlags;
            RequiredPassMarkers=$writeRegionMarkers}
    }
}
$tests += @{Top='tb_c1_frame_write_region_guard';Flags=@();
    RequiredPassMarkers=@('C1_FRAME_WRITE_REGION_GUARD_PASS')}
foreach($drainCase in 1..10){foreach($drainIdle in 0..1){
    $tests+=@{Top='tb_c1_r1_job_controller';Flags=@(
        "-Ptb_c1_r1_job_controller.DRAIN_CASE=$drainCase",
        "-Ptb_c1_r1_job_controller.DRAIN_IDLE_EDGE=$drainIdle");
        RequiredPassMarkers=@('C1_JOB_SUCCESS_DRAIN_PASS')}
}}
$tests += @{Top='tb_c1_r1_job_controller';Flags=@();
    RequiredPassMarkers=@('C1_R1_JOB_CONTROLLER_PASS')}
foreach($resetBoundary in 1..3) {
    $tests += @{Top='tb_c1_r1_job_controller';Flags=@(
        "-Ptb_c1_r1_job_controller.RESET_BOUNDARY=$resetBoundary");
        RequiredPassMarkers=@('C1_JOB_RESET_BOUNDARY_PASS')}
}
foreach($snapshotGeometry in 0..1) {
    foreach($snapshotPreview in 0..1) {
        foreach($snapshotCase in 1..9) {
            $tests+=@{Top='tb_c1_r1_job_frontend';Flags=@(
                "-Ptb_c1_r1_job_frontend.INPUT_SNAPSHOT_CASE=$snapshotCase",
                "-Ptb_c1_r1_job_frontend.SEPARATE_INPUT_GEOMETRY=$snapshotGeometry",
                "-Ptb_c1_r1_job_frontend.SNAPSHOT_PREVIEW=$snapshotPreview");
                RequiredPassMarkers=@('C1_INPUT_SNAPSHOT_PASS')}
        }
    }
}
foreach($regionTicket in 0..1) {
    foreach($regionCase in 1..7) {
        $regionFlags=@("-Ptb_c1_r1_soc_control.INPUT_REGION_CASE=$regionCase")
        if($regionTicket) {$regionFlags+='-DC1_REGISTER_FATAL_TICKET'}
        $tests+=@{Top='tb_c1_r1_soc_control';Flags=$regionFlags;
            RequiredPassMarkers=@('C1_INPUT_REGION_PASS')}
    }
}
foreach($aliasPreview in 0..1) {
    foreach($aliasTicket in 0..1) {
        foreach($publishMode in 1..6) {
            $publishFlags=@("-Ptb_c1_r1_soc_control.CAPTURE_GUARD_PUBLISH=$publishMode",
                "-Ptb_c1_r1_soc_control.PREVIEW_DISPLAY=$aliasPreview")
            if($aliasTicket) {$publishFlags+='-DC1_REGISTER_FATAL_TICKET'}
            $tests+=@{Top='tb_c1_r1_soc_control';Flags=$publishFlags;
                RequiredPassMarkers=@('C1_CAPTURE_GUARD_PUBLISH_PASS')}
        }
        $guardCancelFlags=@('-Ptb_c1_r1_soc_control.CAPTURE_GUARD_CANCEL=1',
            "-Ptb_c1_r1_soc_control.PREVIEW_DISPLAY=$aliasPreview")
        if($aliasTicket) {$guardCancelFlags+='-DC1_REGISTER_FATAL_TICKET'}
        $tests+=@{Top='tb_c1_r1_soc_control';Flags=$guardCancelFlags;
            RequiredPassMarkers=@('C1_CAPTURE_GUARD_CANCEL_PASS')}
        foreach($aliasMode in 1..3) {
            $aliasFlags=@("-Ptb_c1_r1_soc_control.CAPTURE_DISPLAY_ALIAS=$aliasMode",
                "-Ptb_c1_r1_soc_control.PREVIEW_DISPLAY=$aliasPreview")
            if($aliasTicket) { $aliasFlags+='-DC1_REGISTER_FATAL_TICKET' }
            $tests+=@{Top='tb_c1_r1_soc_control';Flags=$aliasFlags;
                RequiredPassMarkers=@('C1_CAPTURE_DISPLAY_ALIAS_GUARD_PASS')}
        }
    }
}
foreach ($swapPreview in 0..1) {
    foreach ($swapTicket in 0..1) {
        $swapFlags=@('-Ptb_c1_r1_soc_control.SWAP_ABORT_COLLISION=1',
            '-Ptb_c1_r1_soc_control.DIFFERENT_RESOLVED_GEOMETRY=1',
            "-Ptb_c1_r1_soc_control.PREVIEW_DISPLAY=$swapPreview")
        if($swapTicket) { $swapFlags += '-DC1_REGISTER_FATAL_TICKET' }
        $tests += @{ Top='tb_c1_r1_soc_control'; Flags=$swapFlags;
            RequiredPassMarkers=@('C1_SOC_SWAP_ABORT_METADATA_PASS','C1_R1_SOC_CONTROL_PASS') }
        $secondSwapFlags=@($swapFlags | Where-Object { $_ -notmatch 'SWAP_ABORT_COLLISION=' })
        $secondSwapFlags += '-Ptb_c1_r1_soc_control.SWAP_ABORT_COLLISION=2'
        $tests += @{ Top='tb_c1_r1_soc_control'; Flags=$secondSwapFlags;
            RequiredPassMarkers=@('C1_SOC_SECOND_SWAP_ABORT_PASS') }
        $tests += @{ Top='tb_c1_r1_soc_control'; Flags=($secondSwapFlags+@('-Ptb_c1_r1_soc_control.SWAP_ERROR_COLLISION=1'));
            RequiredPassMarkers=@('C1_SOC_COMMITTED_SWAP_ERROR_PASS') }
        $pendingSwapFlags=@($swapFlags | Where-Object { $_ -notmatch 'SWAP_ABORT_COLLISION=' })
        $pendingSwapFlags += '-Ptb_c1_r1_soc_control.SWAP_ABORT_COLLISION=3'
        $tests += @{ Top='tb_c1_r1_soc_control'; Flags=$pendingSwapFlags;
            RequiredPassMarkers=@('C1_SOC_PENDING_SWAP_ABORT_PASS') }
        $tests += @{ Top='tb_c1_r1_soc_control'; Flags=($pendingSwapFlags+@('-Ptb_c1_r1_soc_control.SWAP_ERROR_COLLISION=1'));
            RequiredPassMarkers=@('C1_SOC_PENDING_SWAP_ERROR_PASS') }
    }
}
$tests += @{ Top='tb_c1_frame_triple_layout_check'; Flags=@(); RequiredPassMarkers=@('C1_FRAME_TRIPLE_LAYOUT_PASS') }
$tests += @{ Top='tb_c1_frame_triple_layout_check'; Flags=@('-Ptb_c1_frame_triple_layout_check.FAST_ENVELOPE=0'); RequiredPassMarkers=@('C1_FRAME_TRIPLE_LAYOUT_PASS') }
foreach ($readGuardFast in 0..1) {
    $tests += @{ Top='tb_c1_frame_triple_layout_check'; Flags=@(
        '-Ptb_c1_frame_triple_layout_check.WRITE_VS_READERS=1',
        "-Ptb_c1_frame_triple_layout_check.FAST_ENVELOPE=$readGuardFast");
        RequiredPassMarkers=@('C1_FRAME_WRITE_READERS_PASS') }
}
foreach ($fastEnvelope in 0..1) {
    $tests += @{ Top='tb_c1_frame_triple_layout_check'; Flags=@('-Ptb_c1_frame_triple_layout_check.PERF_MODE=1',"-Ptb_c1_frame_triple_layout_check.FAST_ENVELOPE=$fastEnvelope"); RequiredPassMarkers=@('C1_FRAME_LAYOUT_PERF_PASS') }
}
foreach ($regionMode in 1..4) {
    $tests += @{ Top='tb_c1_frame_triple_layout_check'; Flags=@("-Ptb_c1_frame_triple_layout_check.REGION_MODE=$regionMode"); RequiredPassMarkers=@('C1_FRAME_LAYOUT_REGION_PASS') }
}
$tests += @{ Top='tb_c1_r1_portable_soc_smoke'; Flags=@(); RequiredPassMarkers=@('C1_R1_PORTABLE_SOC_SMOKE_PASS') }
foreach ($qosCase in @(@(24,16777216,16777215),@(24,16777215,16777215),
                       @(24,12345,12345),@(32,4294967295,4294967295))) {
    $tests += @{ Top='tb_c1_r1_portable_soc_smoke'; Flags=@(
        '-Ptb_c1_r1_portable_soc_smoke.QUEUED_WRITE=1',
        "-Ptb_c1_r1_portable_soc_smoke.QOS_WIDTH=$($qosCase[0])",
        "-Ptb_c1_r1_portable_soc_smoke.QOS_DEADLINE=$($qosCase[1])",
        "-Ptb_c1_r1_portable_soc_smoke.EXPECT_QOS_DEADLINE=$($qosCase[2])");
        RequiredPassMarkers=@('C1_SOC_QOS_DEADLINE_PASS','C1_SOC_QUEUED_WRITE_FAULT_PASS') }
}
foreach ($badPreviewAllocation in 0..4) {
    $tests += @{ Top='tb_c1_r1_portable_soc_smoke'; Flags=@('-Ptb_c1_r1_portable_soc_smoke.PREVIEW_CAPTURE=1','-Ptb_c1_r1_portable_soc_smoke.QUEUED_WRITE=1','-Ptb_c1_r1_portable_soc_smoke.FATAL_TICKET=1',"-Ptb_c1_r1_portable_soc_smoke.PREVIEW_BAD_ALLOC=$badPreviewAllocation"); RequiredPassMarkers=@('C1_SOC_PREVIEW_ALLOCATION_PASS','C1_SOC_QUEUED_WRITE_FAULT_PASS') }
}
foreach ($badPreviewDisplay in 0..1) {
    $tests += @{ Top='tb_c1_r1_portable_soc_smoke'; Flags=@('-Ptb_c1_r1_portable_soc_smoke.PREVIEW_DISPLAY=1',"-Ptb_c1_r1_portable_soc_smoke.PREVIEW_BAD_ALLOC=$badPreviewDisplay",'-Ptb_c1_r1_portable_soc_smoke.QUEUED_WRITE=1'); RequiredPassMarkers=@('C1_SOC_PREVIEW_DISPLAY_CONFIG_PASS','C1_SOC_QUEUED_WRITE_FAULT_PASS') }
}
$tests += @{ Top='tb_c1_r1_portable_soc_smoke'; Flags=@('-Ptb_c1_r1_portable_soc_smoke.QUEUED_WRITE=1'); RequiredPassMarkers=@('C1_SOC_QUEUED_WRITE_FAULT_PASS') }
$tests += @{ Top='tb_c1_r1_portable_soc_smoke'; Flags=@('-Ptb_c1_r1_portable_soc_smoke.QUEUED_WRITE=1','-Ptb_c1_r1_portable_soc_smoke.FATAL_TICKET=1'); RequiredPassMarkers=@('C1_SOC_QUEUED_WRITE_FAULT_PASS') }
$tests += @{ Top='tb_c1_two_frame_writers_w_ahead'; Flags=@('-Ptb_c1_two_frame_writers_w_ahead.SHARED_FABRIC=1'); RequiredPassMarkers=@('C1_SHARED_QUEUED_WRITE_PASS') }
$tests += @{ Top='tb_c1_two_frame_writers_w_ahead'; Flags=@('-Ptb_c1_two_frame_writers_w_ahead.SHARED_FABRIC=1','-Ptb_c1_two_frame_writers_w_ahead.BYPASS=1','-Ptb_c1_two_frame_writers_w_ahead.READ_SKID=1'); RequiredPassMarkers=@('C1_SHARED_QUEUED_WRITE_PASS') }
$tests += @{ Top='tb_c1_two_frame_writers_w_ahead'; Flags=@('-Ptb_c1_two_frame_writers_w_ahead.SHARED_FABRIC=1','-Ptb_c1_two_frame_writers_w_ahead.W_AHEAD=0'); RequiredPassMarkers=@('C1_SHARED_QUEUED_WRITE_PASS') }
$tests += @{ Top='tb_c1_axi_shared_qos_monitor'; Flags=@(); RequiredPassMarkers=@('C1_AXI_SHARED_QOS_MONITOR_PASS','C1_QOS_FRAME_WRAP_PASS','C1_QOS_FRAME_ABORT_PASS','C1_QOS_LIVE_CLEAR_PASS') }
$tests += @{ Top='tb_c1_two_frame_writers_w_ahead'; Flags=@(); RequiredPassMarkers=@('C1_TWO_WRITERS_W_AHEAD_PASS') }
$tests += @{ Top='tb_c1_two_frame_writers_w_ahead'; Flags=@('-Ptb_c1_two_frame_writers_w_ahead.BYPASS=1'); RequiredPassMarkers=@('C1_TWO_WRITERS_W_AHEAD_PASS') }
$tests += @{ Top='tb_c1_two_frame_writers_w_ahead'; Flags=@('-Ptb_c1_two_frame_writers_w_ahead.W_AHEAD=0'); RequiredPassMarkers=@('C1_TWO_WRITERS_W_AHEAD_PASS') }
$tests += @{ Top='tb_c1_axi_n_write_burst_arbiter_128'; Flags=@('-DC1_W_AHEAD_OF_B_TB'); RequiredPassMarkers=@('C1_WRITE_W_AHEAD_PASS') }
$tests += @{ Top='tb_c1_axi_n_write_burst_arbiter_128'; Flags=@('-DC1_W_AHEAD_OF_B_TB','-DC1_EMPTY_AW_BYPASS_TB'); RequiredPassMarkers=@('C1_WRITE_W_AHEAD_PASS') }
$tests += @{ Top='tb_c1_axi_n_write_burst_arbiter_128'; Flags=@('-DC1_W_AHEAD_OF_B_TB','-Ptb_c1_axi_n_write_burst_arbiter_128.FIFO_DEPTH=3'); RequiredPassMarkers=@('C1_WRITE_W_AHEAD_PASS') }
$tests += @{ Top='tb_c1_r1_preview_job_join'; Flags=@(); RequiredPassMarkers=@('C1_PREVIEW_JOB_JOIN_PASS','C1_PREVIEW_JOIN_COLLISION_PASS') }
$tests += @{ Top='tb_c1_r1_preview_job_join'; Flags=@('-Ptb_c1_r1_preview_job_join.USE_RUNTIME=1'); RequiredPassMarkers=@('C1_PREVIEW_RUNTIME_PASS','C1_PREVIEW_JOIN_COLLISION_PASS') }
$tests += @{ Top='tb_c1_r1_preview_dma_cancel'; Flags=@(); RequiredPassMarkers=@('C1_PREVIEW_DMA_CANCEL_PASS') }
$tests += @{ Top='tb_c1_r1_preview_dma'; Flags=@(); RequiredPassMarkers=@('C1_PREVIEW_DMA_PASS','C1_PREVIEW_COORDINATE_GUARD_PASS','C1_PREVIEW_MARKER_GUARD_PASS') }
$tests += @{ Top='tb_c1_r1_preview_dma'; Flags=@('-Ptb_c1_r1_preview_dma.REGION_GUARD=1'); RequiredPassMarkers=@('C1_PREVIEW_REGION_GUARD_PASS','C1_PREVIEW_COORDINATE_GUARD_PASS','C1_PREVIEW_MARKER_GUARD_PASS') }
$tests += @{ Top='tb_c1_r1_preview_fork'; Flags=@(); RequiredPassMarkers=@('C1_PREVIEW_FORK_PASS') }
$tests += @{ Top='tb_c1_r1_preview_multiline'; Flags=@(); RequiredPassMarkers=@('C1_PREVIEW_MULTILINE_PASS') }
$tests += @{ Top='tb_c1_preview_pair_ownership'; Flags=@(); RequiredPassMarkers=@('C1_PREVIEW_PAIR_OWNERSHIP_PASS','C1_PREVIEW_PAIR_CANCEL_PASS') }
$tests += @{ Top='tb_c1_frame_manager_ready_fifo'; Flags=@(); RequiredPassMarkers=@('C1_FRAME_MANAGER_READY_FIFO_PASS') }
$tests += @{ Top='tb_c1_display_geometry'; Flags=@('-Ptb_c1_display_geometry.STORE_WIDTH=2048');
    RequiredPassMarkers=@('C1_DISPLAY_LAYOUT_GEOMETRY_PASS','C1_DISPLAY_GEOMETRY_PASS') }
$tests += @{ Top='tb_c1_control'; Flags=@();
    RequiredPassMarkers=@('C1_CSR_GEOMETRY_SHADOW_PASS','C1_CONTROL_PASS') }
$tests += @{ Top='tb_c1_display_geometry'; Flags=@('-Ptb_c1_display_geometry.SEPARATE=1');
    RequiredPassMarkers=@('C1_DISPLAY_LAYOUT_GEOMETRY_PASS','C1_DISPLAY_GEOMETRY_PASS') }
foreach ($fifoMode in 0..1) {
    $tests += @{ Top='tb_c1_display_prefetch_separate';
        Flags=@("-Ptb_c1_display_prefetch_separate.FIFO=$fifoMode",
            '-Ptb_c1_display_prefetch_separate.RESET_PRIMED=1');
        RequiredPassMarkers=@('C1_DISPLAY_PRIMED_RESET_PASS') }
    $tests += @{ Top='tb_c1_display_prefetch_separate';
        Flags=@("-Ptb_c1_display_prefetch_separate.FIFO=$fifoMode");
        RequiredPassMarkers=@('C1_DISPLAY_PREFETCH_SEPARATE_PASS') }
}
foreach ($ticketFlag in @('', '-DC1_REGISTER_FATAL_TICKET')) {
    $geometryFlags = @('-Ptb_c1_r1_soc_control.DIFFERENT_RESOLVED_GEOMETRY=1')
    if ($ticketFlag) { $geometryFlags += $ticketFlag }
    $tests += @{ Top='tb_c1_r1_soc_control'; Flags=$geometryFlags;
        RequiredPassMarkers=@('C1_DISPLAY_PAIR_GEOMETRY_PASS','C1_SOC_INPUT_GEOMETRY_PASS','C1_R1_SOC_CONTROL_PASS') }
    $tests += @{ Top='tb_c1_r1_soc_control'; Flags=($geometryFlags+@('-Ptb_c1_r1_soc_control.PREVIEW_DISPLAY=1'));
        RequiredPassMarkers=@('C1_PREVIEW_DISPLAY_METADATA_PASS','C1_SOC_INPUT_GEOMETRY_PASS','C1_R1_SOC_CONTROL_PASS') }
}
foreach($geometryMode in 0..1) {
    $tests += @{ Top='tb_c1_r1_job_frontend'; Flags=@("-Ptb_c1_r1_job_frontend.SEPARATE_INPUT_GEOMETRY=$geometryMode");
                 RequiredPassMarkers=@('C1_R1_JOB_FRONTEND_PASS') }
}
$tests += @{ Top='tb_c1_frame_pair_geometry'; Flags=@(); RequiredPassMarkers=@('C1_FRAME_PAIR_GEOMETRY_PASS') }
$tests += @{ Top='tb_c1_frame_pair_resolver'; Flags=@(); RequiredPassMarkers=@('C1_FRAME_PAIR_RESOLVER_PASS') }
$tests += @{ Top='tb_c1_resize_phase_range'; Flags=@();
             RequiredPassMarkers=@('C1_RESIZE_PHASE_RANGE_PASS') }
foreach ($displayMode in 0..3) {
    $tests += @{ Top='tb_c1_split_compositor';
                 Flags=@("-Ptb_c1_split_compositor.MODE=$displayMode");
                 RequiredPassMarkers=@('C1_COMPOSITOR_RASTER_MODE_PASS','C1_SPLIT_COMPOSITOR_PASS') }
}
$tests += @{ Top='tb_c1_gamma_initialization'; Flags=@();
             RequiredPassMarkers=@('C1_GAMMA_INITIALIZATION_PASS') }
$tests += @{ Top='tb_c1_gamma_initialization';
             Flags=@('-Ptb_c1_gamma_initialization.PROGRAM_LUT=0');
             ExpectedFailure='R1 Gamma LUT read before initialization' }
foreach ($order in @(0,1)) {
  foreach ($endMarker in @(0,1)) {
    $tests += @{ Top='tb_c1_adapter_packing_memory';
        Flags=@("-Ptb_c1_adapter_packing_memory.W_FIRST=$order",
                "-Ptb_c1_adapter_packing_memory.USE_END=$endMarker");
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv','tb_c1_tensor_packing_memory.sv');
        RequiredPassMarkers=@('C1_ADAPTER_PACKING_MEMORY_PASS','C1_ADAPTER_PIPELINED_WRITES_PASS',
                             'C1_ADAPTER_PACKING_ERROR_PASS','C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS') }
    $packingMarkers=@('C1_PACKING_MEMORY_PASS','C1_PACKING_WSTRB_MATRIX_PASS masks=256 lane_orders=2 logical_writes=1024',
        'C1_PACKING_CONSERVATION_PASS')
    if($endMarker) {$packingMarkers+=@('C1_END_DISPATCH_PASS','C1_DIRECT_END_MATRIX_PASS')}
    $tests += @{ Top='tb_c1_tensor_packing_memory';
        Flags=@("-Ptb_c1_tensor_packing_memory.W_FIRST=$order",
                "-Ptb_c1_tensor_packing_memory.USE_END=$endMarker");
        RequiredPassMarkers=$packingMarkers }
  }
}
# The owner/epoch fence composition is checked with its detached xsim runner:
foreach ($delay in @(0,12,64)) {
  foreach ($packed in @(0,1)) {
    # The packed/end=1/delay=12/AW-first case is already in the matrix above.
    if ($packed -eq 1 -and $delay -eq 12) { continue }
    $tests += @{ Top='tb_c1_adapter_packing_memory';
        Flags=@("-Ptb_c1_adapter_packing_memory.PACKED_WRITES=$packed",
                "-Ptb_c1_adapter_packing_memory.USE_END=$packed",
                "-Ptb_c1_adapter_packing_memory.B_RESPONSE_DELAY=$delay");
        ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv','tb_c1_tensor_packing_memory.sv');
        RequiredPassMarkers=@('C1_ADAPTER_PACKING_MEMORY_PASS','C1_ADAPTER_WRITE_LATENCY_PASS',
                             'C1_ADAPTER_PACKING_ERROR_PASS','C1_ADAPTER_PIPELINED_WRITES_PASS') }
  }
}
# Icarus encountered a scheduling stall on that composition in this review.
foreach ($cfg in @(@(0,0,0),@(0,1,0),@(1,0,0),@(1,0,1),@(2,0,0))) {
    $tests += @{ Top='tb_c1_axi_protocol_fix'; Flags=@(
        "-Ptb_c1_axi_protocol_fix.KIND=$($cfg[0])",
        "-Ptb_c1_axi_protocol_fix.SKID=$($cfg[1])",
        "-Ptb_c1_axi_protocol_fix.BYPASS=$($cfg[2])") }
}
foreach ($top in @('tb_c1_axi7_serial_arbiter_128','tb_c1_axi2_serial_arbiter_128',
    'tb_c1_axi_n_write_burst_arbiter_128','tb_c1_axi_n_write_burst_arbiter_orphan_b',
    'tb_c1_r1_soc_control','tb_c1_display_geometry','tb_c1_display_line_store_cdc',
    'tb_c1_display_prefetch_pair','tb_c1_display_outer_flush','tb_c1_requant_bank8_boundaries',
    'tb_c1_async_stream_fifo','tb_c1_reset_sync','tb_c1_packed_probe_load')) {
    $tests += @{ Top=$top; Flags=@() }
}
$tests += @{ Top='tb_c1_axi7_serial_arbiter_128'; Flags=@('-DC1_READ_RESPONSE_SKID') }
foreach ($dotFlags in @('','-DC1_PIPELINED_DOT_TREE','-DC1_PIPELINED_DOT_TREE_FULL')) {
    $tests += @{ Top='tb_c1_dot8x8_requant_core'; Flags=@($dotFlags | Where-Object { $_ }) }
}
$tests += @{ Top='tb_c1_residual_s8_exhaustive'; Flags=@() }
$tests += @{ Top='tb_c1_r1_soc_control'; Flags=@('-DC1_REGISTER_FATAL_TICKET') }
$tests += @{ Top='tb_c1_display_geometry'; Flags=@('-Ptb_c1_display_geometry.STORE_WIDTH=8') }
$tests += @{ Top='tb_c1_display_prefetch_pair'; Flags=@('-Ptb_c1_display_prefetch_pair.FIFO=1') }
$tests += @{ Top='tb_c1_display_outer_flush'; Flags=@('-Ptb_c1_display_outer_flush.FIFO=1') }
foreach ($depth in @(2,3,5,64)) {
    foreach ($fifoTop in @('tb_c1_stream_fifo','tb_c1_stream_fifo_reset')) {
        $tests += @{ Top=$fifoTop; Flags=@("-P${fifoTop}.DEPTH=$depth") }
    }
}
foreach ($fifo in @(0,1)) {
    $tests += @{ Top='tb_c1_display_outer_flush'; Flags=@(
        "-Ptb_c1_display_outer_flush.FIFO=$fifo",
        '-Ptb_c1_display_outer_flush.WIDTH=128',
        '-Ptb_c1_display_outer_flush.BASE_SKEW=16') }
}
$tests += @{ Top='tb_c1_axi_n_write_burst_arbiter_128'; Flags=@('-DC1_EMPTY_AW_BYPASS_TB') }
$testImage = Join-Path ([IO.Path]::GetTempPath()) ('c1_review_' + [guid]::NewGuid().ToString('N') + '.vvp')
$vectorDir = Join-Path ([IO.Path]::GetTempPath()) ('c1_review_vectors_' + [guid]::NewGuid().ToString('N'))
$tests += @{ Top='tb_c1_r1_compute_ingress'; Flags=@(); WorkingDirectory=$vectorDir;
             ExtraSources=@('c1_rv_hold_checker.sv');
             RequiredPassMarkers=@('C1_R1_COMPUTE_INGRESS_PASS') }
foreach($ingressSeed in @(1,7,12345,305419896,2147483647)) {
    $tests += @{Top='tb_c1_r1_compute_ingress';
        Flags=@("-Ptb_c1_r1_compute_ingress.SEED=$ingressSeed");WorkingDirectory=$vectorDir;
        ExtraSources=@('c1_rv_hold_checker.sv');
        RequiredPassMarkers=@('C1_R1_COMPUTE_INGRESS_PASS')}
}
foreach($ingressSeed in @(729413027,1,7,12345,305419896,2147483647)) {
    $tests += @{Top='tb_c1_r1_compute_ingress';
        Flags=@("-Ptb_c1_r1_compute_ingress.SEED=$ingressSeed",
            '-Ptb_c1_r1_compute_ingress.REGISTER_ABORT_RESET=1');WorkingDirectory=$vectorDir;
        ExtraSources=@('c1_rv_hold_checker.sv');
        RequiredPassMarkers=@('C1_R1_COMPUTE_INGRESS_PASS')}
}
foreach ($resizeFlag in @('', '-DC1_REGISTER_ABORT_RESET')) {
    $tests += @{ Top='tb_c1_r1_resize_pipeline'; Flags=@($resizeFlag | Where-Object { $_ });
                 WorkingDirectory=$vectorDir; RequiredPassMarkers=@('C1_R1_RESIZE_PIPELINE_PASS','C1_RESIZE_SOURCE_TAIL_DRAIN_PASS','C1_RESIZE_TAIL_RECOVERY_PASS') }
}
$tests += @{ Top='tb_c1_residual_add_c8'; Flags=@(); WorkingDirectory=$vectorDir }
$tests += @{ Top='tb_c1_s8_window3x3_same_c8'; Flags=@(); WorkingDirectory=$vectorDir }
foreach ($cacheTop in @('tb_c1_window_line_cache_c8','tb_c1_window_line_cache_c8_faults',
                       'tb_c1_window_line_cache_c8_maxrow')) {
    $tests += @{ Top=$cacheTop; Flags=@() }
    $bankedCacheTest=@{ Top=$cacheTop; Flags=@("-P$cacheTop.BANKED=1") }
    if($cacheTop -eq 'tb_c1_window_line_cache_c8') {
        $bankedCacheTest.RequiredPassMarkers=@('C1_CACHE_STORAGE_EQUIVALENCE_PASS')
    }
    $tests += $bankedCacheTest
}
$passed = 0
$tests += @{ Top='tb_c1_r1_microstyle_tensor_adapter'; Flags=@() }
foreach($reuseShape in @(@(4,4),@(12,8),@(20,12),@(32,16))) {
    foreach($reuseEnable in @(0,1)) {
        $geometryMarkers=@('C1_ADAPTER_GEOMETRY_PASS','C1_ADAPTER_READ_BUDGET_PASS')
        if($reuseEnable){$geometryMarkers+='C1_ADAPTER_REUSE_RESTART_PASS'}
        $tests+=@{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=@(
            "-Ptb_c1_r1_microstyle_tensor_adapter.FRAME_W=$($reuseShape[0])",
            "-Ptb_c1_r1_microstyle_tensor_adapter.FRAME_H=$($reuseShape[1])",
            "-Ptb_c1_r1_microstyle_tensor_adapter.HORIZONTAL_REUSE=$reuseEnable",
            '-Ptb_c1_r1_microstyle_tensor_adapter.PREFETCH_TAP_ADDRESS=1',
            '-DC1_PIPELINED_TENSOR_ADDRESS','-DC1_PIPELINED_TENSOR_PIXEL_INDEX');
            RequiredPassMarkers=$geometryMarkers}
    }
}
$tests += @{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=@(
    '-Ptb_c1_r1_microstyle_tensor_adapter.HORIZONTAL_REUSE=1');
    RequiredPassMarkers=@('C1_ADAPTER_HORIZONTAL_REUSE_PASS enabled=1',
        'C1_ADAPTER_READ_BUDGET_PASS','C1_ADAPTER_REUSE_RESTART_PASS')}
foreach($reusePixel in @(0,1)) {
    foreach($reusePrefetch in @(0,1)) {
        $reuseFlags=@('-Ptb_c1_r1_microstyle_tensor_adapter.HORIZONTAL_REUSE=1',
            '-DC1_PIPELINED_TENSOR_ADDRESS',
            "-Ptb_c1_r1_microstyle_tensor_adapter.PREFETCH_TAP_ADDRESS=$reusePrefetch")
        if($reusePixel){$reuseFlags+='-DC1_PIPELINED_TENSOR_PIXEL_INDEX'}
        $tests+=@{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=$reuseFlags;
            RequiredPassMarkers=@('C1_ADAPTER_HORIZONTAL_REUSE_PASS enabled=1',
                'C1_ADAPTER_READ_BUDGET_PASS','C1_ADAPTER_REUSE_RESTART_PASS')}
    }
}
$tests += @{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=@(
    '-Ptb_c1_r1_microstyle_tensor_adapter.HORIZONTAL_REUSE=1',
    '-Ptb_c1_r1_microstyle_tensor_adapter.PREFETCH_TAP_ADDRESS=1',
    '-Ptb_c1_r1_microstyle_tensor_adapter.PIPELINED_WRITES=1',
    '-DC1_PIPELINED_TENSOR_ADDRESS','-DC1_PIPELINED_TENSOR_PIXEL_INDEX');
    RequiredPassMarkers=@('C1_ADAPTER_HORIZONTAL_REUSE_PASS enabled=1',
        'C1_ADAPTER_READ_BUDGET_PASS','C1_ADAPTER_REUSE_RESTART_PASS',
        'C1_ADAPTER_PIPELINED_WRITES_PASS')}
$tests += @{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=@(
    '-Ptb_c1_r1_microstyle_tensor_adapter.PREFETCH_TAP_ADDRESS=1');
    RequiredPassMarkers=@('C1_ADAPTER_TAP_ADDRESS_PASS')}
$tests += @{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=@(
    '-Ptb_c1_r1_microstyle_tensor_adapter.PREFETCH_TAP_ADDRESS=1',
    '-Ptb_c1_r1_microstyle_tensor_adapter.PIPELINED_WRITES=1',
    '-Ptb_c1_r1_microstyle_tensor_adapter.FIXED_READ_DELAY=8',
    '-DC1_PIPELINED_TENSOR_ADDRESS','-DC1_PIPELINED_TENSOR_PIXEL_INDEX');
    RequiredPassMarkers=@('C1_ADAPTER_TAP_ADDRESS_PASS',
        'C1_ADAPTER_TAP_DRAIN_PASS phase=2 fault=0',
        'C1_ADAPTER_TAP_DRAIN_PASS phase=4 fault=1',
        'C1_ADAPTER_TAP_DRAIN_PASS phase=4 fault=0 restart_ready=1 held_request=0',
        'C1_ADAPTER_TAP_DRAIN_PASS phase=4 fault=1 restart_ready=1 held_request=0',
        'C1_ADAPTER_PIPELINED_WRITES_PASS')}
foreach($tapPixel in @(0,1)) {
    foreach($tapPrefetch in @(0,1)) {
        foreach($tapDelay in @(-1,0,8)) {
            $tapFlags = @('-DC1_PIPELINED_TENSOR_ADDRESS',
                "-Ptb_c1_r1_microstyle_tensor_adapter.PREFETCH_TAP_ADDRESS=$tapPrefetch",
                "-Ptb_c1_r1_microstyle_tensor_adapter.FIXED_READ_DELAY=$tapDelay")
            if ($tapPixel) { $tapFlags += '-DC1_PIPELINED_TENSOR_PIXEL_INDEX' }
            $tapMarkers = @('C1_ADAPTER_TAP_ADDRESS_PASS')
            if ($tapPrefetch) {
                $tapMarkers += @('C1_ADAPTER_TAP_DRAIN_PASS phase=1 fault=0',
                    'C1_ADAPTER_TAP_DRAIN_PASS phase=3 fault=0',
                    'C1_ADAPTER_TAP_DRAIN_PASS phase=4 fault=0',
                    'C1_ADAPTER_TAP_DRAIN_PASS phase=4 fault=1',
                    'C1_ADAPTER_TAP_DRAIN_PASS phase=4 fault=0 restart_ready=1 held_request=0',
                    'C1_ADAPTER_TAP_DRAIN_PASS phase=4 fault=1 restart_ready=1 held_request=0')
                if ($tapPixel) { $tapMarkers += 'C1_ADAPTER_TAP_DRAIN_PASS phase=2 fault=0' }
            }
            $tests += @{Top='tb_c1_r1_microstyle_tensor_adapter';Flags=$tapFlags;
                RequiredPassMarkers=$tapMarkers}
        }
    }
}
$tests += @{ Top='tb_c1_r1_microstyle_tensor_adapter';
    Flags=@('-Ptb_c1_r1_microstyle_tensor_adapter.PIPELINED_WRITES=1');
    RequiredPassMarkers=@('C1_ADAPTER_PIPELINED_WRITES_PASS') }
foreach ($depth in @(1,2)) {
    $tests += @{ Top='tb_c1_r1_microstyle_tensor_adapter';
        Flags=@('-Ptb_c1_r1_microstyle_tensor_adapter.PIPELINED_WRITES=1',
                "-Ptb_c1_r1_microstyle_tensor_adapter.RESPONSE_DEPTH=$depth");
        RequiredPassMarkers=@('C1_ADAPTER_PIPELINED_WRITES_PASS') }
}
$tests += @{ Top='tb_c1_r1_microstyle_tensor_adapter';
    Flags=@('-Ptb_c1_r1_microstyle_tensor_adapter.PIPELINED_WRITES=1',
            '-DC1_PIPELINED_TENSOR_ADDRESS','-DC1_PIPELINED_TENSOR_PIXEL_INDEX');
    RequiredPassMarkers=@('C1_ADAPTER_PIPELINED_WRITES_PASS',
                         'C1_ADAPTER_WRITE_DRAIN_PASS fault=0',
                         'C1_ADAPTER_WRITE_DRAIN_PASS fault=1') }
$tests += @{ Top='tb_c1_axi_xrgb_frame_writer'; Flags=@() }
$tests += @{ Top='tb_c1_frame_writer_aw_w_independent'; Flags=@() }
$tests += @{ Top='tb_c1_tensor_mem_axi128_write_burst_client'; Flags=@() }
foreach($endDependentAw in @(0,1)) {
    $tests += @{ Top='tb_c1_tensor_mem_axi128_write_burst_client';
        Flags=@('-Ptb_c1_tensor_mem_axi128_write_burst_client.USE_END=1',
            "-Ptb_c1_tensor_mem_axi128_write_burst_client.DEPENDENT_AW=$endDependentAw");
        RequiredPassMarkers=@('C1_TENSOR_MEM_AXI128_WRITE_BURST_CLIENT_PASS',
            "C1_WRITE_BURST_END_MODE end_marker=1 dependent_aw=$endDependentAw") }
}
foreach($writeEarlyEnd in @(0,1)) {
    $tests += @{ Top='tb_c1_tensor_write_early_w';
        Flags=@("-Ptb_c1_tensor_write_early_w.USE_END=$writeEarlyEnd");
        RequiredPassMarkers=@('C1_TENSOR_WRITE_EARLY_W_PASS',"C1_TENSOR_WRITE_EARLY_W_MODE end_marker=$writeEarlyEnd") }
}
$tests += @{ Top='tb_c1_axi128_write_mlp'; Flags=@() }
$tests += @{ Top='tb_c1_axi128_write_mlp'; Flags=@('-Ptb_c1_axi128_write_mlp.DEPENDENT_FIRST_AW=1') }
$tests += @{ Top='tb_c1_axi128_write_mlp'; Flags=@('-DC1_WRITE_RSP_POP_REFILL_TB') }
$tests += @{ Top='tb_c1_axi128_write_mlp_aw_before_payload'; Flags=@() }
$tests += @{ Top='tb_c1_mlp_early_w'; Flags=@() }
$tests += @{ Top='tb_c1_axi_write_skid_bridge'; Flags=@() }
foreach ($faultMode in @(1,2)) {
    foreach ($beatFlag in @('','-DC1_BEAT_FIFO_FABRIC_TB')) {
        $tests += @{ Top='tb_c1_tensor_mem_axi128_read_fabric_2c';
            Flags=@($beatFlag | Where-Object { $_ }) + @("-Ptb_c1_tensor_mem_axi128_read_fabric_2c.FAULT_MODE=$faultMode",
                '-Ptb_c1_tensor_mem_axi128_read_fabric_2c.STRESS_BACKPRESSURE=1');
            RequiredPassMarkers=@('C1_READ_FAULT_BACKPRESSURE_PASS','C1_READ_FABRIC_FAULT_PASS','C1_TENSOR_MEM_AXI128_READ_FABRIC_PASS') }
        $tests += @{ Top='tb_c1_tensor_mem_axi128_read_fabric_2c';
            Flags=@($beatFlag | Where-Object { $_ }) + @("-Ptb_c1_tensor_mem_axi128_read_fabric_2c.FAULT_MODE=$faultMode");
            RequiredPassMarkers=@('C1_READ_FABRIC_FAULT_PASS','C1_TENSOR_MEM_AXI128_READ_FABRIC_PASS') }
    }
}
foreach ($readFabricFlag in @('','-DC1_BEAT_FIFO_FABRIC_TB',
    '-DC1_REQ_POP_REFILL_FABRIC_TB','-DC1_EMPTY_AR_BYPASS_FABRIC_TB')) {
    $tests += @{ Top='tb_c1_tensor_mem_axi128_read_fabric_2c';
        Flags=@($readFabricFlag | Where-Object { $_ }) }
}
foreach ($readBypass in @('','-DC1_EMPTY_AR_BYPASS_TB')) {
    foreach ($readResp in 0..3) {
        $tests += @{ Top='tb_c1_axi_n_read_burst_arbiter_128';
            Flags=@($readBypass | Where-Object { $_ }) + @("-Ptb_c1_axi_n_read_burst_arbiter_128.TEST_RRESP=$readResp") }
    }
}
$tests += @{ Top='tb_c1_mlp_early_w'; Flags=@('-Ptb_c1_mlp_early_w.EARLY_AW=1') }
foreach ($adapterFlags in @('','-DC1_ADAPTER_ISSUE_AW_BEFORE_PAYLOAD_TB','-DC1_ADAPTER_RSP_POP_REFILL_TB')) {
    $tests += @{ Top='tb_c1_tensor_mem_axi128_write_mlp_adapter';
                 Flags=@($adapterFlags | Where-Object { $_ }) }
}
foreach ($fabricFlags in @('','-DC1_FABRIC_RSP_POP_REFILL_TB')) {
    $tests += @{ Top='tb_c1_tensor_mem_axi128_write_mlp_fabric_2c';
                 Flags=@($fabricFlags | Where-Object { $_ }) }
}
foreach ($refillFlags in @('','-DC1_WRITE_REQ_POP_REFILL_TB')) {
    $tests += @{ Top='tb_c1_tensor_mem_axi128_write_burst_client_req_pop_refill';
                 Flags=@($refillFlags | Where-Object { $_ }) }
    $tests += @{ Top='tb_c1_tensor_mem_axi128_write_burst_client_req_pop_refill';
                 Flags=@($refillFlags | Where-Object { $_ })+
                     @('-Ptb_c1_tensor_mem_axi128_write_burst_client_req_pop_refill.USE_END=1');
                 RequiredPassMarkers=@('C1_TENSOR_MEM_AXI128_WRITE_BURST_CLIENT_REQ_POP_REFILL_PASS') }
}
foreach ($laneFlags in @('','-DC1_WRITE_PARALLEL_LANES4_TB')) {
    $tests += @{ Top='tb_c1_tensor_mem_axi128_write_parallel_fabric';
                 Flags=@($laneFlags | Where-Object { $_ }) }
}
$tests += @{ Top='tb_c1_tensor_mem_axi128_write_burst_client';
             Flags=@('-Ptb_c1_tensor_mem_axi128_write_burst_client.DEPENDENT_AW=1') }
$tests += @{ Top='tb_c1_r1_adapter_window_cache_axi_dynamic'; Flags=@();
             ExtraSources=@('tb_c1_r1_microstyle_tensor_adapter.sv');
             RequiredPassMarkers=@('C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS',
                 'C1_ADAPTER_AXI_MEMORY_COMMIT_PASS','C1_R1_ADAPTER_WINDOW_CACHE_AXI_DYNAMIC_PASS') }
try {
    if ($TestTop) {
        $tests = @($tests | Where-Object Top -eq $TestTop)
        if ($tests.Count -eq 0) { throw "Unknown test top: $TestTop" }
    }
    if ($TestFlagsMatch) {
        if(-not $TestTop){throw 'TestFlagsMatch requires an explicit TestTop'}
        $tests = @($tests | Where-Object {($_.Flags -join ' ') -match $TestFlagsMatch})
        if($tests.Count -eq 0){throw "No configurations match TestFlagsMatch: $TestFlagsMatch"}
    }
    & $Python -B (Join-Path $caseRoot 'golden\generate_residual_add_c8_vectors.py') --output-dir $vectorDir
    if ($LASTEXITCODE -ne 0) { throw 'Residual golden vector generation failed' }
    & $Python -B (Join-Path $caseRoot 'golden\generate_window3x3_same_c8_vectors.py') --output-dir $vectorDir
    if ($LASTEXITCODE -ne 0) { throw 'Window golden vector generation failed' }
    & $Python -B (Join-Path $caseRoot 'golden\generate_r1_resize_line_sampler_vectors.py') --output-dir $vectorDir
    if ($LASTEXITCODE -ne 0) { throw 'Resize golden vector generation failed' }
    foreach ($test in $tests) {
        $top = $test.Top
        $argsList = @('-g2012','-s',$top,'-o',$testImage) + $test.Flags + $sources +
            @(Join-Path $caseRoot "sim\$top.sv")
        foreach ($extraSource in $test.ExtraSources) {
            $argsList += Join-Path $caseRoot "sim\$extraSource"
        }
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $diag = @(& $compiler @argsList 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
        $ErrorActionPreference = $saved
        if ($code -ne 0) {
            $diag | Where-Object { $_ -match '(?i)error:|syntax error|Unable to bind' } | Select-Object -First 8
            $diag | Select-Object -Last 12
            throw (Format-C1RegressionFailure 'Compile failed' $top $test.Flags $diag)
        }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $simulator
        if ($test.WorkingDirectory) { $psi.WorkingDirectory = $test.WorkingDirectory }
        $psi.Arguments = '"' + $testImage + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $psi
        try {
            [void]$proc.Start()
            $stdout = $proc.StandardOutput.ReadToEndAsync()
            $stderr = $proc.StandardError.ReadToEndAsync()
            $testTimeoutSeconds=$SimulationTimeoutSeconds
            if(-not $PSBoundParameters.ContainsKey('SimulationTimeoutSeconds') -and $test.TimeoutSeconds) {
                $testTimeoutSeconds=[Math]::Min(60,[int]$test.TimeoutSeconds)
            }
            if (-not $proc.WaitForExit($testTimeoutSeconds*1000)) {
                $proc.Kill(); $proc.WaitForExit()
                $timeoutLines=($stdout.Result + $stderr.Result) -split '\r?\n'
                throw (Format-C1RegressionFailure "Simulation exceeded $testTimeoutSeconds seconds (use detached xsim for scheduling compatibility)" $top $test.Flags $timeoutLines)
            }
            $result = ($stdout.Result + $stderr.Result) -split '\r?\n'
            $simCode = $proc.ExitCode
        } finally { $proc.Dispose() }
        if ($test.ExpectedFailure) {
            if ($simCode -eq 0 -or -not ($result -match [regex]::Escape($test.ExpectedFailure))) {
                throw (Format-C1RegressionFailure "Expected diagnostic not observed ($($test.ExpectedFailure))" $top $test.Flags $result)
            }
            Write-Output "C1_EXPECTED_DIAGNOSTIC_PASS top=$top diagnostic=$($test.ExpectedFailure)"
            $passed++
            continue
        }
        if ($simCode -ne 0 -or -not ($result -match '_PASS')) {
            $result | Select-Object -Last 15
            throw (Format-C1RegressionFailure "Regression failed exit=$simCode" $top $test.Flags $result)
        }
        foreach ($requiredMarker in $test.RequiredPassMarkers) {
            if (-not ($result -match [regex]::Escape($requiredMarker))) {
                throw (Format-C1RegressionFailure "Missing required result $requiredMarker" $top $test.Flags $result)
            }
        }
        $result | Where-Object { $_ -match '_PASS|COUNTS' }
        $passed++
    }
    Write-Output "C1_REVIEW_FIXES_REGRESSION_PASS configurations=$passed"
} finally {
    # Only the one uniquely named compiler image is generated. No waves or
    # recursive simulator project directories are created by these tests.
    if (Test-Path -LiteralPath $testImage) { Remove-Item -LiteralPath $testImage }
    # Delete only the known outputs in this newly generated directory.
    # No recursive operation or user-owned vector directory is involved.
    if (Test-Path -LiteralPath $vectorDir) {
        foreach ($name in @('residual_add_c8_frames.mem','residual_add_c8_main.mem',
            'residual_add_c8_skip.mem','residual_add_c8_expected.mem','residual_add_c8_vectors.json',
            'window3x3_same_c8_frames.mem','window3x3_same_c8_input.mem',
            'window3x3_same_c8_expected.mem','window3x3_same_c8_vectors.json',
            'r1_resize_line_sampler_source.txt','r1_resize_line_sampler_configs.txt',
            'r1_resize_line_sampler_expected.txt','r1_resize_line_sampler_manifest.json')) {
            $generatedFile = Join-Path $vectorDir $name
            if (Test-Path -LiteralPath $generatedFile) { Remove-Item -LiteralPath $generatedFile }
        }
        if (@(Get-ChildItem -LiteralPath $vectorDir -Force).Count -eq 0) {
            Remove-Item -LiteralPath $vectorDir
        }
    }
}
