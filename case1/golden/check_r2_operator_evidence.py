"""C5 independent operator evidence gate, not an end-to-end frame gate."""
from __future__ import annotations
import argparse,json,re
from pathlib import Path
from check_r2_pw_tile_evidence import fields
from r2_operator_schedule_budget import row_cycles,budget

ROOT=Path(__file__).resolve().parents[1]


def simulation(text):
    lines=text.splitlines();headers=[s for s in lines if s.startswith('C1_R2_OPERATOR_VECTORS ')]
    if len(headers)!=1: raise ValueError('missing/duplicate metadata')
    m=json.loads(headers[0].split(' ',1)[1]);jobs=m['jobs']
    if len(jobs)!=187 or [sum(j['mode']==i for j in jobs) for i in range(6)]!=[62,13,73,14,14,11]: raise ValueError('missing operator jobs')
    if m['commands']!=501259 or sum(j['loads']+1 for j in jobs)!=m['commands']: raise ValueError('wrong command plan')
    if m['vectors']!=167635 or sum(j['vectors'] for j in jobs)!=m['vectors']: raise ValueError('wrong vector total')
    if m['scalars']!=925169 or sum(j['scalars'] for j in jobs)!=m['scalars']: raise ValueError('wrong scalar total')
    if m['trained_scalars']!=367360 or sum(j['scalars'] for j in jobs if j['trained'])!=m['trained_scalars']: raise ValueError('missing trained coverage')
    wanted={f'qat_stage{s}_row{y}' for s,h in ((2,1),(3,1),(4,1),(6,1),(7,1),(8,1),(10,1),(11,1),(12,1),(15,2),(16,2),(18,4),(19,4),(20,4),(0,6),(1,3)) for y in range(h)}
    wanted|={f'qat_stage{s}' for s in (5,9,13)}
    wanted|={f'qat_virtual_stage{s}_row{y}' for s,h in ((15,6),(18,12)) for y in range(h)}
    if {j['label'] for j in jobs if j['trained']}!=wanted: raise ValueError('wrong trained layer coverage')
    if {(j['channels'],j['outputs']) for j in jobs if j['mode']==0}!={(ci,co) for ci in (16,24,48) for co in (8,16,24,48)}: raise ValueError('missing retained PW shapes')
    for mode in (4,5):
        if not {1,2,3,7,1024}<={j['size'] for j in jobs if j['mode']==mode}: raise ValueError('missing encoder borders')
    if {(j['channels'],j['phase']) for j in jobs if j['virtual_up2']}!={(c,p) for c in (16,24,48) for p in (0,1)}: raise ValueError('missing virtual row phases')
    rows=[fields(s) for s in lines if s.startswith('C1_R2_OPERATOR_JOB ')];passes=[fields(s) for s in lines if s.startswith('C1_R2_OPERATOR_PASS ')]
    if len(rows)!=374 or len(passes)!=2: raise ValueError('incomplete test variants')
    for stalls in (0,1):
        rs=[r for r in rows if r['stalls']==stalls]
        if [r['job'] for r in rs]!=list(range(187)): raise ValueError('missing/duplicate job')
        checks=windows=zero_masks=encoder_windows=virtual_jobs=0
        for r,j in zip(rs,jobs):
            if any(r[k]!=j[k] for k in ('mode','size','channels','outputs','vectors','phase')) or r['up2']!=int(j['virtual_up2']) or r['width']!=j['output_width']: raise ValueError('wrong job identity')
            groups=1 if j['mode']==4 else 2 if j['mode']==5 else j['channels']//8
            out_width=(j['size']+1)//2 if j['mode'] in (4,5) else j['size']*2 if j['virtual_up2'] else j['size']
            if out_width!=j['output_width']: raise ValueError('wrong mapped width')
            nw=out_width*groups if j['mode'] in (4,5) else ((out_width+1)//2)*groups if j['mode'] in (1,2) else 0
            k=(j['channels']+15)//16 if j['mode']==0 else 5 if j['mode']==1 else 2 if j['mode']==4 else 7 if j['mode']==5 else 1
            vectors=(j['size']*j['outputs']+5)//6 if j['mode']==0 else (out_width+1)//2 if j['mode']==1 else ((out_width+1)//2)*groups*3 if j['mode']==2 else (j['size']+5)//6 if j['mode']==3 else out_width*j['outputs']//6
            if vectors!=j['vectors']: raise ValueError('wrong vector mapping')
            beats=vectors*k;wr=beats if j['mode']!=3 else 0;fr=beats if j['mode'] in (0,3) else 0
            ew=out_width if j['mode'] in (4,5) else 0
            want=dict(groups=groups,windows=nw,ram_reads=nw*2,mac_beats=beats,weight_reads=wr,feature_reads=fr,encoder_windows=ew)
            if any(r[k]!=v for k,v in want.items()): raise ValueError('wrong SRAM/MAC/assembly work')
            minimum=row_cycles(j['mode'],j['size'],j['channels'],j['outputs'],j['virtual_up2'])
            if r['cycles']<minimum or (not stalls and r['cycles']!=minimum): raise ValueError('wrong schedule')
            windows+=nw;checks+=wr*(3 if j['mode']==1 else 8);encoder_windows+=ew;virtual_jobs+=int(j['virtual_up2'])
            if j['mode']==2 and out_width%2: zero_masks+=groups
        ps=[p for p in passes if p['stalls']==stalls]
        if len(ps)!=1: raise ValueError('missing/duplicate pass')
        p=ps[0];changes=sum(a['mode']!=b['mode'] for a,b in zip(jobs,jobs[1:]))
        want=dict(jobs=187,vectors=167635,mode_changes=changes,windows=windows,zero_masks=zero_masks,parameter_checks=checks,
                  encoder_windows=encoder_windows,virtual_jobs=virtual_jobs,reset_inflight=8,invalid_commands=46)
        if any(p[k]!=v for k,v in want.items()): raise ValueError('missing virtual/encoder/reset coverage')
        if min(p['busy_rejections'],p['full_slots'],p['simultaneous_push_pop'],p['encoder_full_slots'])<20 or (stalls and p['blocked']<20): raise ValueError('no queue/backpressure coverage')
    if lines.count('C1_R2_OPERATOR_CLEAN temporary_vectors_and_simulator_removed=1')!=1 or any('FATAL' in s or 'ERROR' in s for s in lines): raise ValueError('error or missing cleanup')
    return dict(configs=2,jobs_per_config=187,vectors_per_config=167635,scalars_per_config=925169,trained_scalars_per_config=367360,
                parameter_bank_checks=1743597,encoder_windows=3956,virtual_jobs=48,scope='independent SRAM-backed operator rows, not graph/frame/DMA proof')


def physical(run):
    def read(name): return (run/name).read_text(encoding='utf-8-sig')
    status=json.loads(read('status.json'));s=json.loads(read('summary.json'))
    if status['state']!='complete' or status['exit_code']!=0 or s['flow']!='map+pnr' or s['pnr_exit_code']!=0: raise ValueError('physical run incomplete')
    if s['family']!='Titanium' or s['device']!='Ti60F225' or '--timing_model I3 ' not in read('efinity.pnr.stdout.tail.log'): raise ValueError('wrong physical target')
    m=s['metrics'];r=s['pnr_resources'];t=s['timing']
    if m['primitive_counts'].get('EFX_DSP24')!=96 or m['primitive_counts'].get('EFX_DSP48')!=12: raise ValueError('duplicated/pruned compute')
    if (r['dsp_blocks_used'],r['dsp_blocks_total'])!=(108,160) or (r['memory_blocks_used'],r['memory_blocks_total'])!=(128,256): raise ValueError('wrong resource footprint')
    def counts(fragment):
        found=[x for x in m['module_rows'] if fragment in x]
        if len(found)!=1: raise ValueError('missing/duplicate hierarchy '+fragment)
        pairs=re.findall(r'(\d+)\((\d+)\)',found[0])
        if len(pairs)!=7: raise ValueError('wrong hierarchy columns')
        return [int(a) for a,_ in pairs]
    if counts('+u_weights:')[-2:]!=[64,0] or counts('+u_linear:')[-2:]!=[16,0] or counts('+u_spatial:')[-2:]!=[48,0]: raise ValueError('wrong storage sharing')
    if counts('+u_store:')[-2:]!=[48,0] or counts('+u_encoder:')[-2:]!=[0,0]: raise ValueError('encoder duplicated RAM/compute')
    if counts('+u_compute:')[-2:]!=[0,108] or counts('+u_mac:')[-1]!=96 or counts('+u_quant:')[-1]!=12: raise ValueError('not one compute hierarchy')
    if r['xlr_cells_total']!=60800 or not 0<r['xlr_cells_used']<=60800: raise ValueError('invalid XLR footprint')
    if t['final_slack_ns']<0 or t['final_hold_slack_ns']<0 or abs(t['final_period_ns']+t['final_slack_ns']-6.666)>.002: raise ValueError('150 MHz core timing failed')
    return dict(run=run.name,dsp=108,ram=128,xlr=r['xlr_cells_used'],ff=m['module']['ff'],setup_ns=t['final_slack_ns'],hold_ns=t['final_hold_slack_ns'],
                estimated_internal_fmax_MHz=t['final_frequency_mhz'],scope='operator core, no CPU/DDR/video/board I/O')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--sim-only',action='store_true');args=p.parse_args()
    log=(ROOT/'logs/r2_operator_probe_20260913_b.log').read_text(encoding='utf-8-sig')
    print('C1_R2_OPERATOR_SIM_GATE_PASS '+json.dumps(simulation(log)))
    wrongs=(log.replace('cycles=1297','cycles=1298',1),log.replace('up2=1 phase=0','up2=0 phase=0',1),
            log.replace('encoder_windows=320','encoder_windows=319',1),log.replace('parameter_checks=1743597','parameter_checks=0',1),
            log.replace('reset_inflight=8','reset_inflight=7',1),log.replace('invalid_commands=46','invalid_commands=45',1),
            log.replace('virtual_jobs=48','virtual_jobs=0',1),log.replace('C1_R2_OPERATOR_CLEAN','MISSING_CLEAN'),log+'\nFATAL: injected bad evidence\n')
    for wrong in wrongs:
        assert wrong!=log
        try: simulation(wrong)
        except ValueError: pass
        else: raise AssertionError('corrupt evidence accepted')
    print(f'C1_R2_OPERATOR_NEGATIVE_GATE_PASS rejected={len(wrongs)}')
    b=budget();assert b['row_schedule_estimate']==6119861 and b['measured_frame_fps'] is None
    assert sum(r['row_cycles'] is not None for r in b['stages'])==19
    print('C1_R2_OPERATOR_BUDGET_GATE_PASS row_estimate=6119861 operator_stages=19 measured_frame_fps=unknown')
    if not args.sim_only: print('C1_R2_OPERATOR_PHYSICAL_GATE_PASS '+json.dumps(physical(ROOT/'logs/efinity_resource_runs/c1_ti60_r2_operator96_i3_20260913_a')))
