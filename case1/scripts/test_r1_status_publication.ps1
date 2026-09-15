[CmdletBinding()]
param([ValidateRange(2,4)][int]$Workers=4,[ValidateRange(2,100)][int]$Writes=32)
$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$runner=Join-Path $PSScriptRoot 'run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'runner syntax failure'}
$setter=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-StatusContent'},$true)
if(-not $setter){throw 'missing production status publisher'}
$init=[scriptblock]::Create($setter.Extent.Text)
$testRoot=Join-Path $caseRoot ('logs\status_atomic_test_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$target=Join-Path $testRoot 'latest.json'
$statusJobs=@();$samples=0;$sharingRetries=0;$watch=[Diagnostics.Stopwatch]::StartNew()
try {
    . $init
    $firstValue=@{writer=1;sequence=1;payload=('x'*4096)}|ConvertTo-Json -Compress
    Set-StatusContent $target $firstValue
    Set-StatusContent $target $firstValue
    Write-Output 'C1_STATUS_PUBLICATION_SEQUENTIAL_PASS create=1 update=1'
    # Use the production exclusive-handle publisher in real PowerShell child
    # processes. No Vivado processes or simulator projects are launched.
    foreach($writer in 1..$Workers) {
        $statusJobs+=Start-Job -InitializationScript $init -ScriptBlock {
            param($path,$identity,$count)
            $ErrorActionPreference='Stop'
            foreach($sequence in 1..$count) {
                $value=@{writer=$identity;sequence=$sequence;payload=('x'*4096)}|ConvertTo-Json -Compress
                Set-StatusContent $path $value
            }
        } -ArgumentList $target,$writer,$Writes
    }
    while(@($statusJobs | Where-Object {$_.State -in @('Running','NotStarted')}).Count) {
        if($watch.Elapsed.TotalSeconds -gt 45){throw 'status publisher test timeout'}
        if(Test-Path -LiteralPath $target) {
            # Readers may meet an OS sharing violation during publication;
            # retry only I/O errors. Truncated/invalid JSON must still fail.
            try {$json=Get-Content -LiteralPath $target -Raw}
            catch {
                if($_.Exception.GetBaseException() -isnot [IO.IOException]){throw}
                $sharingRetries++;Start-Sleep -Milliseconds 5;continue
            }
            $record=$json | ConvertFrom-Json
            if($record.writer -lt 1 -or $record.writer -gt $Workers -or $record.sequence -lt 1 -or
               $record.sequence -gt $Writes -or $record.payload.Length -ne 4096){throw 'torn or malformed status snapshot'}
            $samples++
        }
        Start-Sleep -Milliseconds 5
    }
    foreach($job in $statusJobs) {
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
        if($job.State -ne 'Completed'){throw 'status publisher child failed'}
    }
    $record=Get-Content -LiteralPath $target -Raw | ConvertFrom-Json
    if($record.sequence -ne $Writes){throw 'final snapshot lost the completed update'}
    if(@(Get-ChildItem -LiteralPath $testRoot -Filter '*.pending' -File).Count){throw 'publisher retained pending status files'}
    if($samples -eq 0){throw 'no live concurrent snapshot observed'}
    Write-Output "C1_STATUS_PUBLICATION_PASS workers=$Workers writes=$($Workers*$Writes) valid_snapshots=$samples sharing_retries=$sharingRetries final=$Writes"
} finally {
    foreach($job in $statusJobs) {
        if($job.State -in @('Running','NotStarted')){Stop-Job -Job $job}
        Remove-Job -Job $job -Force
    }
    # Delete only exact known siblings in this new, validated test directory.
    $resolvedTest=(Resolve-Path -LiteralPath $testRoot).Path
    if(-not $resolvedTest.StartsWith((Join-Path $caseRoot 'logs\status_atomic_test_'),[StringComparison]::OrdinalIgnoreCase)){
        throw 'status-test cleanup escaped its dedicated directory'
    }
    foreach($file in Get-ChildItem -LiteralPath $resolvedTest -File) {
        if($file.Name -eq 'latest.json' -or $file.Name -match '^latest\.json\.\d+\.pending$') {
            Remove-Item -LiteralPath $file.FullName
        }
    }
    if(@(Get-ChildItem -LiteralPath $resolvedTest -Force).Count -eq 0){Remove-Item -LiteralPath $resolvedTest}
}
