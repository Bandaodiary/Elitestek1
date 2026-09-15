<##
.SYNOPSIS
  Run the bounded stage-0 -> stage-1…stage-21 handoff gate with Icarus.

.DESCRIPTION
  This is the quick, boardless companion to
  run_r1_stage1_handoff_xsim_detached.ps1.  It compiles the real adapter,
  MicroStyle engine/top and production parameter bank against the existing
  8x8 vectors.  The default mode stops after the first stage-1 pixel;
  -FullStage1 stops after the complete 2x2 stage-1 output; -FullStage2 runs
  the complete 2x2 stage-2 1x1 expansion; -FullStage3 runs the complete 2x2
  stage-3 depthwise3x3 after those prerequisites.  -FullStage4, -FullStage5,
  and -FullStage6 extend the same finite 2x2 bank handoff through the first
  residual block (project1x1, add_relu, and res1.expand1x1 respectively).
  -FullStage7 adds the bounded res1.depthwise3x3 handoff.  -FullStage8 through
  -FullStage20 extend the same finite 2x2 bank handoff through the residual,
  decoder and output layers; -FullStage21 checks the final 64 RGB beats and
  completes naturally.  A higher stage switch takes precedence and implies
  all lower-stage prerequisites in the testbench.  Intermediate endpoints use
  a protocol-safe abort after the final write response.
  All vectors and the vvp snapshot live
  below a disposable %TEMP% directory and are removed in finally, so no
  simulator tree is retained in case1/sim.
##>
[CmdletBinding()]
param(
  [string]$IcarusHome = 'D:\iverilog',
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

function Resolve-Tool([string]$Root, [string]$Name) {
  $candidate = if ([string]::IsNullOrWhiteSpace($Root)) { '' } else {
    Join-Path (Join-Path $Root 'bin') ($Name + '.exe')
  }
  if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    return (Resolve-Path -LiteralPath $candidate).Path
  }
  $command = Get-Command ($Name + '.exe') -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  throw "Unable to find $Name.exe. Set -IcarusHome to the installation root or refresh PATH."
}

function Invoke-Native([string]$File, [string[]]$Arguments) {
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $lines = @(& $File @Arguments 2>&1 | ForEach-Object { $_.ToString() })
  $exitCode = $LASTEXITCODE
  $ErrorActionPreference = $saved
  [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
}

function Assert-Marker($Result, [string]$Marker, [string]$Label) {
  if ($Result.ExitCode -ne 0) {
    throw "$Label exited with code $($Result.ExitCode): $($Result.Lines -join ' | ')"
  }
  $count = @($Result.Lines | Where-Object { $_ -like "*$Marker*" }).Count
  if ($count -ne 1) {
    throw "$Label marker '$Marker' count=${count}: $($Result.Lines -join ' | ')"
  }
  if (@($Result.Lines | Where-Object { $_ -match '(?i)\b(FATAL|ERROR|FAIL)\b' }).Count -ne 0) {
    throw "$Label reported a fatal/error/fail line: $($Result.Lines -join ' | ')"
  }
}

$iverilog = Resolve-Tool $IcarusHome 'iverilog'
$vvp = Resolve-Tool $IcarusHome 'vvp'
$iverilogBin = Split-Path -Parent $iverilog
if (($env:PATH -split ';') -notcontains $iverilogBin) {
  $env:PATH = $iverilogBin + ';' + $env:PATH
}

$runRoot = Join-Path ([IO.Path]::GetTempPath()) `
  ('c1_iverilog_stage1_handoff_' + [guid]::NewGuid().ToString('N'))
$vvpPath = Join-Path $runRoot 'stage1_handoff.vvp'
$top = 'tb_c1_r1_microstyle_artifact_tensor_engine_8x8'
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
$locationPushed = $false

try {
  New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
  foreach ($f in 'descriptors.mem', 'parameter_arena.mem',
                    'engine_vectors.mem', 'expected_outputs.mem',
                    'stage_meta.mem') {
    Copy-Item -LiteralPath (Join-Path $vecRoot $f) `
      -Destination (Join-Path $runRoot $f)
  }
  Push-Location $runRoot
  $locationPushed = $true
  $defines = @('-D', 'C1_USE_PARAMETER_BANK', '-D', 'C1_STAGE1_HANDOFF')
  if ($PackedAffine) { $defines += @('-D', 'C1_PACKED_AFFINE_CACHE') }
  $marker = 'C1_R1_STAGE1_HANDOFF_8X8_PASS'
  $mode = 'first_pixel'
  # Keep the highest requested gate when multiple switches are supplied.  The
  # testbench's stage-N macro recursively enables all required predecessors.
  $requestedStage = 0
  foreach ($n in 21..8) { if ((Get-Variable "FullStage$n" -ValueOnly)) { $requestedStage = $n; break } }
  if ($requestedStage -ge 8) {
    $defines += @('-D', "C1_STAGE${requestedStage}_FULL")
    $marker = "C1_R1_STAGE${requestedStage}_FULL_8X8_PASS"
    $mode = "stage${requestedStage}_full_scaled"
  } elseif ($FullStage7) {
    $defines += @('-D', 'C1_STAGE7_FULL')
    $marker = 'C1_R1_STAGE7_FULL_8X8_PASS'
    $mode = 'stage7_full_2x2'
  } elseif ($FullStage6) {
    $defines += @('-D', 'C1_STAGE6_FULL')
    $marker = 'C1_R1_STAGE6_FULL_8X8_PASS'
    $mode = 'stage6_full_2x2'
  } elseif ($FullStage5) {
    $defines += @('-D', 'C1_STAGE5_FULL')
    $marker = 'C1_R1_STAGE5_FULL_8X8_PASS'
    $mode = 'stage5_full_2x2'
  } elseif ($FullStage4) {
    $defines += @('-D', 'C1_STAGE4_FULL')
    $marker = 'C1_R1_STAGE4_FULL_8X8_PASS'
    $mode = 'stage4_full_2x2'
  } elseif ($FullStage3) {
    $defines += @('-D', 'C1_STAGE3_FULL')
    $marker = 'C1_R1_STAGE3_FULL_8X8_PASS'
    $mode = 'stage3_full_2x2'
  } elseif ($FullStage2) {
    $defines += @('-D', 'C1_STAGE2_FULL')
    $marker = 'C1_R1_STAGE2_FULL_8X8_PASS'
    $mode = 'stage2_full_2x2'
  } elseif ($FullStage1) {
    $defines += @('-D', 'C1_STAGE1_FULL')
    $marker = 'C1_R1_STAGE1_FULL_8X8_PASS'
    $mode = 'full_2x2'
  }
  $compile = Invoke-Native $iverilog `
    (@('-g2012', '-s', $top, '-o', $vvpPath) + $defines + $sources)
  if ($compile.ExitCode -ne 0) {
    throw "Icarus compile failed: $($compile.Lines -join ' | ')"
  }
  $run = Invoke-Native $vvp @($vvpPath)
  Assert-Marker $run $marker ("Icarus $mode gate")
  $markerLine = $run.Lines | Where-Object { $_ -like "*$marker*" }
  Write-Output ("C1_IVERILOG_STAGE1_PASS mode={0} marker={1}" -f $mode, $markerLine)
} finally {
  if ($locationPushed) { Pop-Location -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $runRoot) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
