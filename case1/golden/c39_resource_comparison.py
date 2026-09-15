"""Small same-boundary resource report; MAP counts are never called XLR."""
import argparse
import json
from pathlib import Path
from c39_candidate_sources import ROOT, artifacts as candidate_artifacts
from c39_host_projects import artifacts as project_artifacts


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def exact_source_gate():
    for relative, expected in list(candidate_artifacts()) + list(project_artifacts()):
        if (ROOT / relative).read_text(encoding='utf-8-sig').strip() != expected.strip():
            raise ValueError('candidate/source/project generation differs: ' + relative)


def record(run):
    if not run or Path(run).name != run:
        raise ValueError('expected a run identifier, not a path')
    folder = ROOT / 'logs/efinity_resource_runs' / run
    if not (folder / 'summary.json').is_file():
        return dict(run=run, state='pending_or_missing', measured=False)
    data = load(folder / 'summary.json')
    status = load(folder / 'status.json')
    measured = status['state'] in ('complete', 'failed') and data.get('metrics') is not None
    result = dict(run=run, state=status['state'], measured=measured)
    if not measured:
        return result
    metrics = data['metrics']
    pnr, timing = data['pnr_resources'], data['timing']
    result.update(lut4=metrics['le'], ff=metrics['registers'], ram=metrics['ebr'], dsp=metrics['dsp'],
                  pnr_xlr=pnr.get('xlr_cells_used'), pnr_exit_code=data.get('pnr_exit_code'),
                  setup_ns=timing.get('final_slack_ns'), hold_ns=timing.get('final_hold_slack_ns'),
                  private_removed=status.get('run_directory_present') is False and
                                  not Path(status['run_directory']).exists())
    result['pnr_timing_pass'] = (data.get('pnr_exit_code') == 0 and status['state'] == 'complete' and
                                 result['setup_ns'] is not None and result['setup_ns'] >= 0 and
                                 result['hold_ns'] is not None and result['hold_ns'] >= 0)
    return result


def compare(runs):
    exact_source_gate()
    baseline = record('c37_resource24_pnr_20260915b')
    if not baseline['measured'] or not baseline['private_removed'] or not baseline['pnr_timing_pass']:
        raise ValueError('retained pure-host reference lacks complete resource/timing evidence')
    rows = []
    for run in runs:
        row = record(run)
        if row['measured']:
            # Reject accidental CPU+DDR comparison against the pure-host boundary.
            summary = load(ROOT / 'logs/efinity_resource_runs' / run / 'summary.json')
            if not summary['metrics']['module_row'].lstrip().startswith('c1_ti60_c39_host_'):
                raise ValueError('candidate is not a pure-host ablation: ' + run)
            if summary['metrics']['module_row'].lstrip().startswith('c1_ti60_c39_host_direct:'):
                from c39_direct_sources import verify as verify_direct
                verify_direct()
            if summary['metrics']['module_row'].lstrip().startswith('c1_ti60_c39_host_onehot:'):
                from c39_onehot_sources import verify as verify_onehot
                verify_onehot()
            if summary['metrics']['module_row'].lstrip().startswith('c1_ti60_c39_host_native:'):
                from c39_native_sources import verify as verify_native
                verify_native()
            row['delta_vs_c37'] = {key: row[key] - baseline[key] for key in ('lut4', 'ff', 'ram', 'dsp')}
            if row['pnr_timing_pass']:
                row['delta_vs_c37']['pnr_xlr'] = row['pnr_xlr'] - baseline['pnr_xlr']
        rows.append(row)
    return dict(boundary='same C37 host probe / 18-node model / original clocks and constraints',
                baseline=baseline, candidates=rows, functional_signoff=False,
                native_throughput_verified=False, official_CPU_DDR_included=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('runs', nargs='+')
    args = parser.parse_args()
    print(json.dumps(compare(args.runs), ensure_ascii=False, separators=(',', ':')), flush=True)
