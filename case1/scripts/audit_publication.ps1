param([string]$Repository, [switch]$UpdateManifest)
$ErrorActionPreference = 'Stop'
if (-not $Repository) { $Repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$repo = (Resolve-Path -LiteralPath $Repository).Path
$manifestPath = Join-Path $repo 'PUBLICATION_MANIFEST.json'
if (-not(Test-Path -LiteralPath $manifestPath)) { throw 'Not an isolated publication' }
$rootFiles = @('.gitignore','README.md','THIRD_PARTY_NOTICES.md','PUBLICATION_MANIFEST.json')
foreach ($entry in Get-ChildItem -LiteralPath $repo -Force) {
    if ($entry.Name -in @('case1','.git')) { continue }
    if ($entry.Name -notin $rootFiles) { throw "Unexpected root entry: $($entry.Name)" }
}
$allowedExt = @('.sv','.v','.svh','.vh','.py','.ps1','.tcl','.sdc','.xml','.c','.h','.s','.ld','.md','.json','.txt','.yml','.yaml','.f','.cfg','.ini','.toml')
$caseRoot = Join-Path $repo 'case1'
$files = @(Get-ChildItem -LiteralPath $caseRoot -File -Recurse)
$total = 0L
$entries = [System.Collections.Generic.List[object]]::new()
foreach ($f in $files | Sort-Object FullName) {
    $p = $f.FullName.Substring($repo.Length+1).Replace('\','/')
    if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $p" }
    if ($p -match '(?i)(^|/)(?:\.[^/]+|logs|tmp|__pycache__|build|work[^/]*|outflow|generated|assets|vectors|local_only|xsim[^/]*|.*_runs|c39_cpu_[^/]+)/') { throw "Forbidden generated/local path: $p" }
    $modelBinary = $p -match '^case1/outputs/c36_qat_b_(?:starry_equalized|mosaic_equalized|mosaic_stable)_20260915a/(?:checkpoint_best\.pt|(?:artifact|plan_unfused)/[A-Za-z0-9_]+\.bin)$'
    if ($f.Extension.ToLowerInvariant() -notin $allowedExt -and $f.Name -ne 'Makefile' -and -not $modelBinary) { throw "Forbidden file type: $p" }
    if ($f.Length -gt 1MB) { throw "File exceeds source publication limit: $p" }
    if (-not $modelBinary) {
        $text = [IO.File]::ReadAllText($f.FullName)
        if ($text -match '(?i)(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)') { throw "Potential credential: $p" }
        if ($f.Extension -in @('.v','.sv','.vh','.svh') -and $text -match '(?im)^\s*`pragma\s+protect\s+begin_protected') { throw "Protected IP: $p" }
    }
    $total += $f.Length
    $entries.Add([pscustomobject][ordered]@{path=$p; bytes=$f.Length})
}
if ($UpdateManifest) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.source_file_count = $entries.Count
    $manifest.source_bytes = $total
    $manifest.files = @($entries.ToArray())
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
}
Write-Output "PUBLICATION_AUDIT_PASS case1_files=$($files.Count) source_bytes=$total other_cases=0 generated_eda_files=0 protected_payloads=0"
