<#
Launch the Efinity RISC-V Embedded Software IDE with a dedicated workspace.

This helper is intentionally limited to the GUI launcher.  It does not call
the interactive IDE setup.bat (which asks for a FreeRTOS directory), does not
start Efinity map/pnr, and does not run OpenOCD.  Keeping the workspace outside
case1/ prevents Eclipse indexes and build products from being mixed with RTL.
#>
[CmdletBinding()]
param(
    [string]$RiscvHome = 'D:\ELS\efinity-riscv-ide-2026.1',
    [string]$Workspace = 'D:\contest\2026FPGA\efinity_workspace',
    [switch]$Wait
)

$ErrorActionPreference = 'Stop'
$ideRoot = Join-Path $RiscvHome 'Efinity-RISCV-IDE'
$ideExe = Join-Path $ideRoot 'efinity-riscv-ide.exe'
if (-not (Test-Path -LiteralPath $ideExe -PathType Leaf)) {
    throw "RISC-V IDE executable not found: $ideExe"
}

if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
}

# These variables are the non-interactive part of the IDE environment.  They
# are inherited by the IDE and by projects launched from it, but do not alter
# the caller after this script exits.
$env:BSP = 'efinix/EfxSapphireSoC'
$env:RISCV_TOOLS_HOME = $RiscvHome
$toolDirs = @(
    (Join-Path $RiscvHome 'toolchain\bin'),
    (Join-Path $RiscvHome 'build_tools\bin'),
    (Join-Path $RiscvHome 'openocd\bin')
)
foreach ($dir in $toolDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "RISC-V tool directory not found: $dir"
    }
}
$env:PATH = (($toolDirs -join ';') + ';' + $env:PATH)

# Eclipse accepts -data as the workspace selector.  Quote the path explicitly
# so a future workspace containing spaces remains valid.
$argList = '-data "{0}"' -f $Workspace
$proc = Start-Process -FilePath $ideExe -ArgumentList $argList `
    -WorkingDirectory $ideRoot -WindowStyle Normal -PassThru
Write-Output ("EFINITY_RISCV_IDE_LAUNCH_PASS pid={0} workspace={1}" -f $proc.Id, $Workspace)

if ($Wait) {
    Wait-Process -Id $proc.Id
}
