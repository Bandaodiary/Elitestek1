# Read-only, bounded observation. Never launches, stops or restarts a simulator.
[CmdletBinding()]
param([string]$RunId='c39_onehot_stable_camera30_20260915b',
      [int]$KernelPid=36500,
      [string]$KernelStart='2026-09-15T21:06:50.6944104+08:00')
$ErrorActionPreference='Stop'
if($RunId -notmatch '^[A-Za-z0-9_-]+$' -or $KernelPid -le 0){throw 'invalid observation identity'}
if($RunId -ne 'c39_onehot_stable_camera30_20260915b' -and
   (-not $PSBoundParameters.ContainsKey('KernelPid') -or -not $PSBoundParameters.ContainsKey('KernelStart'))){
    throw 'a different run requires explicitly observed kernel identity; never reuse the defaults'
}
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$folder=Join-Path $caseRoot "logs\c39_onehot_trained_host_runs\$RunId"
$statePath=Join-Path $folder 'status.json'
$state=$null
for($attempt=0;$attempt -lt 5;$attempt++){
    try{
        $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -ErrorAction Stop
        if($state.run_id -ne $RunId){throw 'incomplete/wrong run status'}
        break
    }catch{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 200}
}
$expectedPrivate=Join-Path $caseRoot "sim\c1_c39_onehot_trained_host_$RunId"
if([IO.Path]::GetFullPath($state.run_directory) -ne $expectedPrivate){throw 'unexpected private directory'}
$kernel=Get-Process -Id $KernelPid -ErrorAction SilentlyContinue
$same=$false;$actualStart=$null;$cpu=$null;$memory=$null
if($kernel){
    try{
        $actualStart=$kernel.StartTime.ToString('o')
        $same=$kernel.ProcessName -eq 'xsimk' -and
            $kernel.StartTime.ToUniversalTime().Ticks -eq ([DateTime]$KernelStart).ToUniversalTime().Ticks
        if($same){$cpu=$kernel.CPU;$memory=[math]::Round($kernel.WorkingSet64/1MB,1)}
    }finally{$kernel.Dispose()}
}
$candidate=if(Test-Path -LiteralPath $expectedPrivate){Join-Path $expectedPrivate 'native\native_xsim.stdout.log'}else{Join-Path $folder 'native_xsim.result.log'}
$reference=Join-Path $caseRoot 'logs\c37_trained_host_runs\c37_stable_native_20260915a\native_xsim.result.log'
$stageRows=@();$referenceStages=@{};$bytes=0
$frames=@();$latestStage=$null;$latestProgress=$null;$latestStart=$null
if(Test-Path -LiteralPath $candidate){
    foreach($file in @($reference,$candidate)){
        $length=(Get-Item -LiteralPath $file).Length
        if($length -gt 1MB){throw 'observation refuses large logs'}
        $bytes+=$length
    }
    Get-Content -LiteralPath $reference|ForEach-Object{
        if($_ -match '^C1_R2_FUSED_RGB2_HOST_SYSTEM_STAGE tag=0 stage=(\d+) cycles=(\d+) words=(\d+)$'){
            $id=[int]$Matches[1]
            if($referenceStages.ContainsKey($id)){throw 'duplicate reference stage'}
            $referenceStages[$id]=@([long]$Matches[2],[long]$Matches[3])
        }
    }
    $stageRows=@(Get-Content -LiteralPath $candidate|ForEach-Object{
        if($_ -match '^C1_R2_FUSED_RGB2_HOST_SYSTEM_FRAME width=(\d+) height=(\d+) stalls=(\d+) tag=(\d+) cycles=(\d+) read_beats=(\d+) write_beats=(\d+) producers=(\d+) commits=(\d+)$'){
            $frames+=,[ordered]@{width=[int]$Matches[1];height=[int]$Matches[2];stalls=[int]$Matches[3];
                tag=[int]$Matches[4];compute_cycles=[long]$Matches[5];commits=[int]$Matches[9]}
        }
        if($_ -match '^C1_R2_FUSED_RGB2_HOST_SYSTEM_NN_START job=(\d+) tag=(\d+) cycle=(\d+) input=([0-9a-fA-F]+) output=([0-9a-fA-F]+)$'){
            $latestStart=[ordered]@{job=[int]$Matches[1];tag=[int]$Matches[2];start_cycle=[long]$Matches[3]}
        }
        if($_ -match '^C1_R2_FUSED_RGB2_HOST_SYSTEM_STAGE tag=(\d+) stage=(\d+) cycles=(\d+) words=(\d+)$'){
            $latestStage=[ordered]@{tag=[int]$Matches[1];stage=[int]$Matches[2];compute_cycles=[long]$Matches[3];words=[long]$Matches[4]}
        }
        if($_ -match '^C1_R2_FUSED_RGB2_HOST_SYSTEM_PROGRESS cycle=(\d+) cnn_done=(\d+) captures=(\d+) displays=(\d+) scan_level=(\d+)$'){
            $latestProgress=[ordered]@{cycle=[long]$Matches[1];cnn_done=[int]$Matches[2];
                captures=[int]$Matches[3];displays=[int]$Matches[4];scan_level=[int]$Matches[5]}
        }
        if($_ -match '^C1_R2_FUSED_RGB2_HOST_SYSTEM_STAGE tag=0 stage=(\d+) cycles=(\d+) words=(\d+)$'){
            $id=[int]$Matches[1];$cycles=[long]$Matches[2];$words=[long]$Matches[3]
            if(-not $referenceStages.ContainsKey($id)){throw 'stage absent from reference'}
            [ordered]@{stage=$id;candidate_cycles=$cycles;reference_cycles=$referenceStages[$id][0];
                words_equal=($words -eq $referenceStages[$id][1]);cycles_equal=($cycles -eq $referenceStages[$id][0])}
        }
    })
    for($index=0;$index -lt $stageRows.Count;$index++){
        if($stageRows[$index].stage -ne $index){throw 'non-contiguous or duplicate first-frame stage progress'}
    }
    # A matched stage prefix is progress only, never a six-frame throughput gate.
}
[ordered]@{run=$RunId;observed=(Get-Date -Format o);state=$state.state;step=$state.step;
    expected_kernel_pid=$KernelPid;expected_kernel_start=$KernelStart;actual_kernel_start=$actualStart;
    original_kernel_live=$same;kernel_cpu_seconds=$cpu;kernel_memory_mb=$memory;
    absence_means='not observed; inspect terminal worker state, never auto-restart';
    bounded_logs_bytes=$bytes;first_frame_stages_compared=$stageRows.Count;
    all_observed_stage_cycles_and_words_equal=($stageRows.Count -gt 0 -and
        @($stageRows|Where-Object {-not $_.words_equal -or -not $_.cycles_equal}).Count -eq 0);
    latest_observed_stage=($stageRows|Select-Object -Last 1);
    first_frame_comparison_only=$true;observed_frame_events=$frames.Count;
    last_observed_frame=($frames|Select-Object -Last 1);latest_work_stage=$latestStage;
    latest_NN_start=$latestStart;latest_reported_progress=$latestProgress;
    no_FPS_inferred_from_frame_compute_cycles=$true;full_native_acceptance_proven=$false}|ConvertTo-Json -Depth 4
