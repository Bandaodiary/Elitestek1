<##
.SYNOPSIS
  Run a bounded Icarus/GTKWave interoperability smoke.

.DESCRIPTION
  The default test is a tiny Verilog-2005 DUT and emits a small VCD only in a
  disposable directory under %TEMP%.  A SystemVerilog syntax probe is also
  attempted.  Use -TrySapphireAdapter only after a current Icarus reports a
  working SystemVerilog flag; that option compiles and runs the existing
  boardless Soft Sapphire APB/IRQ adapter seam.  No Efinity map/P&R, Vivado,
  xsim or IP generation is invoked.

  The script deliberately does not leave simulator work trees in case1/sim.
  With -KeepVcd the small smoke waveform is copied to an explicitly bounded
  output path; otherwise it is removed with the temporary directory.
##>
[CmdletBinding()]
param(
    [string]$IcarusHome = 'D:\iverilog',
    [switch]$TrySapphireAdapter,
    [switch]$RequireSystemVerilog,
    [switch]$KeepVcd,
    [string]$VcdPath = '',
    [switch]$OpenGtkWave
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$simRoot = Join-Path $caseRoot 'sim'
if ($OpenGtkWave -and -not $KeepVcd) {
    throw '-OpenGtkWave requires -KeepVcd so the viewer receives an explicit retained waveform.'
}

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
}

$iverilog = Resolve-Tool $IcarusHome 'iverilog'
$vvp = Resolve-Tool $IcarusHome 'vvp'
# Some Windows packages keep GTK/MinGW DLLs beside the executables and rely on
# PATH for dependent DLL lookup.  Prepend that exact bin directory for this
# child PowerShell only; do not modify the user's persistent system PATH.
$iverilogBin = Split-Path -Parent $iverilog
if (($env:PATH -split ';') -notcontains $iverilogBin) {
    $env:PATH = $iverilogBin + ';' + $env:PATH
}
$gtkwave = $null
if ($OpenGtkWave) { $gtkwave = Resolve-Tool $IcarusHome 'gtkwave' }

$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('c1_iverilog_smoke_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$plainVvp = Join-Path $runRoot 'c1_iverilog_compat.vvp'
$svVvp = Join-Path $runRoot 'c1_iverilog_sv_probe.vvp'
$adapterVvp = Join-Path $runRoot 'c1_sapphire_apb_adapter.vvp'
$plainSources = @(
    (Join-Path $simRoot 'c1_iverilog_compat_dut.v'),
    (Join-Path $simRoot 'tb_c1_iverilog_compat.v')
)
$svProbe = Join-Path $simRoot 'c1_iverilog_sv_probe.sv'
$adapterSources = @(
    (Join-Path $caseRoot 'rtl\vendor\c1_sapphire_apb_master_adapter.sv'),
    (Join-Path $caseRoot 'rtl\vendor\c1_sapphire_irq_adapter.sv'),
    (Join-Path $simRoot 'tb_c1_sapphire_apb_master_adapter.sv')
)
$locationPushed = $false

try {
    Write-Output 'C1_IVERILOG_SMOKE_BEGIN'
    Write-Output ("iverilog={0}" -f $iverilog)
    $version = Invoke-Native $iverilog @('-V')
    if ($version.ExitCode -ne 0) { throw "iverilog -V failed: $($version.Lines -join ' | ')" }
    Write-Output ("version={0}" -f (($version.Lines | Select-Object -First 1) -join ''))

    Push-Location $runRoot
    $locationPushed = $true
    $plainArgs = @('-g2005', '-s', 'tb_c1_iverilog_compat', '-o', $plainVvp) + $plainSources
    $plain = Invoke-Native $iverilog $plainArgs
    if ($plain.ExitCode -ne 0) {
        throw "Verilog-2005 compile failed: $($plain.Lines -join ' | ')"
    }
    Assert-Marker (Invoke-Native $vvp @($plainVvp)) 'C1_IVERILOG_VERILOG2005_PASS' 'Verilog-2005 simulation'
    Write-Output 'C1_IVERILOG_VERILOG2005_PASS'

    $svFlag = $null
    foreach ($candidate in @('-g2012', '-g2005-sv', '-gsystem-verilog')) {
        $probeArgs = @($candidate, '-s', 'c1_iverilog_sv_probe', '-o', $svVvp, $svProbe)
        $probe = Invoke-Native $iverilog $probeArgs
        if ($probe.ExitCode -eq 0) {
            $svFlag = $candidate
            break
        }
    }
    if ($svFlag) {
        Write-Output ("C1_IVERILOG_SYSTEMVERILOG_PASS flag={0}" -f $svFlag)
    } else {
        Write-Output 'C1_IVERILOG_SYSTEMVERILOG_UNAVAILABLE'
        if ($RequireSystemVerilog -or $TrySapphireAdapter) {
            throw 'Current Icarus cannot elaborate the SystemVerilog probe; install a current build or omit -TrySapphireAdapter.'
        }
    }

    if ($TrySapphireAdapter) {
        $adapterArgs = @($svFlag, '-s', 'tb_c1_sapphire_apb_master_adapter', '-o', $adapterVvp) + $adapterSources
        $adapter = Invoke-Native $iverilog $adapterArgs
        if ($adapter.ExitCode -ne 0) {
            throw "Sapphire APB adapter compile failed: $($adapter.Lines -join ' | ')"
        }
        $adapterRun = Invoke-Native $vvp @($adapterVvp)
        Assert-Marker $adapterRun 'C1_SAPPHIRE_APB_ADAPTER_PASS' 'Sapphire APB/IRQ adapter simulation'
        Write-Output 'C1_SAPPHIRE_APB_ADAPTER_PASS'
    }

    $generatedVcd = Join-Path $runRoot 'c1_iverilog_compat.vcd'
    if (-not (Test-Path -LiteralPath $generatedVcd -PathType Leaf)) {
        throw "Expected bounded VCD was not generated: $generatedVcd"
    }
    if ($KeepVcd) {
        if ([string]::IsNullOrWhiteSpace($VcdPath)) {
            $VcdPath = Join-Path $caseRoot ('outputs\local_only\c1_iverilog_compat_' + [guid]::NewGuid().ToString('N') + '.vcd')
        }
        $vcdParent = Split-Path -Parent $VcdPath
        New-Item -ItemType Directory -Path $vcdParent -Force | Out-Null
        Copy-Item -LiteralPath $generatedVcd -Destination $VcdPath -Force
        Write-Output ("VCD_KEPT path={0} bytes={1}" -f $VcdPath, (Get-Item -LiteralPath $VcdPath).Length)
        if ($OpenGtkWave) {
            Start-Process -FilePath $gtkwave -ArgumentList @($VcdPath) -WorkingDirectory $vcdParent | Out-Null
            Write-Output 'GTKWAVE_STARTED'
        }
    }
    Write-Output 'C1_IVERILOG_SMOKE_PASS'
} finally {
    if ($locationPushed) { Pop-Location -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
