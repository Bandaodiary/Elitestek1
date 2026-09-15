<##
.SYNOPSIS
  Run the bounded trained-artifact -> tensor-adapter -> RTL-engine probe.

.DESCRIPTION
  The foreground invocation only creates a WMI worker.  The worker launches
  xvlog/xelab/xsim outside the Codex Windows job, keeps all simulator output
  below a disposable case1/sim run directory, and removes that directory in a
  finally block.  This is an 8x8 correctness probe, not a native-frame or
  throughput run.
##>
[CmdletBinding()]
param(
  [switch]$Worker,
  [string]$RunId = ''
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
$simRoot = Join-Path $caseRoot 'sim'
$vecRoot = Join-Path $caseRoot 'vectors\microstyle_engine_bitexact_8x8'
$logRoot = Join-Path $caseRoot 'logs\r1_microstyle_artifact_tensor_engine_8x8_runs'

if (-not $Worker) {
  if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = [guid]::NewGuid().ToString('N')
  }
  $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $cmd = "`"$ps`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Worker -RunId $RunId"
  # Prefer WMI, but retain a native CREATE_BREAKAWAY_FROM_JOB fallback for
  # hosts where the local policy blocks Win32_Process.Create (as on some
  # managed desktops).  Both paths create the worker outside this job.
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

$runRoot = Join-Path $simRoot "xsim_r1_microstyle_artifact_tensor_engine_8x8_$RunId"
$runLog = Join-Path $logRoot $RunId
$statusPath = Join-Path $runLog 'status.json'
$vivadoBin = 'D:\vivado\vivado\Vivado\2023.1\bin'
$clock = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $runRoot, $runLog | Out-Null

function Set-RunStatus([string]$State, [string]$Step, [int]$Code, [string]$Message) {
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

function Invoke-VivadoStep([string]$Name, [string]$Tool, [string[]]$Arguments,
                            [string]$Marker = '') {
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
  Set-RunStatus 'running' 'setup' 0 'detached 8x8 artifact tensor-engine probe'
  foreach ($f in 'descriptors.mem', 'parameter_arena.mem', 'engine_vectors.mem',
                    'expected_outputs.mem', 'stage_meta.mem') {
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
    (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_engine.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_cnn_top.sv'),
    (Join-Path $rtlRoot 'cnn\c1_r1_microstyle_tensor_adapter.sv'),
    (Join-Path $rtlRoot 'cnn\c1_pixel_result_writer.sv'),
    (Join-Path $simRoot 'tb_c1_r1_microstyle_artifact_tensor_engine_8x8.sv')
  )

  Invoke-VivadoStep 'xvlog' (Join-Path $vivadoBin 'xvlog.bat') (@('-sv') + $sources)
  Invoke-VivadoStep 'xelab' (Join-Path $vivadoBin 'xelab.bat') `
      @('tb_c1_r1_microstyle_artifact_tensor_engine_8x8', '-s', 'artifact_tensor_8x8_sim')
  Invoke-VivadoStep 'xsim' (Join-Path $vivadoBin 'xsim.bat') `
      @('artifact_tensor_8x8_sim', '-runall') `
      'C1_R1_MICROSTYLE_ARTIFACT_TENSOR_ENGINE_8X8_PASS'
  $clock.Stop()
  Set-RunStatus 'complete' 'done' 0 'trained artifact tensor-engine probe passed'
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
