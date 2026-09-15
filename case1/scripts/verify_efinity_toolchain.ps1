<##
.SYNOPSIS
  Verify the locally installed Efinity and Efinity RISC-V toolchain.

.DESCRIPTION
  This is a boardless, bounded check.  It does not invoke Vivado, Efinity
  map/place-and-route, IP Manager, or a programmer.  With -BuildSmoke it
  builds the small case1/software/efinity_smoke project only.

  The script deliberately prepends tool directories to the current PowerShell
  process instead of calling the interactive Efinity setup script.  This
  keeps the caller's environment unchanged and avoids setup.bat prompts.
##>
[CmdletBinding()]
param(
    [string]$EfinityHome = 'D:\ELS\Efinity\2026.1',
    [string]$RiscvHome = 'D:\ELS\efinity-riscv-ide-2026.1',
    [switch]$BuildSmoke,
    [switch]$CleanSmokeAfter
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$smokeRoot = Join-Path $caseRoot 'software\efinity_smoke'

function Require-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("Missing {0}: {1}" -f $Label, $Path)
    }
}

Require-File (Join-Path $EfinityHome 'bin\efx_run.bat') 'Efinity CLI launcher'
Require-File (Join-Path $EfinityHome 'scripts\efx_run.py') 'Efinity Python runner'
Require-File (Join-Path $EfinityHome 'python311\bin\python.exe') 'Efinity Python runtime'
Require-File (Join-Path $RiscvHome 'Efinity-RISCV-IDE\efinity-riscv-ide.exe') 'RISC-V IDE'

$toolDirs = @(
    (Join-Path $RiscvHome 'toolchain\bin'),
    (Join-Path $RiscvHome 'build_tools\bin'),
    (Join-Path $RiscvHome 'openocd\bin')
)
foreach ($dir in $toolDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Missing tool directory: $dir"
    }
}
$env:PATH = (($toolDirs -join ';') + ';' + $env:PATH)

function Invoke-Checked([string]$Name, [string[]]$Arguments) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Command not found after PATH setup: $Name"
    }
    # Some Efinity utilities (notably OpenOCD) intentionally print their
    # version to stderr.  Capture it as data without letting PowerShell's
    # native-command error preference abort the verification.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& $command.Source @Arguments 2>&1)
    $ErrorActionPreference = $savedPreference
    $exitCode = $LASTEXITCODE
    $first = ($output | Select-Object -First 2) -join ' | '
    if ($exitCode -ne 0) {
        throw ("{0} failed with exit code {1}: {2}" -f $Name, $exitCode, $first)
    }
    Write-Output ("{0}: {1}" -f $Name, $first)
}

Write-Output 'EFINITY_TOOLCHAIN_CHECK_BEGIN'
Write-Output ("EfinityHome={0}" -f $EfinityHome)
Write-Output ("RiscvHome={0}" -f $RiscvHome)
Invoke-Checked 'riscv-none-elf-gcc' @('--version')
Invoke-Checked 'riscv-none-elf-objcopy' @('--version')
Invoke-Checked 'riscv-none-elf-gdb' @('--version')
Invoke-Checked 'openocd' @('--version')
Invoke-Checked 'make' @('--version')
Require-File (Join-Path $RiscvHome 'qemu\qemu-system-riscv32.exe') 'QEMU RV32'
Invoke-Checked (Join-Path $RiscvHome 'qemu\qemu-system-riscv32.exe') @('--version')

# efx_run.bat is a cmd wrapper.  Reproduce the non-interactive part of
# setup.bat in a child cmd instead of calling setup.bat itself: the installed
# setup script invokes a profile-enabled `powershell -Command` for an ASCII
# path check, which can print an unrelated local conda/profile traceback.
# Nothing here changes the caller's environment.
$efxRun = Join-Path $EfinityHome 'bin\efx_run.bat'
$efUnix = $EfinityHome -replace '\\', '/'
$pythonHome = Join-Path $EfinityHome 'python311'
$localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA -replace '\\', '/' } else { '' }
$childSets = @(
    ('set "EFINITY_HOME={0}"' -f $efUnix),
    ('set "EFXPT_HOME={0}/pt"' -f $efUnix),
    ('set "EFXPGM_HOME={0}/pgm"' -f $efUnix),
    ('set "EFXDBG_HOME={0}/debugger"' -f $efUnix),
    ('set "EFXIPM_HOME={0}/ipm"' -f $efUnix),
    ('set "EFXSVF_HOME={0}/debugger/svf_player"' -f $efUnix),
    ('set "EFXSERDESDBG_HOME={0}/debugger/serdes_debug_tool"' -f $efUnix),
    ('set "EFINITY_USER_DIR_INI={0}/efinity/user_dir.ini"' -f $localAppData),
    ('set "PYTHONHOME={0}"' -f $pythonHome),
    ('set "PATH={0};{1};{2};{3};{4};{5};%PATH%"' -f `
        (Join-Path $EfinityHome 'python311\bin'),
        (Join-Path $EfinityHome 'bin'),
        (Join-Path $EfinityHome 'pgm\bin'),
        (Join-Path $EfinityHome 'debugger\bin'),
        (Join-Path $EfinityHome 'scripts'),
        (Join-Path $EfinityHome 'ipm\bin\ip_packager')),
    ('set "QT_PLUGIN_PATH={0}/bin"' -f $efUnix),
    ('set "QT_QPA_PLATFORM_PLUGIN_PATH={0}/python311/platforms"' -f $efUnix),
    ('set "QT_LOGGING_CONF={0}/bin/lc.ini"' -f $efUnix)
)
$cmdLine = (($childSets + ('"{0}" --help' -f $efxRun)) -join ' && ')
$savedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$helpOutput = @(& cmd.exe /d /s /c $cmdLine 2>&1)
$helpExit = $LASTEXITCODE
$ErrorActionPreference = $savedPreference
if ($helpExit -ne 0) {
    throw ("efx_run.bat --help failed with exit code {0}" -f $helpExit)
}
$helpSummary = $helpOutput |
    Where-Object { $_.ToString() -notmatch 'profile.ps1 cannot be loaded|SecurityError|PSSecurityException' } |
    Select-Object -First 2
Write-Output ("efx_run.bat: {0}" -f (($helpSummary) -join ' | '))

if ($BuildSmoke) {
    if (-not (Test-Path -LiteralPath $smokeRoot -PathType Container)) {
        throw "Smoke project not found: $smokeRoot"
    }
    $make = (Get-Command make -ErrorAction Stop).Source
    & $make -C $smokeRoot clean all
    if ($LASTEXITCODE -ne 0) {
        throw "efinity_smoke make failed with exit code $LASTEXITCODE"
    }
    $artifacts = Get-ChildItem -LiteralPath (Join-Path $smokeRoot 'build') -File -ErrorAction Stop
    $bytes = ($artifacts | Measure-Object -Property Length -Sum).Sum
    Write-Output ("SMOKE_BUILD_PASS files={0} bytes={1}" -f $artifacts.Count, $bytes)
    if ($CleanSmokeAfter) {
        & $make -C $smokeRoot clean
        if ($LASTEXITCODE -ne 0) {
            throw "efinity_smoke clean failed with exit code $LASTEXITCODE"
        }
        Write-Output 'SMOKE_BUILD_CLEANED'
    }
}

Write-Output 'EFINITY_TOOLCHAIN_CHECK_PASS'
