"""Check C4 functional/physical evidence without promoting it to frame proof."""
from __future__ import annotations
import argparse,json,re
from pathlib import Path
from check_r2_pw_tile_evidence import fields
from r2_tile_schedule_budget import row_cycles,budget

ROOT=Path(__file__).resolve().parents[1]


def simulation(text):
    lines=text.splitlines();headers=[s for s in lines if s.startswith('C1_R2_TILE_VECTORS ')]
    if len(headers)!=1: raise ValueError('missing/duplicate metadata')
    m=json.loads(headers[0].split(' ',1)[1]);jobs=m['jobs']
    if len(jobs)!=114 or [sum(j['mode']==i for j in jobs) for i in range(4)]!=[62,13,25,14]: raise ValueError('missing operator jobs')
    if m['commands']!=247710 or sum(j['loads']+1 for j in jobs)!=m['commands']: raise ValueError('wrong command plan')
    if m['vectors']!=69827 or sum(j['vectors'] for j in jobs)!=m['vectors']: raise ValueError('wrong vector total')
    if m['scalars']!=396681 or sum(j['scalars'] for j in jobs)!=m['scalars']: raise ValueError('wrong scalar total')
    if m['trained_scalars']!=163840 or sum(j['scalars'] for j in jobs if j['trained'])!=m['trained_scalars']: raise ValueError('missing trained coverage')
    shapes={(j['channels'],j['outputs']) for j in jobs if j['mode']==0}
    if shapes!={(ci,co) for ci in (16,24,48) for co in (8,16,24,48)}: raise ValueError('missing PW shapes')
    native={j['label'] for j in jobs if j['trained']}
    wanted={f'qat_stage{s}_row{y}' for s,h in ((2,1),(3,1),(4,1),(6,1),(7,1),(8,1),(10,1),(11,1),(12,1),(15,2),(16,2),(18,4),(19,4),(20,4)) for y in range(h)}
    wanted|={f'qat_stage{s}' for s in (5,9,13)}
    if native!=wanted: raise ValueError('wrong model layer coverage')
    rows=[fields(s) for s in lines if s.startswith('C1_R2_TILE_JOB ')];passes=[fields(s) for s in lines if s.startswith('C1_R2_TILE_PASS ')]
    if len(rows)!=228 or len(passes)!=2: raise ValueError('incomplete test variants')
    for stalls in (0,1):
        rs=[r for r in rows if r['stalls']==stalls]
        if [r['job'] for r in rs]!=list(range(114)): raise ValueError('missing/duplicate job')
        checks=windows=zero_masks=0
        for r,j in zip(rs,jobs):
            if any(r[k]!=j[k] for k in ('mode','size','channels','outputs','vectors')): raise ValueError('wrong job identity')
            groups=j['channels']//8
            nw=((j['size']+1)//2)*groups if j['mode'] in (1,2) else 0
            beats=j['vectors']*((j['channels']+15)//16 if j['mode']==0 else 5 if j['mode']==1 else 1)
            wr=beats if j['mode']!=3 else 0; fr=beats if j['mode'] in (0,3) else 0
            want=dict(groups=groups,windows=nw,ram_reads=nw*2,mac_beats=beats,weight_reads=wr,feature_reads=fr)
            if any(r[k]!=v for k,v in want.items()): raise ValueError('wrong SRAM/MAC work count')
            minimum=row_cycles(j['mode'],j['size'],j['channels'],j['outputs'])
            if r['cycles']<minimum or (not stalls and r['cycles']!=minimum): raise ValueError('wrong cycle budget')
            windows+=nw;checks+=wr*(3 if j['mode']==1 else 8)
            if j['mode']==2 and j['size']%2: zero_masks+=groups
        ps=[p for p in passes if p['stalls']==stalls]
        if len(ps)!=1: raise ValueError('missing/duplicate pass')
        p=ps[0];changes=sum(a['mode']!=b['mode'] for a,b in zip(jobs,jobs[1:]))
        want=dict(jobs=114,vectors=69827,mode_changes=changes,windows=windows,zero_masks=zero_masks,parameter_checks=checks,
                  reset_inflight=4,invalid_commands=24)
        if any(p[k]!=v for k,v in want.items()): raise ValueError('missing parameter/reset/mode coverage')
        if min(p['busy_rejections'],p['full_slots'],p['simultaneous_push_pop'])<20 or (stalls and p['blocked']<20): raise ValueError('no backpressure/ownership coverage')
    if lines.count('C1_R2_TILE_CLEAN temporary_vectors_and_simulator_removed=1')!=1 or any('FATAL' in s or 'ERROR' in s for s in lines): raise ValueError('error or missing cleanup')
    return dict(configs=2,jobs_per_config=114,vectors_per_config=69827,scalars_per_config=396681,trained_scalars_per_config=163840,
                pw_shapes=12,parameter_bank_checks_per_config=690509,scope='SRAM backed operator rows; no full CNN/DDR/frame proof')


def physical(run):
    def read(name): return (run/name).read_text(encoding='utf-8-sig')
    status=json.loads(read('status.json'));s=json.loads(read('summary.json'))
    if status['state']!='complete' or status['exit_code']!=0 or s['flow']!='map+pnr' or s['pnr_exit_code']!=0: raise ValueError('physical run incomplete')
    if s['family']!='Titanium' or s['device']!='Ti60F225' or '--timing_model I3 ' not in read('efinity.pnr.stdout.tail.log'): raise ValueError('wrong target')
    m=s['metrics'];r=s['pnr_resources'];t=s['timing']
    if m['primitive_counts'].get('EFX_DSP24')!=96 or m['primitive_counts'].get('EFX_DSP48')!=12: raise ValueError('duplicated/pruned compute')
    if (r['dsp_blocks_used'],r['dsp_blocks_total'])!=(108,160) or (r['memory_blocks_used'],r['memory_blocks_total'])!=(128,256): raise ValueError('wrong DSP/RAM footprint')
    # Run a's 40-row summary truncated the compute/spatial hierarchy. Run b
    # deliberately repeats MAP ONLY with an 80-row bound, same design/config.
    # Keep a as the PNR evidence; never pretend b also ran placement/routing.
    hierarchy_run=run.parent/'c1_ti60_r2_tile96_i3_20260913_b'
    hs=json.loads((hierarchy_run/'status.json').read_text(encoding='utf-8-sig'))
    hm=json.loads((hierarchy_run/'summary.json').read_text(encoding='utf-8-sig'))
    if hs['state']!='complete' or hs['exit_code']!=0 or hm['flow']!='map': raise ValueError('hierarchy map incomplete')
    if any(hm['metrics']['module'][key]!=m['module'][key] for key in ('ff','luts','rams','dsp_mults')):
        raise ValueError('map-only hierarchy not numerically consistent with PNR source map')
    rows=list(dict.fromkeys(hm['metrics']['module_rows']))
    def counts(fragment):
        found=[x for x in rows if fragment in x and len(re.findall(r'(\d+)\((\d+)\)',x))==7]
        if len(found)!=1: raise ValueError('missing/duplicate hierarchy '+fragment)
        return [int(a) for a,_ in re.findall(r'(\d+)\((\d+)\)',found[0])]
    if counts('+u_weights:')[-2:]!=[64,0] or counts('+u_linear:')[-2:]!=[16,0] or counts('+u_spatial:')[-2:]!=[48,0]: raise ValueError('wrong shared storage hierarchy')
    if counts('+u_compute:')[-2:]!=[0,108] or counts('+u_mac:')[-1]!=96 or counts('+u_quant:')[-1]!=12: raise ValueError('not one compute hierarchy')
    if r['xlr_cells_total']!=60800 or not 0<r['xlr_cells_used']<=60800: raise ValueError('invalid XLR footprint')
    if t['final_slack_ns']<0 or t['final_hold_slack_ns']<0 or abs(t['final_period_ns']+t['final_slack_ns']-6.666)>.002: raise ValueError('150 MHz core timing failed')
    return dict(run=run.name,hierarchy_map_run=hierarchy_run.name,dsp=108,ram=128,xlr=r['xlr_cells_used'],ff=m['module']['ff'],setup_ns=t['final_slack_ns'],hold_ns=t['final_hold_slack_ns'],
                estimated_internal_fmax_MHz=t['final_frequency_mhz'],scope='compute/parameter/feature core, excludes CPU/DDR/video/I/O')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--sim-only',action='store_true')
    args=parser.parse_args();log=(ROOT/'logs/r2_cnn_tile_probe_20260913_a.log').read_text(encoding='utf-8-sig')
    print('C1_R2_TILE_SIM_GATE_PASS '+json.dumps(simulation(log)))
    wrongs=(log.replace('cycles=2573','cycles=2574',1),log.replace('weight_reads=2560','weight_reads=2559',1),
            log.replace('feature_reads=854','feature_reads=853',1),log.replace('parameter_checks=690509','parameter_checks=0',1),
            log.replace('reset_inflight=4','reset_inflight=3',1),log.replace('invalid_commands=24','invalid_commands=23',1),
            log.replace('C1_R2_TILE_CLEAN','MISSING_CLEAN'),log+'\nFATAL: injected bad evidence\n')
    for wrong in wrongs:
        assert wrong!=log
        try: simulation(wrong)
        except ValueError: pass
        else: raise AssertionError('corrupt evidence accepted')
    print(f'C1_R2_TILE_NEGATIVE_GATE_PASS rejected={len(wrongs)}')
    b=budget();assert b['mixed_schedule_cycles']==6113143 and b['measured_frame_fps'] is None
    print('C1_R2_TILE_BUDGET_GATE_PASS mixed_cycles=6113143 measured_frame_fps=unknown')
    if not args.sim_only: print('C1_R2_TILE_PHYSICAL_GATE_PASS '+json.dumps(physical(ROOT/'logs/efinity_resource_runs/c1_ti60_r2_tile96_i3_20260913_a')))
