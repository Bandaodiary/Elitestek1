param(
    [Parameter(Mandatory=$true)][string]$Mode,
    [Parameter(Mandatory=$true)][string]$OutPath,
    [Parameter(Mandatory=$true)][string]$ErrPath,
    [Parameter(Mandatory=$true)][string]$WorkDir,
    [string]$UserDataRoot = ''
)
$ErrorActionPreference = 'Stop'
$vivadoRoot = 'D:\vivado\vivado\Vivado\2023.1'
$bin = Join-Path $vivadoRoot 'bin'
$bat = Join-Path $bin 'vivado.bat'
$loader = Join-Path $bin 'loader.bat'
$exe = Join-Path $bin 'unwrapped\win64.o\vivado.exe'
$tcl = Join-Path (Split-Path -Parent $PSCommandPath) 'vivado_runtime_probe.tcl'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
if (-not [string]::IsNullOrWhiteSpace($UserDataRoot)) {
    New-Item -ItemType Directory -Force -Path $UserDataRoot | Out-Null
    # Vivado 2023.1 otherwise derives a one-character Tcl-store path ('C')
    # from the drive-qualified Windows profile in this environment.  Keep the
    # probe's store private and writable; this setting is inherited by cmd and
    # by any synthesis helper child.
    $env:XILINX_LOCAL_USER_DATA = $UserDataRoot
    $env:XILINX_TCL_STORE = $UserDataRoot
}

# Keep this probe self-contained and close to the production launch path.  The
# loader mode exercises Vivado's own environment setup without the outer
# vivado.bat wrapper; the exe mode additionally bypasses loader.bat while
# retaining the minimal variables needed by the executable.
$cmd = switch ($Mode) {
    'bat' {
        'call "' + $bat + '" -mode batch -nolog -nojournal -notrace -source "' + $tcl + '"'
    }
    'loader' {
        'call "' + $loader + '" -exec vivado -mode batch -nolog -nojournal -notrace -source "' + $tcl + '"'
    }
    'exe' {
        'set RDI_APPROOT=' + ($vivadoRoot -replace '\\','/') + '&& ' +
        'set RDI_BINROOT=' + (($bin) -replace '\\','/') + '&& ' +
        'set XILINX_VIVADO=' + ($vivadoRoot -replace '\\','/') + '&& ' +
        'set RT_LIBPATH=' + (($vivadoRoot + '\scripts\rt\data') -replace '\\','/') + '&& ' +
        'set SYNTH_COMMON=' + (($vivadoRoot + '\scripts\rt\data') -replace '\\','/') + '&& ' +
        'set RT_TCL_PATH=' + (($vivadoRoot + '\scripts\rt\base_tcl\tcl') -replace '\\','/') + '&& ' +
        'set RDI_DATADIR=' + (($vivadoRoot + '\data') -replace '\\','/') + '&& ' +
        'set PATH=' + $bin + ';%PATH%&& "' + $exe + '" -mode batch -nolog -nojournal -notrace -source "' + $tcl + '"'
    }
    default { throw "unknown probe mode: $Mode" }
}
$full = '"' + (Join-Path $env:SystemRoot 'System32\cmd.exe') + '" /d /s /c "' + $cmd + '"'
$p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/d','/s','/c',$cmd) -WorkingDirectory $WorkDir -WindowStyle Hidden -RedirectStandardOutput $OutPath -RedirectStandardError $ErrPath -Wait -PassThru
exit $p.ExitCode
