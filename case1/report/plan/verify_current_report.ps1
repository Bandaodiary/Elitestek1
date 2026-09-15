param([string]$ReportRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$reportFile = Join-Path $ReportRoot 'chapters/赛题一_RTL架构设计与验证报告.md'
$body = Get-Content -LiteralPath $reportFile -Raw -Encoding UTF8
$failures = [System.Collections.Generic.List[string]]::new()
if ($body.Contains([char]0xfffd)) { $failures.Add('Invalid Unicode replacement') }
if ([regex]::Matches($body, '(?m)^# ').Count -ne 1) { $failures.Add('Expected one title') }
foreach ($n in 1..8) {
    if ([regex]::Matches($body, "(?m)^## $n ").Count -ne 1) { $failures.Add("Section $n missing/duplicated") }
}
if ([regex]::Matches($body, '(?m)^```').Count % 2) { $failures.Add('Unbalanced fence') }
$prose = ($body -split '(?m)^## (参考|资料|附录)', 2)[0]
$prose = [regex]::Replace($prose, '(?ms)^```.*?^```[^\r\n]*', '')
$prose = (($prose -split '\r?\n') | Where-Object { $_ -notmatch '^\s*(#|\|)' }) -join "`n"
$han = [regex]::Matches($prose, '[\u4e00-\u9fff]').Count
if ($han -lt 6000) { $failures.Add("Too short: $han prose Han characters") }
$links = 0
foreach ($m in [regex]::Matches($body, '\[[^\]\r\n]+\]\((?<p><[^>\r\n]+>|[^)\r\n]+)\)')) {
    $p = $m.Groups['p'].Value.Trim('<','>')
    if ($p -match '^(https?://|#)') { continue }
    $p = ($p -split '#', 2)[0]
    $target = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Split-Path $reportFile) $p }
    $links++
    if (-not (Test-Path -LiteralPath $target)) { $failures.Add("Missing local link: $p") }
}
$lines = $body -split '\r?\n'
$tableWidth = 0
$fenced = $false
for ($i=0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^```') { $fenced = -not $fenced; continue }
    if ($fenced) { continue }
    if ($line -match '^#{1,6} ' -and $i+1 -lt $lines.Count -and $lines[$i+1] -notmatch '^\s*$') { $failures.Add("Heading spacing line $($i+1)") }
    if ($line -match '^\|') {
        $width = [regex]::Matches($line, '(?<!\\)\|').Count
        if ($tableWidth -and $width -ne $tableWidth) { $failures.Add("Table width line $($i+1)") }
        $tableWidth = $width
    } else { $tableWidth = 0 }
}
$caseRoot = Split-Path -Parent $ReportRoot
$workspace = Split-Path -Parent $caseRoot
$metrics = Get-Content -LiteralPath (Join-Path $ReportRoot 'tables/current-c39-metrics.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$plan = Get-Content -LiteralPath (Join-Path $workspace $metrics.model.manifest) -Raw -Encoding UTF8 | ConvertFrom-Json
if ($plan.steps.Count -ne 18) { $failures.Add('Current model not 18 stages') }
$views = @($plan.steps | Where-Object view | ForEach-Object index)
if (($views -join ',') -ne '11,13,17') { $failures.Add('View-stage evidence mismatch') }
$joint = Get-Content -LiteralPath (Join-Path $caseRoot 'review/C39_ONEHOT_JOINT_RESOURCE_CDC_REVIEW_20260915.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($joint.resource_xlr -ne $metrics.joint_s2.xlr -or $joint.map_metrics.rams -ne $metrics.joint_s2.ram -or $joint.map_metrics.dsp_mults -ne $metrics.joint_s2.dsp) { $failures.Add('Joint metrics mismatch') }
$compact = $body.Replace(',','').Replace('，','')
foreach ($number in @('40476','41318','51900','6433652')) {
    if (-not $compact.Contains($number)) { $failures.Add("Missing current fact: $number") }
}
if ($body -notmatch '23\.31') { $failures.Add('Missing scoped native fps') }
if ($body -notmatch '100\s*MHz' -or $body -notmatch '150\s*MHz') { $failures.Add('Missing separate clock boundaries') }
$slots = @([regex]::Matches($body, '【待[^】]*?\b([MP]\d+)\b') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($slots.Count -lt 8) { $failures.Add("Expected numbered incomplete work: $($slots.Count)") }
if ($failures.Count) { $failures | ForEach-Object { Write-Output "FAIL $_" }; exit 1 }
Write-Output "CURRENT_REPORT_PASS sections=8 prose_han=$han local_links=$links placeholders=$($slots.Count) model_stages=18"
Write-Output 'EVIDENCE_SCOPE_PASS current model and derived joint resource record checked; no new EDA or board validation.'
