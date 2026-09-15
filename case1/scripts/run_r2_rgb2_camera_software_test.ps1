$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot=Join-Path $caseRoot 'software\build'
$leaf='c31_rgb2_camera_'+[guid]::NewGuid().ToString('N')
$private=Join-Path $buildRoot $leaf
$gcc='D:\vivado\vivado\Vivado\2023.1\tps\mingw\9.3.0\win64.o\nt\bin\gcc.exe'
if(-not (Test-Path -LiteralPath $gcc)){throw 'Configured host GCC not found'}
New-Item -ItemType Directory -Path $private|Out-Null
try {
    $exe=Join-Path $private 'test.exe'
    & $gcc '-std=c11' '-Wall' '-Wextra' '-Werror' ('-I'+(Join-Path $caseRoot 'software\include')) (Join-Path $caseRoot 'software\src\c1_r2_rgb2_camera.c') (Join-Path $caseRoot 'software\test\test_c1_r2_rgb2_camera.c') '-o' $exe
    if($LASTEXITCODE -ne 0){throw 'Host C compile failed'}
    $result=& $exe
    if($LASTEXITCODE -ne 0 -or @($result|Where-Object {$_ -cmatch '^C31_RGB2_CAMERA_SOFTWARE_PASS '}).Count -ne 1){throw 'Host C test failed'}
    $result
    $riscvBin='D:\ELS\efinity-riscv-ide-2026.1\toolchain\bin'
    $object=Join-Path $private 'camera_rv32imc.o'
    & (Join-Path $riscvBin 'riscv-none-elf-gcc.exe') '-march=rv32imc' '-mabi=ilp32' '-ffreestanding' '-Os' '-std=c11' '-Wall' '-Wextra' '-Werror' ('-I'+(Join-Path $caseRoot 'software\include')) '-c' (Join-Path $caseRoot 'software\src\c1_r2_rgb2_camera.c') '-o' $object
    if($LASTEXITCODE -ne 0){throw 'Efinity RV32IMC compile failed'}
    $disassembly=& (Join-Path $riscvBin 'riscv-none-elf-objdump.exe') '-f' '-d' $object
    if($LASTEXITCODE -ne 0 -or ($disassembly -join "`n") -notmatch 'file format elf32-littleriscv' -or
       ($disassembly -join "`n") -notmatch '<c1_r2c2_info_read>' -or @($disassembly|Where-Object {$_ -match '\bfence\b'}).Count -lt 2){throw 'RV32IMC object/fence evidence missing'}
    'C31_RGB2_CAMERA_RISCV_COMPILE_PASS efinity_toolchain=1 isa=rv32imc abi=ilp32 elf32=1 mmio_fence=1 cpu_execution_claim=0'
} finally {
    $target=[IO.Path]::GetFullPath($private)
    if(-not $target.StartsWith([IO.Path]::GetFullPath($buildRoot).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $target) -ne $leaf){throw 'Unsafe private target'}
    Remove-Item -LiteralPath $target -Recurse -Force
}
'C31_RGB2_CAMERA_SOFTWARE_CLEAN temporary_executable_removed=1'
