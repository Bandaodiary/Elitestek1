param([string]$DestinationName = 'Elitestek1-20260915')
$ErrorActionPreference = 'Stop'
if ($DestinationName -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid destination name' }
$caseRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$publishRoot = Join-Path $caseRoot 'publish'
$destination = [IO.Path]::GetFullPath((Join-Path $publishRoot $DestinationName))
if (-not $destination.StartsWith($publishRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid publication destination' }
if (Test-Path -LiteralPath $destination) { throw 'Refusing to overwrite an existing publication' }
$files = [System.Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$extensions = @('.sv','.v','.svh','.vh','.py','.ps1','.tcl','.sdc','.xml','.c','.h','.s','.ld','.md','.json','.txt','.yml','.yaml','.f','.cfg','.ini','.toml')
$deniedPart = '(^|/)(?:\.[^/]+|__pycache__|build|logs|tmp|work[^/]*|outflow|output|generated|node_modules|local_only|.*_runs|.*_run_[^/]*|xsim[^/]*)(/|$)'
function Add-Source([IO.FileInfo]$File) {
    $relative = $File.FullName.Substring($caseRoot.Length+1).Replace('\','/')
    if ($relative -match $deniedPart) { return }
    if ($File.Extension.ToLowerInvariant() -notin $extensions -and $File.Name -ne 'Makefile') { return }
    if ($File.Length -gt 1MB) { throw "Unexpected source over 1 MiB: $relative" }
    if ($File.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refuse reparse-point source: $relative" }
    $files[$relative] = $File
}
foreach ($name in @('rtl','golden','scripts','tb','tests','software','model','review','report')) {
    Get-ChildItem -LiteralPath (Join-Path $caseRoot $name) -Recurse -File | ForEach-Object { Add-Source $_ }
}
# Authored simulation and Efinity sources are directly in these folders.
# Never recurse into generated simulator/IP trees, even if they contain .v/.sv.
foreach ($name in @('sim','efinity')) {
    Get-ChildItem -LiteralPath (Join-Path $caseRoot $name) -File | ForEach-Object { Add-Source $_ }
}
Get-ChildItem -LiteralPath $caseRoot -File -Filter '*.md' | ForEach-Object { Add-Source $_ }
Add-Source (Get-Item -LiteralPath (Join-Path $caseRoot 'PUBLICATION_GITIGNORE.txt'))
$models = @('c36_qat_b_starry_equalized_20260915a','c36_qat_b_mosaic_equalized_20260915a','c36_qat_b_mosaic_stable_20260915a')
foreach ($model in $models) {
    $folder = Join-Path $caseRoot "outputs/$model"
    foreach ($name in @('training_config.json','status.json','checkpoint_best.pt')) {
        $f = Get-Item -LiteralPath (Join-Path $folder $name)
        if ($f.Length -gt 1MB) { throw "Unexpected model input size: $($f.Name)" }
        $files["outputs/$model/$name"] = $f
    }
    foreach ($part in @('artifact','plan_fused','plan_unfused')) {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $folder $part) -File) {
            if ($f.Extension -notin @('.json','.sv','.bin')) { continue }
            if ($f.Length -gt 1MB) { throw "Unexpected model input size: $($f.Name)" }
            $files["outputs/$model/$part/$($f.Name)"] = $f
        }
    }
}
# Secret/IP scan only the selected small text sources; do not print matched data.
$restricted = '(?i)(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)'
foreach ($pair in $files.GetEnumerator()) {
    if ($pair.Value.Extension -in @('.bin','.pt')) { continue }
    $selectedText = [IO.File]::ReadAllText($pair.Value.FullName)
    if ($selectedText -match $restricted) { throw "Restricted material requires review: $($pair.Key)" }
    if ($pair.Value.Extension -in @('.v','.sv','.vh','.svh') -and $selectedText -match '(?im)^\s*`pragma\s+protect\s+begin_protected') { throw "Protected RTL requires review: $($pair.Key)" }
}
New-Item -ItemType Directory -Path $destination | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$entries = [System.Collections.Generic.List[object]]::new()
foreach ($pair in $files.GetEnumerator()) {
    $target = Join-Path $destination ('case1/' + $pair.Key)
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath $pair.Value.FullName -Destination $target
    if ($pair.Key -match '^efinity/[^/]+\.xml$') {
        $t = [IO.File]::ReadAllText($target)
        # A relocatable token avoids silently compiling the original workspace.
        $t = $t.Replace($caseRoot.Replace('\','/'),'@CASE1_ROOT@').Replace($caseRoot,'@CASE1_ROOT@')
        [IO.File]::WriteAllText($target,$t,$utf8)
    }
    $entries.Add([pscustomobject][ordered]@{ path=('case1/' + $pair.Key); bytes=(Get-Item -LiteralPath $target).Length })
}
foreach ($mapping in @(
    @('PUBLICATION_README.md','README.md'),
    @('PUBLICATION_GITIGNORE.txt','.gitignore'),
    @('THIRD_PARTY_NOTICES.md','THIRD_PARTY_NOTICES.md')
)) {
    Copy-Item -LiteralPath (Join-Path $caseRoot $mapping[0]) -Destination (Join-Path $destination $mapping[1])
}
$manifest = [ordered]@{
    scope='case1 authored sources and selected deployment inputs only'
    as_of='2026-09-15'
    git_history_copied=$false
    xilinx_generated_files_included=$false
    vendor_generated_ip_included=$false
    historical_tool_logs_included=$false
    xml_source_root_token='@CASE1_ROOT@'
    selected_models=$models
    source_file_count=$entries.Count
    source_bytes=($entries | Measure-Object bytes -Sum).Sum
    files=$entries
}
[IO.File]::WriteAllText((Join-Path $destination 'PUBLICATION_MANIFEST.json'),($manifest | ConvertTo-Json -Depth 6),$utf8)
Write-Output "PUBLICATION_EXPORT_PASS files=$($entries.Count) bytes=$($manifest.source_bytes) destination=$destination"
Write-Output 'No existing repository, original source, vendor installation, or other contest case was modified.'
