# Run only the real parser function, never the EDA runner's top-level commands.
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$parseTokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'run_efinity_ti60_resource_map_detached.ps1'),[ref]$parseTokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'EDA runner parse failed'}
$definition=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-ResourceMetrics'},$true)
if(-not $definition){throw 'actual metrics function missing'}
Invoke-Expression $definition.Extent.Text
$fixture=Join-Path $caseRoot 'tests\fixtures\efinity_truncated_map.txt'
$original=Get-Content -LiteralPath (Join-Path $caseRoot 'logs\efinity_resource_runs\c39_onehot_acceptance_20260915a_joint_s2_onehot_cdc\summary.json') -Raw|ConvertFrom-Json
$row=@(Get-Content -LiteralPath $fixture)
if(@($row).Count -ne 1 -or $original.metrics.module_rows -cnotcontains $row[0]){throw 'fixture differs from retained original root row'}
$actual=Read-ResourceMetrics @($fixture) 'c1_ti60_c39_joint_s2_onehot_cdc'
if($actual.registers -ne 23053 -or $actual.le -ne 35368 -or $actual.ebr -ne 165 -or $actual.dsp -ne 125){throw 'truncated root MAP incorrectly parsed'}
$missing=Read-ResourceMetrics @() 'missing'
if($null -ne $missing.ebr -or $null -ne $missing.registers){throw 'missing statistics incorrectly treated as zero'}
$wrong=Read-ResourceMetrics @($fixture) 'c1_ti60_c39_joint_s2_onehot'
if($null -ne $wrong.module_row -or $null -ne $wrong.ebr){throw 'different root instance incorrectly accepted'}
'EFINITY_MAP_POWERSHELL_SELFTEST_PASS actual_root=1 ff=23053 lut4=35368 ram=165 dsp=125 missing_RAM=null wrong_root_rejected=1 historical_modified=0'
