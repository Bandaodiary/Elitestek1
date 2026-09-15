[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Python)
$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$referenceRoot = Join-Path $caseRoot 'vectors\microstyle_engine_bitexact_8x8'
$artifact = Join-Path $caseRoot 'model\microstyle24_starry_functional'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('c1_golden_check_' + [guid]::NewGuid().ToString('N'))
$files = @('descriptors.mem','parameter_arena.mem','engine_vectors.mem',
           'expected_outputs.mem','stage_meta.mem')
try {
    & $Python (Join-Path $caseRoot 'golden\generate_microstyle_engine_bitexact_vectors.py') `
        --artifact $artifact --output-dir $scratch --width 8 --height 8
    if ($LASTEXITCODE -ne 0) { throw 'Integer golden generation failed' }
    $records = 0
    foreach ($file in $files) {
        # Compare actual records, not timestamps or digests. Read only the
        # five small stimulus files, never simulation output trees.
        $expected = [IO.File]::ReadAllLines((Join-Path $referenceRoot $file))
        $actual = [IO.File]::ReadAllLines((Join-Path $scratch $file))
        if ($expected.Length -ne $actual.Length) { throw "$file record count mismatch" }
        for ($i=0; $i -lt $actual.Length; $i++) {
            if ($expected[$i].Trim() -cne $actual[$i].Trim()) {
                throw "$file differs at record $i"
            }
        }
        $records += $actual.Length
        Write-Output "C1_GOLDEN_FILE_MATCH file=$file records=$($actual.Length)"
    }
    Write-Output "C1_ENGINE_GOLDEN_REGEN_PASS files=$($files.Count) records=$records width=8 height=8"
} finally {
    # Delete only known outputs from this invocation; no broad recursive
    # cleanup and no changes to the saved artifact or reference vectors.
    foreach ($file in ($files + @('engine_vector_manifest.json'))) {
        $path = Join-Path $scratch $file
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path }
    }
    if ((Test-Path -LiteralPath $scratch) -and
        @(Get-ChildItem -LiteralPath $scratch -Force).Count -eq 0) {
        Remove-Item -LiteralPath $scratch
    }
}
