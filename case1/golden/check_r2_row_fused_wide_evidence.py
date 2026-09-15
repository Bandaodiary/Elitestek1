"""Independent native-width row-transfer gate; never infer native FPS."""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'model'))
from r2_plan_package import profile_nodes
from r2_execution_plan import OP_UPSAMPLE2,OP_OUTPUT_RGB
PREFIX='C35_ROW_FUSED_GRAPH_'
PROFILES={('microstyle24',4,0),('microstyle24',12,1),('drop_res1',12,1)}


def validate_cases(cases):
    for c in cases:
        w,h,fused=c['width'],c['height'],c['fused']
        nodes=profile_nodes(c['profile'],w,h)
        expected_words=sum(((n.spec.output_width+1)//2)*((n.spec.output_channels+7)//8)*n.spec.output_height for n in nodes if n.spec.opcode not in (OP_UPSAMPLE2,OP_OUTPUT_RGB))-(w*h if fused else 0)
        if w!=640 or any(c.get(k) is not False for k in ('actual_AXI','native_fps_claim','physical_RAM_measured')):raise ValueError('wrong wide scope')
        if len(c['frames'])!=2 or len(c['shadow'])!=2:raise ValueError('wrong frames')
        for fid,(f,s) in enumerate(zip(c['frames'],c['shadow'])):
            expected=dict(frame=fid,width=w,height=h,stalls=c['stalls'],commits=len(nodes),write_beats=expected_words,
                memdiv=2,latency=20,cache=1,overlap=1,compute_overlap=1,refill_priority=1,write_throttle=0)
            if any(f.get(k)!=v for k,v in expected.items()) or f.get('cycles',0)<1:raise ValueError('wrong frame coverage')
            if s!=dict(frame=fid,enabled=int(fused),packets=3*w*h if fused else 0,DW_rows=h if fused else 0,PW_rows=h if fused else 0,checker_only=1):raise ValueError('wrong real shadow evidence')


def check_text(text):
    if re.search('FATAL|ERROR:|Traceback|RuntimeError',text):raise ValueError('failed text')
    cases=[json.loads(x[len(PREFIX+'CASE '):]) for x in text.splitlines() if x.startswith(PREFIX+'CASE ')]
    paired=[json.loads(x[len(PREFIX+'WIDE_PAIRED '):]) for x in text.splitlines() if x.startswith(PREFIX+'WIDE_PAIRED ')]
    keys={(c['profile'],c['height'],c['stalls'],c['fused']) for c in cases}
    if len(cases)!=6 or keys!={(p,h,s,f) for p,h,s in PROFILES for f in (False,True)}:raise ValueError('wrong wide matrix')
    if len(paired)!=3 or {(c['profile'],c['height'],c['stalls']) for c in paired}!=PROFILES:raise ValueError('wrong paired matrix')
    validate_cases(cases)
    reductions=[]
    for pair in paired:
        profile,h,stalls=pair['profile'],pair['height'],pair['stalls']
        f=next(c for c in cases if (c['profile'],c['height'],c['stalls'],c['fused'])==(profile,h,stalls,True))
        b=next(c for c in cases if (c['profile'],c['height'],c['stalls'],c['fused'])==(profile,h,stalls,False))
        if len(pair['samples'])!=2 or pair['width']!=640 or pair['actual_AXI'] is not False or pair['native_fps_claim'] is not False:raise ValueError('wrong pair scope')
        removed=640*h;extra=72*(h-1)
        for fid,(a,z,s) in enumerate(zip(f['frames'],b['frames'],pair['samples'])):
            if z['write_beats']-a['write_beats']!=removed or z['producer_reads']-a['producer_reads']!=removed or a['read_beats']-z['read_beats']!=extra-removed:raise ValueError('DW transfer not eliminated')
            reduction=100*(z['cycles']-a['cycles'])/z['cycles']
            expected=dict(frame=fid,fused_cycles=a['cycles'],unfused_cycles=z['cycles'],
                removed_write_bytes=removed*16,removed_feature_read_bytes=removed*16,
                extra_parameter_bytes=extra*16,net_transfer_reduction_bytes=(2*removed-extra)*16)
            if any(s.get(k)!=v for k,v in expected.items()) or abs(s['cycle_reduction_percent']-reduction)>1e-9:raise ValueError('wrong derived benefit')
            reductions.append(reduction)
    for suffix in ('WIDE_SUMMARY configurations=6 correct_frames=12 comparisons=3 actual_AXI=0 native_fps_claim=0','WIDE_CLEAN temporary_vectors_and_simulator_removed=1'):
        if text.splitlines().count(PREFIX+suffix)!=1:raise ValueError('missing/duplicate summary/cleanup')
    return dict(configurations=6,correct_frames=12,comparisons=3,
        cycle_reduction_percent_range=[min(reductions),max(reductions)],
        all_samples_faster=all(x>0 for x in reductions),pairs=paired,
        actual_AXI=False,native_fps_claim=False,physical_RAM_measured=False)


def resume_cases(run):
    # Only completed cases before the known HARNESS timeout can be reused.
    from datetime import datetime
    from run_r2_row_fused_graph_probe import sources
    if run!='c35_row_fused_wide_20260914_a':raise ValueError('unapproved resume source')
    folder=ROOT/'logs/r2_row_fused_wide_runs'/run
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    private=ROOT/'sim'/f'c1_r2_row_fused_wide_{run}'
    if status.get('state')!='failed' or status.get('worker_in_windows_job') is not False or status.get('simulator_directory_present') is not False or private.exists():raise ValueError('resume source not terminal/clean')
    if (folder/'result.log').stat().st_size>131072 or (folder/'result.stderr.log').stat().st_size>32768:raise ValueError('oversized resume log')
    err=(folder/'result.stderr.log').read_text()
    if 'subprocess.TimeoutExpired' not in err or 'timed out after 300 seconds' not in err or 'microstyle24_640x12_s1_f0_n0' not in err:raise ValueError('not the known test-harness timeout')
    text=(folder/'result.log').read_text()
    if re.search('FATAL|ERROR:',text):raise ValueError('failed RTL output')
    previous=(folder/'driver_before_timeout_extension.py').read_text()
    current=(ROOT/'golden/run_r2_row_fused_graph_probe.py').read_text()
    if previous.replace('timeout=300)','timeout=900)').strip()!=current.strip():raise ValueError('driver changed beyond wall-clock timeout')
    protected=sources()+[ROOT/'sim/tb_c1_r2_row_fused_graph.sv']
    protected += [ROOT/'golden'/n for n in ('r2_row_fused_graph_vectors.py','r2_plan_vectors.py','r2_tail_tile_contract.py','run_r2_graph_probe.py','run_r2_array_probe.py','generate_microstyle_engine_bitexact_vectors.py')]
    protected += [ROOT/'model'/n for n in ('r2_row_fused_plan.py','r2_execution_plan.py','r2_plan_package.py','microstyle_layout.py','microstyle_quant.py')]
    protected += list((ROOT/'model/microstyle24_starry_functional').glob('*'))
    # PowerShell emits seven fractional digits; bundled Python accepts six.
    start=re.sub(r'(\.\d{6})\d+(?=[+-]|$)',r'\1',status['worker_start'])
    cutoff=datetime.fromisoformat(start).timestamp()
    if any(p.is_file() and p.stat().st_mtime>cutoff for p in protected):raise ValueError('numeric source changed since completed cases; rerun instead')
    cases=[json.loads(x[len(PREFIX+'CASE '):]) for x in text.splitlines() if x.startswith(PREFIX+'CASE ')]
    expected={('microstyle24',4,0,True),('microstyle24',4,0,False),('microstyle24',12,1,True)}
    if len(cases)!=3 or {(c['profile'],c['height'],c['stalls'],c['fused']) for c in cases}!=expected:raise ValueError('wrong completed-case prefix')
    validate_cases(cases)
    return {(c['profile'],c['height'],c['stalls'],c['fused']):c for c in cases}


def run_gate(run):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',run):raise ValueError('invalid run')
    folder=ROOT/'logs/r2_row_fused_wide_runs'/run
    s=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    private=(ROOT/'sim'/f'c1_r2_row_fused_wide_{run}').resolve()
    if (s.get('run_id')!=run or s.get('state')!='complete' or s.get('exit_code')!=0 or s.get('worker_in_windows_job') is not False or
        s.get('simulator_directory_present') is not False or Path(s['run_directory']).resolve()!=private or private.exists()):raise ValueError('not complete/clean/isolated')
    budget=s.get('workload_budget') or {}
    if budget.get('logical_processors') not in (1,2) or budget.get('priority')!='BelowNormal':raise ValueError('wrong budget')
    if (folder/'result.log').stat().st_size>131072 or (folder/'result.stderr.log').read_text(encoding='utf-8-sig').strip():raise ValueError('oversized/failed log')
    text=(folder/'result.log').read_text(encoding='utf-8-sig');result=check_text(text)
    cases=[json.loads(x[len(PREFIX+'CASE '):]) for x in text.splitlines() if x.startswith(PREFIX+'CASE ')]
    reused=[c for c in cases if c.get('evidence_origin_run')]
    for origin in {c['evidence_origin_run'] for c in reused}:
        original=resume_cases(origin)
        for c in (c for c in reused if c['evidence_origin_run']==origin):
            copy=dict(c);copy.pop('evidence_origin_run')
            if original.get((c['profile'],c['height'],c['stalls'],c['fused']))!=copy:raise ValueError('reused evidence differs from actual source log')
    if reused and text.splitlines().count(PREFIX+'WIDE_EXECUTIONS fresh_configurations=3 reused_configurations=3')!=1:raise ValueError('missing reuse accounting')
    result.update(fresh_configurations=6-len(reused),reused_configurations=len(reused))
    for bad in (text.replace('"width":640','"width":636',1),text+'\nFATAL damaged evidence',
        text.replace('correct_frames=12','correct_frames=11'),text.replace('"checker_only":1','"checker_only":0',1)):
        if bad==text:raise ValueError('ineffective evidence negative')
        try:check_text(bad)
        except (ValueError,KeyError,TypeError):continue
        raise AssertionError('damaged evidence accepted')
    print(PREFIX+'WIDE_EVIDENCE_PASS '+json.dumps(dict(run=run,**result,temporary_removed=True,
        seconds=s['elapsed_seconds'],evidence_corruption_rejections=4,process_liveness_not_inferred=True),separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',required=True);run_gate(p.parse_args().run)
