$ErrorActionPreference='Stop'
# Exercise the actual runner function without starting tools or writing files.
$runner=Join-Path $PSScriptRoot 'run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1'
$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Runner parse failed'}
$functionAst=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-CompactLog'},$true)
if(!$functionAst){throw 'Missing Save-CompactLog'}
. ([scriptblock]::Create($functionAst.Extent.Text))

# File command shims keep the test entirely in memory. Matching and tail
# selection use the real PowerShell regex and Select-Object implementations.
function Test-Path { param($LiteralPath) return $true }
function Select-String {
    param($LiteralPath,$Pattern,[switch]$AllMatches,$ErrorAction)
    foreach($line in $script:fixture){if($line -match $Pattern){[pscustomobject]@{Line=$line}}}
}
function Get-Content {
    param($LiteralPath,$Tail,$ErrorAction)
    $script:fixture | Select-Object -Last $Tail
}
function Set-Content {
    param([Parameter(ValueFromPipeline=$true)]$Value,$LiteralPath,$Encoding)
    process { $script:captured.Add([string]$Value) }
}
$script:fixture=@('C1_NUM_IN 0 0 1234','C1_NUM_IN 0 0 1234',
    'C1_PERF_ABORT job=1','C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=2',
    'C1_SOC_INFLIGHT_READ_ABORT_DRAIN_PASS pending_beats=4')
$script:fixture+=@(1..90 | ForEach-Object { 'ordinary '+$_ })
$script:fixture+=@('C1_NUM_DDR 0 0 1234','EXPECTED_PASS','same warning','same warning')
$script:captured=[System.Collections.Generic.List[string]]::new()
Save-CompactLog 'virtual-input' 'virtual-output' 'EXPECTED_PASS'
foreach($pair in @(
    @('C1_NUM_IN 0 0 1234',2),@('C1_NUM_DDR 0 0 1234',1),
    @('EXPECTED_PASS',1),@('C1_PERF_ABORT job=1',1),
    @('C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=2',1),
    @('C1_SOC_INFLIGHT_READ_ABORT_DRAIN_PASS pending_beats=4',1),@('same warning',2))) {
    if(@($script:captured | Where-Object {$_ -eq $pair[0]}).Count -ne $pair[1]) {
        throw ('Compact log lost or duplicated evidence: '+$pair[0])
    }
}
if($script:captured.Contains('ordinary 1')){throw 'Tail was not bounded'}
$script:fixture=@();$script:captured.Clear()
Save-CompactLog 'virtual-empty' 'virtual-output'
if($script:captured.Count -ne 1 -or $script:captured[0] -ne '(empty)'){throw 'Empty log regression'}
'C1_COMPACT_LOG_TEST_PASS duplicate_numeric_preserved=2 tail_overlap_removed=1 abort_evidence=1 no_files=1'
