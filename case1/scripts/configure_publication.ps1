param([switch]$CheckOnly, [switch]$Portable)
$ErrorActionPreference = 'Stop'
$caseRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $caseRoot
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'PUBLICATION_MANIFEST.json'))) {
    throw 'Only run this helper in the isolated publication, not the original workspace.'
}
$token = '@CASE1_ROOT@'
$caseUnix = $caseRoot.Replace('\','/')
$utf8 = [Text.UTF8Encoding]::new($false)
$changed = 0
if ($CheckOnly -and $Portable) { throw 'CheckOnly and Portable are mutually exclusive' }
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $caseRoot 'efinity') -File -Filter '*.xml') {
    $content = [IO.File]::ReadAllText($f.FullName)
    if ($Portable) {
        $portableText = $content.Replace($caseUnix,$token).Replace($caseRoot,$token)
        if ($portableText -ne $content) { [IO.File]::WriteAllText($f.FullName,$portableText,$utf8); $changed++ }
        continue
    }
    if ($content.Contains($token)) {
        if ($CheckOnly) { throw "Unconfigured XML: $($f.Name). Run without -CheckOnly first." }
        # Mechanical relocation only; preserve serialization used by source-contract tests.
        [IO.File]::WriteAllText($f.FullName, $content.Replace($token,$caseUnix), $utf8)
        $changed++
    }
}
if ($Portable) {
    Write-Output "PUBLICATION_PORTABLE_PASS changed_xml=$changed configure_before_compile=True"
    return
}
$project = Join-Path $caseRoot 'efinity/c1_ti60_c40_host_100.xml'
[xml]$xml = Get-Content -LiteralPath $project -Raw -Encoding UTF8
$nodes = @($xml.SelectNodes('//*[local-name()="design_file"]'))
if ($nodes.Count -ne 50) { throw "Expected 49 production sources plus top; found $($nodes.Count)" }
$resolved = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($node in $nodes) {
    $p = [string]$node.name
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path (Split-Path $project) $p }
    $p = [IO.Path]::GetFullPath($p)
    if (-not $p.StartsWith($caseRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw "Source outside publication: $p" }
    if (-not(Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing source: $p" }
    if (-not $resolved.Add($p)) { throw "Duplicate source: $p" }
}
foreach ($node in $xml.SelectNodes('//*[local-name()="sdc_file"]')) {
    $p = [string]$node.name
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path (Split-Path $project) $p }
    if (-not(Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing SDC: $p" }
}
Write-Output "PUBLICATION_CONFIG_PASS changed_xml=$changed design_sources=$($nodes.Count) vendor_joint_ready=False"
