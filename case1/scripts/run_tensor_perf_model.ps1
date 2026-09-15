param(
    [string]$Python = 'D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Python interpreter not found: $Python"
}

Push-Location $caseRoot
try {
    & $Python '.\model\test_tensor_perf_model.py'
    if ($LASTEXITCODE -ne 0) {
        throw 'tensor performance model regression failed'
    }
} finally {
    Pop-Location
}

Write-Output 'C1_TENSOR_PERF_MODEL_REGRESSION_PASS'
