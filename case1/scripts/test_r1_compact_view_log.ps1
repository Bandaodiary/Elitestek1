[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$c1Runner=Join-Path $PSScriptRoot 'run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1'
$c1Tokens=$null; $c1Errors=$null
$c1Ast=[System.Management.Automation.Language.Parser]::ParseFile($c1Runner,[ref]$c1Tokens,[ref]$c1Errors)
if($c1Errors.Count){throw 'Runner did not parse'}
$c1Functions=@($c1Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-CompactLog'},$true))
if($c1Functions.Count -ne 1){throw 'Expected one production compact-log function'}
# Load only the function, never execute the runner's WMI dispatch/worker body.
. ([scriptblock]::Create($c1Functions[0].Extent.Text))
$c1Logs=(Resolve-Path (Join-Path $PSScriptRoot '..\logs')).Path
$c1Probe=[IO.Path]::GetFullPath((Join-Path $c1Logs ('view_compact_probe_'+[guid]::NewGuid().ToString('N'))))
if(-not $c1Probe.StartsWith($c1Logs+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
    throw 'Probe directory escaped logs'
}
$c1Source=Join-Path $c1Probe 'raw.log'
$c1Output=Join-Path $c1Probe 'compact.log'
New-Item -ItemType Directory -Path $c1Probe | Out-Null
try {
    $c1Evidence=@(
        'C1_NUM_VIEW_ELISION enabled=1',
        'C1_PERF_START job=1 cycle=1',
        'C1_VIEW_CONTEXT job=1 generation=2',
        'C1_VIEW_COMMIT job=1 stage=14 generation=2 input_bank=0 output_bank=3 width=2 height=2 groups=3 debt=0',
        'C1_VIEW_COMMIT job=1 stage=14 generation=2 input_bank=0 output_bank=3 width=2 height=2 groups=3 debt=0',
        'C1_VIEW_COMMIT malformed_do_not_hide',
        'C1_VIEW_STOP job=1 generation=2 views=1',
        'C1_NUM_FINAL_FUSION enabled=1',
        'C1_FINAL_FUSION_BEGIN job=1 generation=2 width=2 height=2',
        'C1_FINAL_FUSION_COMMIT job=1 generation=2 stage=21 inputs=4 outputs=3 held_eof=1',
        'C1_FINAL_FUSION_COMMIT job=1 generation=2 stage=21 inputs=4 outputs=3 held_eof=1',
        'C1_FINAL_FUSION_COMMIT malformed_do_not_hide',
        'C1_FINAL_FUSION_EOF job=1 generation=2 inputs=4 outputs=4',
        'C1_PERF_FINAL_COMPUTE job=1 generation=2 starts=4 outputs=4 inputs_ahead=2 starts_ahead=1',
        'C1_PERF_FINAL_FUSION job=1 generation=2 inputs=4 outputs=4 commits=1 eofs=1',
        'C1_FINAL_FUSION_STOP job=1 generation=2 inputs=4 outputs=3 commits=1 eofs=0',
        'C1_NUM_DW_FRAME_STREAM enabled=1',
        'C1_PERF_DW_FRAME job=1 cold_starts=23 warm_starts=5 continues=82 input_eofs=28 output_eofs=28 held_continues=0',
        'C1_PERF_DW_FRAME job=1 cold_starts=23 warm_starts=5 continues=82 input_eofs=28 output_eofs=28 held_continues=0',
        'C1_PERF_DW_FRAME malformed_do_not_hide',
        'C1_NUM_STAGE_FSM version=1 includes_setup=1 stage_source=adapter',
        'C1_PERF_STAGE_FSM job=1 stage=18 side=engine state=14 cycles=7',
        'C1_PERF_STAGE_FSM job=1 stage=18 side=engine state=14 cycles=7',
        'C1_PERF_STAGE_FSM malformed_do_not_hide',
        'C1_NUM_COLUMN_STAGE version=1 includes_setup=1 stage_source=adapter',
        'C1_PERF_COLUMN_STAGE job=1 stage=19 idle=3 lookup=1 req=2 data=4 read=0 capture=2 response=0 refill_commands=2 refill_words=2',
        'C1_PERF_COLUMN_STAGE job=1 stage=19 idle=3 lookup=1 req=2 data=4 read=0 capture=2 response=0 refill_commands=2 refill_words=2',
        'C1_PERF_COLUMN_STAGE malformed_do_not_hide',
        'C1_NUM_COLUMN_REFILL version=2 window=32 req_depth=32 rsp_depth=128 beat_mode=0 handoff=1',
        'C1_PERF_COLUMN_REFILL job=1 requests=32 responses=32 handoffs=20 adjacent=20 req_peak=1 rsp_peak=2 meta_peak=32 credit_peak=32 ar=1 beats=16',
        'C1_PERF_COLUMN_REFILL job=1 requests=32 responses=32 handoffs=20 adjacent=20 req_peak=1 rsp_peak=2 meta_peak=32 credit_peak=32 ar=1 beats=16',
        'C1_PERF_COLUMN_REFILL malformed_do_not_hide',
        'C1_PERF_COLUMN_BURSTS job=1 beats=16 count=1',
        'C1_PERF_COLUMN_BURSTS job=1 beats=16 count=1',
        'C1_PERF_COLUMN_BURSTS malformed_do_not_hide',
        'C1_NUM_SCALAR_CACHE_ENTRIES entries=2',
        'C1_NUM_SCALAR_ASSOC version=1 enabled=1 entries=2 precise=1',
        'C1_PERF_SCALAR_ASSOC job=1 reads=72 responses=72 hits=36 ar=36 beats=36',
        'C1_PERF_SCALAR_ASSOC job=1 reads=72 responses=72 hits=36 ar=36 beats=36',
        'C1_PERF_SCALAR_ASSOC malformed_do_not_hide',
        'C1_PERF_SCALAR_ASSOC_STAGE job=1 stage=5 reads=24 hits=12 ar=12 beats=12',
        'C1_PERF_SCALAR_ASSOC_STAGE job=1 stage=5 reads=24 hits=12 ar=12 beats=12',
        'C1_PERF_SCALAR_ASSOC_STAGE malformed_do_not_hide',
        'C1_NUM_SCALAR_ASSOC_ABORT stage=5 entries=2 surviving_valid=1 hits=2 reads=5 pending=1',
        'C1_PERF_ABORT job=1 cycle=9 elapsed=8',
        'C1_TEST_COMPACT_PASS')
    # Put every witness outside the retained 80-line tail. Duplicates and
    # malformed records must survive so the independent checker can reject.
    $c1Noise=@(1..120 | ForEach-Object { "diagnostic padding $_" })
    [IO.File]::WriteAllLines($c1Source,[string[]]($c1Evidence+$c1Noise),[Text.Encoding]::UTF8)
    Save-CompactLog $c1Source $c1Output 'C1_TEST_COMPACT_PASS'
    $c1Lines=@(Get-Content -LiteralPath $c1Output)
    $c1Actual=@($c1Lines | Where-Object { $_.StartsWith('C1_') })
    if($c1Actual.Count -ne $c1Evidence.Count){throw 'Lost or invented compact witness'}
    for($c1Index=0;$c1Index -lt $c1Evidence.Count;$c1Index++){
        if($c1Actual[$c1Index] -cne $c1Evidence[$c1Index]){throw 'Compact witness order/content changed'}
    }
    if($c1Lines.Count -ne $c1Evidence.Count+80){throw 'Unbounded/incorrect compact tail'}
    Write-Output "C1_COMPACT_VIEW_LOG_PASS outside_tail=$($c1Evidence.Count) duplicate_preserved=1 malformed_preserved=1 tail=80"
} finally {
    foreach($c1File in @($c1Source,$c1Output)){
        $c1Resolved=[IO.Path]::GetFullPath($c1File)
        if([IO.Path]::GetDirectoryName($c1Resolved) -ne $c1Probe){throw 'Cleanup target escaped probe'}
        if(Test-Path -LiteralPath $c1Resolved){Remove-Item -LiteralPath $c1Resolved -Force}
    }
    # Non-recursive removal: unexpected files are not silently deleted.
    if(Test-Path -LiteralPath $c1Probe){Remove-Item -LiteralPath $c1Probe}
}
