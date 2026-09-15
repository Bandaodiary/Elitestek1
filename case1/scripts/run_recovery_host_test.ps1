$ErrorActionPreference='Stop'
$caseRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$gcc=@('9.3.0','8.3.0','6.2.0') | ForEach-Object {
    "D:\vivado\vivado\Vivado\2023.1\tps\mingw\$_\win64.o\nt\bin\gcc.exe"
} | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if(!$gcc){throw 'Bundled host GCC not found'}
$exe=Join-Path $env:TEMP ('c1_recovery_host_'+[guid]::NewGuid().ToString('N')+'.exe')
try {
    & $gcc '-std=c11' '-Wall' '-Wextra' '-Werror' ("-I"+(Join-Path $caseRoot 'software/include')) `
        (Join-Path $caseRoot 'software/src/c1_recovery.c') `
        (Join-Path $caseRoot 'software/test/test_c1_recovery_host.c') '-o' $exe
    if($LASTEXITCODE -ne 0){throw 'Recovery host compile failed'}
    $result=& $exe
    if($LASTEXITCODE -ne 0 -or @($result | Where-Object {$_ -match '^C1_RECOVERY_HOST_PASS '}).Count -ne 1){
        throw 'Recovery host test failed'
    }
    $result
} finally {
    if(Test-Path -LiteralPath $exe){Remove-Item -LiteralPath $exe}
}
