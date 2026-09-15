[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$c1Profile=Join-Path $PSScriptRoot 'run_r1_column_refill_profile.ps1'
$c1Runner=Join-Path $PSScriptRoot 'run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1'
$c1Tokens=$null; $c1Errors=$null
$c1Ast=[System.Management.Automation.Language.Parser]::ParseFile($c1Runner,[ref]$c1Tokens,[ref]$c1Errors)
if($c1Errors.Count){throw 'Underlying runner did not parse'}
$c1Allowed=@($c1Ast.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath})
$c1Common=@('TensorColumnReads','TrainedArtifact','ColorFixture','PipelineDwPixels',
    'PipelineDotPixels','StreamDwFrame','FuseFinalOutput','TensorPackedWrites','TensorWriteEnd')
$c1Count=0
foreach($c1Entries in @(1,2)){foreach($c1Scenario in @('Single','ReadAbort','WriteAbort','TwoFrame')){
    foreach($c1Mode in @('Baseline','Handoff','WindowOnly','Wide')){
        $c1Cfg=& $c1Profile -Scenario $c1Scenario -RefillMode $c1Mode -ScalarReadCacheEntries $c1Entries -DryRun | ConvertFrom-Json
        if($c1Cfg.ScalarReadCacheEntries -ne $c1Entries){throw 'Scalar cache capacity was lost'}
        if([bool]$c1Cfg.RefillRequestHandoff -ne ($c1Mode -in @('Handoff','Wide')) -or
           [bool]$c1Cfg.WideRefillWindow -ne ($c1Mode -in @('WindowOnly','Wide'))){
            throw 'Incorrect refill selection'
        }
        if([bool]$c1Cfg.NumericalTrace -ne ($c1Scenario -ne 'TwoFrame') -or
           [bool]$c1Cfg.TwoFrameTrace -ne ($c1Scenario -eq 'TwoFrame') -or
           [bool]$c1Cfg.TwoFrame -ne ($c1Scenario -eq 'TwoFrame')){throw 'Incorrect trace selection'}
        if($c1Cfg.Frame -ne $(if($c1Scenario -eq 'Single'){'64x48'}else{'8x8'})){
            throw 'Incorrect frame selection'
        }
        if($c1Cfg.TensorWriteOutstanding -ne 1 -or $c1Cfg.PixelWriteBatchWords -ne 8 -or
           $c1Cfg.TensorWriteBuildTimeout -ne 64){throw 'Incorrect verified write profile'}
        foreach($c1Flag in $c1Common){if($c1Cfg.$c1Flag -ne $true){throw "Missing common flag $c1Flag"}}
        $c1Recovery=$c1Scenario -in @('ReadAbort','WriteAbort')
        if([bool]$c1Cfg.SourceGeometry -ne $c1Recovery -or
           [bool]$c1Cfg.ConcurrentCapture -ne $c1Recovery){throw 'Incorrect recovery prerequisites'}
        foreach($c1Flag in @('InflightReadAbort','VirtualUpsampleReadAbort','PixelPrefetchReadAbort')){
            if([bool]$c1Cfg.$c1Flag -ne ($c1Scenario -eq 'ReadAbort')){throw "Incorrect read flag $c1Flag"}
        }
        foreach($c1Flag in @('InflightWriteAbort','DwPixelWriteAbort')){
            if([bool]$c1Cfg.$c1Flag -ne ($c1Scenario -eq 'WriteAbort')){throw "Incorrect write flag $c1Flag"}
        }
        foreach($c1Property in $c1Cfg.PSObject.Properties.Name){
            if($c1Property -eq 'Worker' -or $c1Property -notin $c1Allowed){
                throw "Unrecognized or unsafe dispatch option $c1Property"
            }
        }
        $c1Count++
    }
}}
$c1Warm=& $c1Profile -Scenario ReadAbort -ScalarReadCacheEntries 2 -WarmScalarAbort -DryRun | ConvertFrom-Json
if(-not $c1Warm.ScalarReadAbort -or -not $c1Warm.ScalarAssocReadAbort -or
    $c1Warm.VirtualUpsampleReadAbort -or $c1Warm.PixelPrefetchReadAbort){throw 'Incorrect warm scalar abort owner'}
$c1BadWarm=$false
try{& $c1Profile -Scenario ReadAbort -ScalarReadCacheEntries 1 -WarmScalarAbort -DryRun | Out-Null}catch{$c1BadWarm=$true}
if(-not $c1BadWarm){throw 'Warm scalar test accepted one entry'}
$c1Invalid=$false
try{& $c1Profile -Scenario TwoFrame -Frame 64x48 -DryRun | Out-Null}catch{$c1Invalid=$true}
if(-not $c1Invalid){throw 'Unsupported geometry was accepted'}
$c1Small=& $c1Profile -Frame 8x8 -RunId bounded_profile_test -DryRun | ConvertFrom-Json
if($c1Small.Frame -ne '8x8' -or $c1Small.RunId -ne 'bounded_profile_test'){throw 'Explicit options lost'}
Write-Output "C1_COLUMN_PROFILE_DRY_PASS configurations=$c1Count no_dispatch=1 known_runner_options=1"
Write-Output 'C1_COLUMN_PROFILE_REJECT_PASS unsupported_geometry=1 explicit_small_frame=1 warm_scalar_owner=1 bad_warm_rejected=1'
