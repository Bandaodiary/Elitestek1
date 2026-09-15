$ErrorActionPreference = 'Stop'

$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = Join-Path $caseRoot 'software\build'
$includeRoot = Join-Path $caseRoot 'software\include'
$sourceRoot = Join-Path $caseRoot 'software\src'
$testRoot = Join-Path $caseRoot 'software\test'
$gccCandidates = @(
    'D:\vivado\vivado\Vivado\2023.1\tps\mingw\9.3.0\win64.o\nt\bin\gcc.exe',
    'D:\vivado\vivado\Vivado\2023.1\tps\mingw\8.3.0\win64.o\nt\bin\gcc.exe',
    'D:\vivado\vivado\Vivado\2023.1\tps\mingw\6.2.0\win64.o\nt\bin\gcc.exe'
)
$gcc = $gccCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $gcc) {
    throw 'No bundled MinGW GCC was found under the installed Vivado tree'
}

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
$executable = Join-Path $buildRoot 'test_c1_accel_host.exe'
$compileArguments = @(
    '-std=c11', '-Wall', '-Wextra', '-Werror',
    "-I$includeRoot",
    (Join-Path $sourceRoot 'c1_accel.c'),
    (Join-Path $testRoot 'test_c1_accel_host.c'),
    '-o', $executable
)
& $gcc @compileArguments
if ($LASTEXITCODE -ne 0) {
    throw "host software compile failed with exit code $LASTEXITCODE"
}
$output = & $executable
if ($LASTEXITCODE -ne 0) {
    throw "host software test failed with exit code $LASTEXITCODE"
}
if (($output | Select-String -SimpleMatch 'C1_SOFTWARE_HOST_TEST_PASS').Count -ne 1) {
    throw 'host software test did not emit exactly one PASS marker'
}
$output

