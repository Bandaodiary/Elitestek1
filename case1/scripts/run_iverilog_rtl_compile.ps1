<##
.SYNOPSIS
  Compile the complete board-independent Case-1 RTL with Icarus Verilog.

.DESCRIPTION
  This is a bounded compile/elaboration smoke, not a functional frame
  regression.  It uses Icarus SystemVerilog-2012, orders the four package
  files before the remaining RTL sources, and elaborates
  c1_r1_portable_soc.  The response file, diagnostic output and VVP image are
  created below %TEMP% and removed in a finally block.  Use -KeepVvp only when
  a deliberately bounded copy is needed for inspection.

  No Efinity IP, Vivado, xsim, map, P&R or board programming is invoked.
  There are intentionally no extra -D defines or -I include directories.
  -QueuedWriteFabric elaborates the optional depth-4 W-ahead/AW-bypass branch
  with shared QoS enabled. It does not run a simulation or enable board IP.
##>
[CmdletBinding()]
param(
    [string]$IcarusHome = 'D:\iverilog',
    [switch]$KeepVvp,
    [switch]$QueuedWriteFabric,
    [string]$VvpPath = '',
    [ValidateRange(0, 20)]
    [int]$WarningSampleCount = 5
)

$ErrorActionPreference = 'Stop'

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
    # Keep native diagnostics in memory so no simulator log is left in the
    # repository.  Capture LASTEXITCODE immediately after the native call.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = @(& $File @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $saved
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
}

$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rtlRoot = Join-Path $caseRoot 'rtl'
if (-not (Test-Path -LiteralPath $rtlRoot -PathType Container)) {
    throw "RTL root does not exist: $rtlRoot"
}

$iverilog = Resolve-Tool $IcarusHome 'iverilog'
$iverilogBin = Split-Path -Parent $iverilog
# Keep the installation-specific DLL lookup local to this PowerShell process.
if (($env:PATH -split ';') -notcontains $iverilogBin) {
    $env:PATH = $iverilogBin + ';' + $env:PATH
}

# Icarus needs package declarations before modules that import them.  Keep
# this list explicit and relative to rtlRoot so a source-file rename fails
# loudly instead of silently changing the compile contract.
$priorityRelative = @(
    'common\c1_fixed_pkg.sv',
    'control\c1_descriptor_pkg.sv',
    'control\c1_descriptor_decoder_pkg.sv',
    'control\c1_frame_buffer_pkg.sv'
)
$allSources = @(Get-ChildItem -LiteralPath $rtlRoot -Recurse -File -Filter '*.sv' | Sort-Object FullName)
if ($allSources.Count -eq 0) { throw "No SystemVerilog sources found below $rtlRoot" }

$orderedSources = New-Object 'System.Collections.Generic.List[string]'
foreach ($relative in $priorityRelative) {
    $path = Join-Path $rtlRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required package source is missing: $path"
    }
    [void]$orderedSources.Add((Resolve-Path -LiteralPath $path).Path)
}
foreach ($source in $allSources) {
    $full = (Resolve-Path -LiteralPath $source.FullName).Path
    if (-not ($orderedSources -contains $full)) {
        [void]$orderedSources.Add($full)
    }
}

$topSource = Join-Path $rtlRoot 'top\c1_r1_portable_soc.sv'
if (-not (Test-Path -LiteralPath $topSource -PathType Leaf)) {
    throw "Expected elaboration top is missing: $topSource"
}

if ($KeepVvp -and [string]::IsNullOrWhiteSpace($VvpPath)) {
    throw '-KeepVvp requires an explicit -VvpPath so retained output has a bounded, reviewable destination.'
}

$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('c1_iverilog_rtl_compile_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$sourceList = Join-Path $runRoot 'rtl_sources.f'
$temporaryVvp = Join-Path $runRoot 'c1_r1_portable_soc.vvp'

try {
    # One source per line makes the invocation deterministic and avoids the
    # Windows command-line length limit.  Quote only paths that need it.
    $sourceLines = @($orderedSources | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    })
    [System.IO.File]::WriteAllLines($sourceList, [string[]]$sourceLines, [System.Text.Encoding]::ASCII)

    Write-Output 'C1_IVERILOG_RTL_COMPILE_BEGIN'
    Write-Output ("iverilog={0}" -f $iverilog)
    $version = Invoke-Native $iverilog @('-V')
    if ($version.ExitCode -ne 0) { throw "iverilog -V failed: $($version.Lines -join ' | ')" }
    Write-Output ("version={0}" -f (($version.Lines | Select-Object -First 1) -join ''))
    Write-Output ("sources={0} top=c1_r1_portable_soc" -f $orderedSources.Count)
    Write-Output 'standard=-g2012 defines=<none> includes=<none>'

    $arguments = @(
        '-g2012',
        '-s', 'c1_r1_portable_soc',
        '-o', $temporaryVvp,
        '-f', $sourceList
    )
    if ($QueuedWriteFabric) {
        $arguments += @('-Pc1_r1_portable_soc.FABRIC_WRITE_FIFO_DEPTH=4',
                        '-Pc1_r1_portable_soc.FABRIC_WRITE_W_AHEAD_OF_B=1',
                        '-Pc1_r1_portable_soc.FABRIC_WRITE_EMPTY_AW_BYPASS=1',
                        '-Pc1_r1_portable_soc.ENABLE_SHARED_QOS_MONITOR=1')
    }
    Write-Output ("queued_write_fabric={0}" -f [bool]$QueuedWriteFabric)
    $result = Invoke-Native $iverilog $arguments
    $warningLines = @($result.Lines | Where-Object { $_ -match '(?i)(warning:|sorry:)' })
    $errorLines = @($result.Lines | Where-Object { $_ -match '(?i)(error:|syntax error|I give up)' })
    Write-Output ("exit_code={0} warnings={1} errors={2}" -f $result.ExitCode, $warningLines.Count, $errorLines.Count)

    if ($result.ExitCode -ne 0) {
        $failureLines = @($errorLines | Select-Object -First 12)
        if ($failureLines.Count -eq 0) {
            $failureLines = @($result.Lines | Select-Object -First 12)
        }
        throw ("Icarus full RTL compile failed:`n" + ($failureLines -join "`n"))
    }
    if (-not (Test-Path -LiteralPath $temporaryVvp -PathType Leaf)) {
        throw "Icarus returned success but did not create the VVP image: $temporaryVvp"
    }

    if ($WarningSampleCount -gt 0 -and $warningLines.Count -gt 0) {
        foreach ($line in @($warningLines | Select-Object -First $WarningSampleCount)) {
            Write-Output ("warning_sample={0}" -f $line)
        }
    }

    if ($KeepVvp) {
        $destination = [IO.Path]::GetFullPath($VvpPath)
        $destinationParent = Split-Path -Parent $destination
        if ([string]::IsNullOrWhiteSpace($destinationParent)) {
            throw "Unable to determine parent directory for -VvpPath: $VvpPath"
        }
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $temporaryVvp -Destination $destination -Force
        Write-Output ("VVP_KEPT path={0} bytes={1}" -f $destination, (Get-Item -LiteralPath $destination).Length)
    }
    Write-Output 'C1_IVERILOG_RTL_COMPILE_PASS'
}
finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
