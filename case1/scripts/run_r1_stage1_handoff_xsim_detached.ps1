<##
.SYNOPSIS
  Run the bounded scaled stage-0 -> stage-1…stage-21 tensor-bank handoff gate.

.DESCRIPTION
  The foreground invocation creates only a detached worker.  The worker
  compiles the existing 22-stage adapter/engine testbench with the production
  atomic parameter bank and C1_STAGE1_HANDOFF mode, then runs xsim without a
  waveform.  It copies the small 8x8 trained-artifact vectors into a private
  runRoot and removes that tree in finally.  By default the gate completes all
  scaled stage-0 output writes, checks the first stage-1 pixel (2 input groups
  and 3 output groups), and aborts before any unbounded later-stage traffic.
  -FullStage1 selects the still-bounded full 2x2 stage-1 (12 output groups).
  -FullStage2 selects the bounded full 2x2 stage-2 1x1 expansion (24 output
  groups); the testbench automatically enables the full stage-1 prerequisite.
  -FullStage3 selects the bounded full 2x2 stage-3 depthwise3x3 (24 output
  groups); the testbench automatically enables the stage-1/2 prerequisites.
  -FullStage4, -FullStage5, and -FullStage6 extend the finite 2x2 handoff
  through res0.project1x1, res0.add_relu, and res1.expand1x1 respectively.
  -FullStage7 adds the bounded res1.depthwise3x3 handoff.  -FullStage8 through
  -FullStage20 extend the finite 2x2 handoff through residual/decoder/output
  layers; -FullStage21 checks 64 final RGB beats and completes naturally.
  A higher stage switch takes precedence when multiple switches are supplied,
  and the testbench automatically enables all lower-stage prerequisites.
  Intermediate endpoints abort only after the final write response, so the
  detached worker can drain outstanding protocol traffic safely.
##>
[CmdletBinding()]
param(
  [switch]$Worker,
  [string]$RunId = '',
  [switch]$FullStage1,
  [switch]$FullStage2,
  [switch]$FullStage3,
  [switch]$FullStage4,
  [switch]$FullStage5,
  [switch]$FullStage6,
  [switch]$FullStage7,
  [switch]$FullStage8, [switch]$FullStage9, [switch]$FullStage10,
  [switch]$FullStage11, [switch]$FullStage12, [switch]$FullStage13,
  [switch]$FullStage14, [switch]$FullStage15, [switch]$FullStage16,
  [switch]$FullStage17, [switch]$FullStage18, [switch]$FullStage19,
  [switch]$FullStage20, [switch]$FullStage21,
  [switch]$PackedAffine
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$vecRoot = Join-Path $caseRoot 'vectors\microstyle_engine_bitexact_8x8'
$logRoot = Join-Path $caseRoot 'logs\stage1_handoff_runs'
$requestedStage = 0
foreach ($n in 21..8) { if ((Get-Variable "FullStage$n" -ValueOnly)) { $requestedStage = $n; break } }

if (-not $Worker) {
  if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = [guid]::NewGuid().ToString('N')
  }
  $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  # Forward only the highest requested gate.  Stage-N testbench macros
  # recursively enable their lower-stage prerequisites.
  $fullArg = if ($requestedStage -ge 8) { " -FullStage$requestedStage" } elseif ($FullStage7) { ' -FullStage7' } elseif ($FullStage6) {
    ' -FullStage6'
  } elseif ($FullStage5) {
    ' -FullStage5'
  } elseif ($FullStage4) {
    ' -FullStage4'
  } elseif ($FullStage3) { ' -FullStage3' } elseif ($FullStage2) {
    ' -FullStage2'
  } elseif ($FullStage1) {
    ' -FullStage1'
  } else { '' }
  if ($PackedAffine) { $fullArg += ' -PackedAffine' }
  $cmd = "`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId$fullArg"
  try {
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
         -Arguments @{ CommandLine = $cmd; CurrentDirectory = $caseRoot }
    if ($r.ReturnValue -ne 0) {
      throw "Win32_Process.Create returned $($r.ReturnValue)"
    }
    $workerPid = [int]$r.ProcessId
  }
  catch {
    $fallback = Join-Path $caseRoot 'scripts\start_detached_process.ps1'
    $workerPid = [int](& powershell.exe -NoLogo -NoProfile -NonInteractive `
      -ExecutionPolicy Bypass -File $fallback -CommandLine $cmd `
      -CurrentDirectory $caseRoot)
  }
  [ordered]@{
    run_id = $RunId
    worker_pid = $workerPid
    status_path = (Join-Path $logRoot "$RunId\status.json")
  } | ConvertTo-Json
  return
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
  throw 'invalid RunId'
}

$runRoot = Join-Path $simRoot "xsim_r1_stage1_handoff_$RunId"
$runLog = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLog 'status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$clock = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot, $runLog | Out-Null

function Set-RunStatus([string]$State, [string]$Step, [int]$Code,
                        [string]$Message) {
  [ordered]@{
    run_id = $RunId
    state = $State
    step = $Step
    exit_code = $Code
    message = $Message
    elapsed_seconds = [math]::Round($clock.Elapsed.TotalSeconds, 3)
    run_directory = $runRoot
    log_directory = $runLog
  } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

function Invoke-VivadoStep([string]$Name, [string]$Tool,
                            [string[]]$Arguments, [string]$Marker = '') {
  Set-RunStatus 'running' $Name 0 "starting $Name"
  $stdout = Join-Path $runLog "$Name.stdout.log"
  $stderr = Join-Path $runLog "$Name.stderr.log"
  $p = Start-Process -FilePath $Tool -ArgumentList $Arguments `
       -WorkingDirectory $runRoot -WindowStyle Hidden -Wait -PassThru `
       -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $out = Get-Content -Raw -LiteralPath $stdout
  $err = Get-Content -Raw -LiteralPath $stderr
  if ($p.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($err) -or
      $out -match '(?im)Fatal|Error:|FAIL') {
    throw "$Name failed (exit=$($p.ExitCode))"
  }
  if ($Marker -and ([regex]::Matches($out, [regex]::Escape($Marker))).Count -ne 1) {
    throw "$Name marker mismatch"
  }
}

try {
  $modeLabel = if ($requestedStage -ge 8) { "detached full stage${requestedStage} gate" } elseif ($FullStage7) { 'detached full stage7 gate' } elseif ($FullStage6) {
    'detached full stage6 gate'
  } elseif ($FullStage5) {
    'detached full stage5 gate'
  } elseif ($FullStage4) {
    'detached full stage4 gate'
  } elseif ($FullStage3) { 'detached full stage3 gate' } elseif ($FullStage2) {
    'detached full stage2 gate'
  } elseif ($FullStage1) {
    'detached full stage1 gate'
  } else { 'detached stage1 handoff gate' }
  Set-RunStatus 'running' 'setup' 0 $modeLabel
  foreach ($f in 'descriptors.mem', 'parameter_arena.mem',
                    'engine_vectors.mem', 'expected_outputs.mem',
                    'stage_meta.mem') {
    Copy-Item -LiteralPath (Join-Path $vecRoot $f) `
              -Destination (Join-Path $runRoot $f)
  }

  $sources = @(
    (Join-Path $rtlRoot 'common\c1_ram_sdp_read_first.sv'),
    (Join-Path $rtlRoot 'control\c1_descriptor_pkg.sv'),
    (Join-Path $rtlRoot 'control\c1_descriptor_decoder_pkg.sv'),
    (Join-Path $rtlRoot 'control\c1_layer_command_decoder.sv'),
    (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum.sv'),
    (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_pipelined.sv'),
    (Join-Path $rtlRoot 'cnn\c1_s8_dot8_accum_treepipe.sv'),
    (Join-Path $rtlRoot 'cnn\c1_requant_bank8.sv'),
    (Join-Path $rtlRoot 'cnn\c1_dot8x8_requant_core.sv'),
    (Join-Path $rtlRoot 'cnn\c1_dwconv3x3_c8_requant_core.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_c8_parameter_scheduler.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_parameter_bank.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_engine.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_cnn_top.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_tensor_adapter.sv'),
    (Join-Path $rtlRoot 'cnn\c1_pixel_result_writer.sv'),
    (Join-Path $simRoot 'tb_c1_r1_microstyle_artifact_tensor_engine_8x8.sv')
  )

  $defines = @('-d', 'C1_USE_PARAMETER_BANK', '-d', 'C1_STAGE1_HANDOFF')
  if ($PackedAffine) { $defines += @('-d', 'C1_PACKED_AFFINE_CACHE') }
  if ($requestedStage -ge 8) {
    $defines += @('-d', "C1_STAGE${requestedStage}_FULL")
  } elseif ($FullStage7) {
    $defines += @('-d', 'C1_STAGE7_FULL')
  } elseif ($FullStage6) {
    $defines += @('-d', 'C1_STAGE6_FULL')
  } elseif ($FullStage5) {
    $defines += @('-d', 'C1_STAGE5_FULL')
  } elseif ($FullStage4) {
    $defines += @('-d', 'C1_STAGE4_FULL')
  } elseif ($FullStage3) {
    $defines += @('-d', 'C1_STAGE3_FULL')
  } elseif ($FullStage2) {
    $defines += @('-d', 'C1_STAGE2_FULL')
  } elseif ($FullStage1) {
    $defines += @('-d', 'C1_STAGE1_FULL')
  }
  $xvlogArgs = @('-sv') + $defines + $sources
  Invoke-VivadoStep 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') $xvlogArgs
  $snapshot = if ($requestedStage -ge 8) { "stage${requestedStage}_full_8x8_sim" } elseif ($FullStage7) { 'stage7_full_8x8_sim' } elseif ($FullStage6) {
    'stage6_full_8x8_sim'
  } elseif ($FullStage5) {
    'stage5_full_8x8_sim'
  } elseif ($FullStage4) {
    'stage4_full_8x8_sim'
  } elseif ($FullStage3) { 'stage3_full_8x8_sim' } elseif ($FullStage2) {
    'stage2_full_8x8_sim'
  } elseif ($FullStage1) {
    'stage1_full_8x8_sim'
  } else {
    'stage1_handoff_8x8_sim'
  }
  $marker = if ($requestedStage -ge 8) { "C1_R1_STAGE${requestedStage}_FULL_8X8_PASS" } elseif ($FullStage7) { 'C1_R1_STAGE7_FULL_8X8_PASS' } elseif ($FullStage6) {
    'C1_R1_STAGE6_FULL_8X8_PASS'
  } elseif ($FullStage5) {
    'C1_R1_STAGE5_FULL_8X8_PASS'
  } elseif ($FullStage4) {
    'C1_R1_STAGE4_FULL_8X8_PASS'
  } elseif ($FullStage3) { 'C1_R1_STAGE3_FULL_8X8_PASS' } elseif ($FullStage2) {
    'C1_R1_STAGE2_FULL_8X8_PASS'
  } elseif ($FullStage1) {
    'C1_R1_STAGE1_FULL_8X8_PASS'
  } else {
    'C1_R1_STAGE1_HANDOFF_8X8_PASS'
  }
  Invoke-VivadoStep 'xelab' (Join-Path $vivadoBin 'xelab.bat') `
      @('tb_c1_r1_microstyle_artifact_tensor_engine_8x8', '-s',
        $snapshot)
  Invoke-VivadoStep 'xsim' (Join-Path $vivadoBin 'xsim.bat') `
      @($snapshot, '-runall') $marker
  $clock.Stop()
  $doneMessage = if ($requestedStage -ge 8) { "full stage${requestedStage} gate passed" } elseif ($FullStage7) { 'full stage7 gate passed' } elseif ($FullStage6) {
    'full stage6 gate passed'
  } elseif ($FullStage5) {
    'full stage5 gate passed'
  } elseif ($FullStage4) {
    'full stage4 gate passed'
  } elseif ($FullStage3) { 'full stage3 gate passed' } elseif ($FullStage2) {
    'full stage2 gate passed'
  } elseif ($FullStage1) {
    'full stage1 gate passed'
  } else {
    'stage1 handoff gate passed'
  }
  Set-RunStatus 'complete' 'done' 0 $doneMessage
}
catch {
  $clock.Stop()
  Set-RunStatus 'failed' 'error' 1 $_.Exception.Message
  exit 1
}
finally {
  if (Test-Path -LiteralPath $runRoot) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
