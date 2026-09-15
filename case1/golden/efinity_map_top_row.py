"""Parse an actual root MAP row even when its repeated module label is truncated."""
import json
from pathlib import Path
import re

KEYS = ('ff', 'srl', 'adds', 'luts', 'comb4', 'rams', 'dsp_mults')


def parse_top_row(rows, name):
    expression = re.compile(r'^\s*(?:INFO\s*:\s*)?' + re.escape(name) + r':(\S+)\s+' +
                            r'\s+'.join([r'([\d,]+)\([\d,]+\)'] * 7) + r'\s*$')
    matches = []
    for row in rows:
        match = expression.fullmatch(row)
        if not match:
            continue
        label = match[1]
        valid = label == name or (label.endswith('...') and len(label[:-3]) >= 8 and name.startswith(label[:-3]))
        if not valid:
            raise ValueError('root MAP instance has a different module label')
        values = tuple(int(match[i + 2].replace(',', '')) for i in range(7))
        matches.append(values)
    if not matches or len(set(matches)) != 1:
        raise ValueError('missing or conflicting actual root MAP row')
    return dict(zip(KEYS, matches[0]))


def selftest():
    root = Path(__file__).resolve().parents[1]
    cases = (
        ('c37_resource24_pnr_20260915b', 'c1_ti60_c37_resource24', (17945, 28933, 117, 121)),
        ('c39_host_native_pnr_20260915a', 'c1_ti60_c39_host_native', (17323, 28687, 117, 121)),
        ('c39_host_direct_pnr_20260915a', 'c1_ti60_c39_host_direct', (17322, 28373, 117, 121)),
        ('c39_host_onehot_pnr_20260915a', 'c1_ti60_c39_host_onehot', (17335, 28079, 117, 121)),
        ('c39_onehot_acceptance_20260915a_joint_s2_onehot_cdc', 'c1_ti60_c39_joint_s2_onehot_cdc', (23053, 35368, 165, 125)),
    )
    for run, name, expected in cases:
        summary = json.loads((root / 'logs/efinity_resource_runs' / run / 'summary.json').read_text(encoding='utf-8-sig'))
        result = parse_top_row(summary['metrics']['module_rows'], name)
        if tuple(result[key] for key in ('ff', 'luts', 'rams', 'dsp_mults')) != expected:
            raise AssertionError('actual MAP counts differ: ' + run)
    row = next(row for row in summary['metrics']['module_rows'] if row.startswith(name + ':'))
    mutations = ([], [row.replace(name + ':', 'wrong:')],
                 [re.sub(r':\S+', ':wrong...', row, count=1)],
                 [row, row.replace('23053(6)', '23054(6)')])
    rejected = 0
    for rows in mutations:
        try:
            parse_top_row(rows, name)
        except ValueError:
            rejected += 1
        else:
            raise AssertionError('ambiguous MAP evidence accepted')
    print('EFINITY_MAP_TOP_ROW_SELFTEST_PASS ' + json.dumps(dict(actual_reports=len(cases), rejected=rejected,
        joint_ff=result['ff'], joint_luts=result['luts'], joint_ram=result['rams'], joint_dsp=result['dsp_mults'],
        historical_summaries_modified=False), separators=(',', ':')))


if __name__ == '__main__':
    selftest()
