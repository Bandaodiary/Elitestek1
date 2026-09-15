param(
    [string]$ReportRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$reportPath = Join-Path $ReportRoot 'chapters/赛题一_RTL架构设计与验证报告.md'
$text = Get-Content -Raw -Encoding UTF8 -LiteralPath $reportPath
$lines = Get-Content -Encoding UTF8 -LiteralPath $reportPath
$failures = New-Object 'System.Collections.Generic.List[string]'

if ($text.Contains([char]0xFFFD)) { $failures.Add('Replacement character found') }
if (([regex]::Matches($text, '(?m)^# ')).Count -ne 1) { $failures.Add('Expected one title') }
foreach ($n in 1..8) {
    if (([regex]::Matches($text, "(?m)^## $n ")).Count -ne 1) {
        $failures.Add("Missing or duplicated section $n")
    }
}
if (([regex]::Matches($text, '(?m)^```')).Count % 2 -ne 0) { $failures.Add('Unbalanced code fence') }
if (([regex]::Matches($text, '\\\[')).Count -ne ([regex]::Matches($text, '\\\]')).Count) {
    $failures.Add('Unbalanced display math delimiters')
}
for ($i = 0; $i -lt $lines.Count - 1; $i++) {
    if ($lines[$i] -match '^#{1,6} ' -and $lines[$i + 1] -notmatch '^\s*$') {
        $failures.Add("Heading needs blank line at $($i+1)")
    }
}
$localCount = 0
foreach ($match in [regex]::Matches($text, '\[[^\]\r\n]+\]\((?<target><[^>\r\n]+>|[^)\r\n]+)\)')) {
    $target = $match.Groups['target'].Value.Trim('<', '>')
    if ($target -match '^[A-Za-z]:[/\\]') {
        $localCount++
        if (-not (Test-Path -LiteralPath $target)) { $failures.Add("Broken local link: $target") }
    }
}
$refText = ($text -split '## 参考文献与工程资料', 2)[1]
foreach ($n in 1..19) {
    $id = 'E{0:d2}' -f $n
    if ($refText -notmatch ('(?m)^\[' + $id + '\]')) { $failures.Add("Missing reference $id") }
}
foreach ($id in @('R01','R02','R03')) {
    if ($refText -notmatch ('(?m)^\[' + $id + '\]')) { $failures.Add("Missing reference $id") }
}
$slots = @([regex]::Matches($text, '【待(?:实测)?补充\s+(?<id>[MP]\d+)') | ForEach-Object { $_.Groups['id'].Value } | Sort-Object -Unique)
foreach ($id in @('M01','M02','M03','P01','P02','P03','P04','P05','P06','P07','P08','P09')) {
    if ($slots -notcontains $id) { $failures.Add("Missing agreed placeholder $id") }
}
$beforeRefs = ($text -split '## 参考文献与工程资料', 2)[0]
$bodyNoCode = [regex]::Replace($beforeRefs, '(?ms)^```.*?^```\s*', '')
$proseLines = ($bodyNoCode -split '\r?\n') | Where-Object { $_ -notmatch '^\s*(#|\|)' }
$proseHan = [regex]::Matches(($proseLines -join "`n"), '[\u4e00-\u9fff]').Count
if ($proseHan -lt 6000) { $failures.Add("Prose too short: $proseHan Han characters") }

$data = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $ReportRoot 'tables/source-metrics.json') | ConvertFrom-Json
$workspace = Split-Path -Parent (Split-Path -Parent $ReportRoot)
$isp = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $workspace $data.isp.source) | ConvertFrom-Json
$qat = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $workspace $data.qat.source) | ConvertFrom-Json
$model = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $workspace $data.model.source) | ConvertFrom-Json
if ($isp.image_count -ne $data.isp.images -or $isp.pattern_cases -ne $data.isp.bayer_cases) { $failures.Add('ISP test counts disagree') }
if ([math]::Abs($isp.minimum_finite_psnr_db - $data.isp.minimum_psnr_db) -gt 1e-9) { $failures.Add('ISP minimum PSNR disagrees') }
if ([math]::Abs($isp.mean_finite_psnr_db - $data.isp.mean_psnr_db) -gt 1e-9) { $failures.Add('ISP mean PSNR disagrees') }
if ($qat.integer_qat_max_abs_error -ne $data.qat.max_abs_error_u8) { $failures.Add('QAT error disagrees') }
if ($model.descriptor_count -ne $data.model.stage_count -or $model.convolution_weights -ne $data.model.conv_weight_count -or $model.parameter_arena_bytes -ne $data.model.parameter_arena_bytes -or $model.macs_per_frame -ne $data.model.mac_per_vga_frame) { $failures.Add('Model manifest metrics disagree') }

$tableWidth = 0
$inCode = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^```') { $inCode = -not $inCode; continue }
    if ($inCode) { continue }
    if ($line -match '^\|') {
        $width = ([regex]::Matches($line, '\|')).Count
        if ($tableWidth -eq 0) { $tableWidth = $width }
        elseif ($width -ne $tableWidth) { $failures.Add("Table width mismatch at $($i+1)") }
    } else { $tableWidth = 0 }
}
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "FAIL $_" }
    exit 1
}
Write-Output "REPORT_CHECK_PASS sections=8 local_links=$localCount references=22 placeholders=$($slots.Count) prose_han=$proseHan bytes=$((Get-Item -LiteralPath $reportPath).Length)"
Write-Output 'METRIC_CHECK_PASS ISP/QAT/model values agree with existing source JSON; no FPGA runs performed.'
