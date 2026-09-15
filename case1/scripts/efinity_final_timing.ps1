# Parse the final STA table, not a concatenation of intermediate log summaries.
# Read only the retained bounded excerpt. Never infer a passing slack from Fmax.
function Get-EfinityFinalTiming([string]$Text) {
    $number = '[-+]?[0-9]+(?:\.[0-9]+)?'
    if ($Text -notmatch '(?m)^Efinix Static Timing Analysis Report\s*$' -or
        $Text -notmatch '(?m)^\s*status\s*:\s*final\s*$') {
        throw 'not a final Efinity STA report'
    }
    $begin = '---------- 2. Clock Relationship Summary (begin) ----------'
    $end = '---------- Clock Relationship Summary (end) ---------------'
    $a = $Text.IndexOf($begin); $b = $Text.IndexOf($end)
    if ($a -lt 0 -or $b -le $a) { throw 'incomplete final clock relationship table' }
    $rows = @(); $mode = ''; $headers = @()
    foreach ($line in ($Text.Substring($a + $begin.Length, $b - $a - $begin.Length) -split '\r?\n')) {
        $line = $line.Trim()
        if ($line -eq 'Setup (Max) Clock Relationship') { $mode = 'setup'; $headers += $mode; continue }
        if ($line -eq 'Hold (Min) Clock Relationship') { $mode = 'hold'; $headers += $mode; continue }
        if (-not $line -or $line -match '^Launch Clock\s+Capture Clock\s+Constraint' -or
            $line -eq 'NOTE: Values are in nanoseconds.') { continue }
        if (-not $mode -or $line -notmatch "^(\S+)\s+(\S+)\s+($number)\s+($number)\s+(\([RF]-[RF]\))$") {
            throw ('unrecognized final timing table row: ' + $line)
        }
        $rows += [pscustomobject]@{
            kind=$mode; launch=$Matches[1]; capture=$Matches[2];
            constraint_ns=[double]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture);
            slack_ns=[double]::Parse($Matches[4], [Globalization.CultureInfo]::InvariantCulture); edge=$Matches[5]
        }
    }
    if (($headers -join ',') -ne 'setup,hold') { throw 'missing or duplicate final timing table sections' }
    $setup = @($rows | Where-Object kind -eq 'setup'); $hold = @($rows | Where-Object kind -eq 'hold')
    if (-not $setup.Count -or -not $hold.Count) { throw 'empty final timing table' }
    $keys = @($rows | ForEach-Object { $_.kind + '/' + $_.launch + '/' + $_.capture + '/' + $_.edge })
    if (@($keys | Select-Object -Unique).Count -ne $keys.Count) { throw 'duplicate final timing relationship' }
    $geo = [regex]::Matches($Text.Substring(0,$a), "(?m)^Geomean max period:\s*($number)\s*$")
    if ($geo.Count -ne 1) { throw 'missing or ambiguous final geomean period' }
    $period = [double]::Parse($geo[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($period -le 0) { throw 'invalid final geomean period' }
    $minSetup = ($setup | Measure-Object slack_ns -Minimum).Minimum
    $minHold = ($hold | Measure-Object slack_ns -Minimum).Minimum
    return [pscustomobject]@{
        source='final_sta_clock_relationship_table';
        final_slack_ns=$minSetup; final_hold_slack_ns=$minHold;
        geomean_period_ns=$period; geomean_frequency_mhz=[math]::Round(1000.0/$period,3);
        geomean_is_core_fmax=$false; setup_rows=$setup.Count; hold_rows=$hold.Count;
        timing_pass=($minSetup -ge 0 -and $minHold -ge 0); relationships=$rows
    }
}
