"""Independent C35 component run gate; no full-CNN/resource/fps claim."""
import argparse
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
REASONS=('two readers','two writers','same-view read/refill','same-view read/refill','invalid bounds',
         'linear read outside shadow','spatial read outside source','linear write outside shadow',
         'spatial write outside source','changed active lease','linear view needs refill','fallback ownership collision')


def check_text(text):
    lines=text.splitlines()
    positives=[line for line in lines if line.startswith('C35_ROW_SHADOW_PASS ')]
    if len(positives)!=1 or re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text):raise ValueError('positive result missing/bad')
    pairs=re.findall(r'(\w+)=(\d+)',positives[0]);counts={key:int(value) for key,value in pairs}
    if len(counts)!=len(pairs):raise ValueError('duplicate positive field')
    for key,value in dict(rows=17,packets=4607,protocol_cases=8,aborts=3,resets=1,byte_capacity=16384,
                          read_latency=1,invalid_padding_poisoned=1).items():
        if counts.get(key)!=value:raise ValueError('wrong count: '+key)
    for key,minimum in dict(packet_word_checks=6000,cross_cycles=4000,linear_reads=1000,
                            spatial_reads=6000,stall_cycles=6000).items():
        if counts.get(key,0)<minimum:raise ValueError('insufficient coverage: '+key)
    actual=[line for line in lines if line.startswith('C35_ROW_SHADOW_NEGATIVE_PASS ')]
    expected=[f'C35_ROW_SHADOW_NEGATIVE_PASS case={i} reason={reason}' for i,reason in enumerate(REASONS,1)]
    if actual!=expected:raise ValueError('assertion negative matrix mismatch')
    if lines.count('C35_ROW_SHADOW_CLEAN temporary_simulator_removed=1')!=1:raise ValueError('no cleanup record')
    if lines.count('C35_ROW_SHADOW_SUMMARY positive_configurations=1 assertion_negatives=12 actual_CNN=0 actual_AXI=0 native_fps_claim=0')!=1:
        raise ValueError('scope/summary mismatch')
    return counts


def gate_run(run):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',run):raise ValueError('bad RunId')
    folder=ROOT/'logs/r2_row_shadow_runs'/run
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    private=(ROOT/'sim'/f'c1_r2_row_shadow_{run}').resolve()
    if (status.get('run_id')!=run or status.get('state')!='complete' or status.get('exit_code')!=0 or
        status.get('worker_in_windows_job') is not False or status.get('simulator_directory_present') is not False or
        Path(status['run_directory']).resolve()!=private or private.exists()):raise ValueError('run not clean/complete/isolated')
    budget=status.get('workload_budget') or {}
    if budget.get('logical_processors') not in (1,2) or budget.get('priority')!='BelowNormal':raise ValueError('wrong worker budget')
    for key in ('actual_CNN','actual_AXI','native_fps_claim','physical_RAM_measured'):
        if status.get(key) is not False:raise ValueError('overstated result scope')
    result=folder/'result.log'
    if result.stat().st_size>65536:raise ValueError('unexpectedly large component log')
    if (folder/'result.stderr.log').read_text(encoding='utf-8-sig').strip():raise ValueError('stderr not empty')
    counts=check_text(result.read_text(encoding='utf-8-sig'))
    print('C35_ROW_SHADOW_EVIDENCE_PASS '+json.dumps(dict(run=run,counts=counts,assertion_negatives=12,
        temporary_removed=True,actual_CNN=False,actual_AXI=False,native_fps_claim=False,
        physical_RAM_measured=False,process_liveness_not_inferred=True),separators=(',',':')),flush=True)
    return counts


def selftest():
    fields='rows=17 packets=4607 packet_word_checks=6053 linear_reads=1254 spatial_reads=8000 cross_cycles=4500 stall_cycles=6500 protocol_cases=8 aborts=3 resets=1 byte_capacity=16384 read_latency=1 invalid_padding_poisoned=1'
    good='C35_ROW_SHADOW_PASS '+fields+'\n'+'\n'.join(
        f'C35_ROW_SHADOW_NEGATIVE_PASS case={i} reason={reason}' for i,reason in enumerate(REASONS,1))+'\n'+\
        'C35_ROW_SHADOW_CLEAN temporary_simulator_removed=1\n'+\
        'C35_ROW_SHADOW_SUMMARY positive_configurations=1 assertion_negatives=12 actual_CNN=0 actual_AXI=0 native_fps_claim=0\n'
    check_text(good)
    bad=[good.replace('rows=17','rows=16'),good.replace('packets=4607','packets=4606'),
         good.replace('cross_cycles=4500','cross_cycles=0'),good.replace('packets=4607','packets=4607 packets=4607'),
         good.replace('case=12','case=11'),good.replace('two readers','unrelated failure'),
         good.replace('C35_ROW_SHADOW_CLEAN','WRONG_CLEAN'),good.replace('native_fps_claim=0','native_fps_claim=1'),
         good+'FATAL bad\n',good+good.splitlines()[0]+'\n']
    for corrupt in bad:
        try:check_text(corrupt)
        except ValueError:pass
        else:raise AssertionError('bad evidence accepted')
    print('C35_ROW_SHADOW_GATE_SELFTEST_PASS '+json.dumps(dict(synthetic_positive=1,rejected=len(bad),
        RTL_executed=False,actual_run_claim=False),separators=(',',':')))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--run');parser.add_argument('--selftest',action='store_true')
    args=parser.parse_args()
    if args.selftest:selftest()
    elif args.run:gate_run(args.run)
    else:parser.error('choose --run or --selftest')
