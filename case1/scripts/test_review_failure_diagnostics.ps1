[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
# Parse and load only the pure formatter, never execute the regression runner.
$parseErrors=$null
$parseTokens=$null
$runner=Join-Path $PSScriptRoot 'run_iverilog_review_fixes.ps1'
$ast=[System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$parseTokens,[ref]$parseErrors)
if($parseErrors.Count) {throw $parseErrors}
$formatter=$ast.Find({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Format-C1RegressionFailure'
},$true)
if(!$formatter) {throw 'Diagnostic formatter missing'}
. ([scriptblock]::Create($formatter.Extent.Text))
$fixture=@('FATAL: injected early root cause') + @('noise '*100)*500 + @('last context')
$message=Format-C1RegressionFailure 'Regression failed exit=1' 'tb_example' @('-PSEED=7') $fixture
if($message -notmatch 'injected early root cause' -or $message -notmatch 'SEED=7' -or
   $message -notmatch 'last context' -or $message.Length -gt 5000) {
    throw 'Diagnostic retention/bounding test failed'
}
$empty=Format-C1RegressionFailure 'Timeout' 'tb_empty' @() @()
if($empty -notmatch 'Timeout: tb_empty') {throw 'Empty diagnostic test failed'}
Write-Output 'C1_FAILURE_DIAGNOSTIC_PASS early_fatal=1 flags=1 tail=1 bounded=1 empty=1 parser=1'
