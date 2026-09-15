# Dot-source only from a detached worker. Changes this worker, not global policy.
# Descendants inherit affinity and BelowNormal priority at process creation.
$budgetWorker=[Diagnostics.Process]::GetCurrentProcess()
$budgetPeerNames=@('xsim','xsimk','xelab','xvlog','vvp','iverilog','efx_map','efx_pnr')
$budgetPeers=@(Get-Process -Name $budgetPeerNames -ErrorAction SilentlyContinue)
if($budgetPeers.Count){throw ('Another FPGA tool is active; refusing overlap: '+(($budgetPeers|ForEach-Object {$_.ProcessName+':'+$_.Id}) -join ','))}
$budgetLease=New-Object Threading.Mutex($false,'Local\Case1FpgaHeavyWorker')
try {$budgetOwned=$budgetLease.WaitOne(0)} catch [Threading.AbandonedMutexException] {$budgetOwned=$true}
if(-not $budgetOwned){$budgetLease.Dispose();throw 'Another budgeted case1 FPGA worker is active'}
$budgetAllowed=$budgetWorker.ProcessorAffinity.ToInt64()
[long]$budgetMask=0
$budgetCount=0
for($budgetBit=0;$budgetBit -lt 63 -and $budgetCount -lt 2;$budgetBit++){
    [long]$budgetCandidate=[long]1 -shl $budgetBit
    if(($budgetAllowed -band $budgetCandidate) -ne 0){$budgetMask=$budgetMask -bor $budgetCandidate;$budgetCount++}
}
if($budgetCount -lt 1){throw 'No allowed logical processor for FPGA worker'}
$budgetWorker.ProcessorAffinity=[IntPtr]$budgetMask
$budgetWorker.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
$budgetWorker.Refresh()
if($budgetWorker.ProcessorAffinity.ToInt64() -ne $budgetMask -or $budgetWorker.PriorityClass -ne 'BelowNormal'){throw 'Failed to apply worker budget'}
$workerBudget=[ordered]@{policy='single-heavy-worker';logical_processors=$budgetCount;affinity_mask=$budgetMask;priority='BelowNormal';thermal_safety_claim=$false}
