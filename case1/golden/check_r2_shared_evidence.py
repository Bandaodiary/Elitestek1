"""Fail-closed checks of the shared-engine evidence, not whole-graph signoff."""
import argparse,json,re
from pathlib import Path
from check_r2_pw_tile_evidence import fields

ROOT=Path(__file__).resolve().parents[1]


def simulation(text):
    lines=text.splitlines()
    metadata=[s for s in lines if s.startswith('C1_R2_SHARED_VECTORS ')]
    arithmetic=[s for s in lines if s.startswith('C1_R2_COMPUTE_VECTORS ')]
    if len(metadata)!=1 or len(arithmetic)!=1:raise ValueError('missing/duplicate metadata')
    meta=json.loads(metadata[0].split(' ',1)[1]);cm=json.loads(arithmetic[0].split(' ',1)[1]);jobs=meta['jobs']
    if len(jobs)!=28 or [j['mode'] for j in jobs]!=[0,1]*14 or sum(j['vectors'] for j in jobs)!=meta['vectors']:
        raise ValueError('incorrect job plan')
    if any(j['loads']!=0 for j in jobs[-2:]) or cm['nonfirst_affine_poisoned'] is not True or cm['trained_scalars']!=69120:
        raise ValueError('missing cached/affine coverage')
    rows=[fields(s) for s in lines if s.startswith('C1_R2_SHARED_JOB ')]
    passes=[fields(s) for s in lines if s.startswith('C1_R2_SHARED_PASS ')]
    if len(rows)!=56 or len(passes)!=2:raise ValueError('incomplete engine runs')
    for mode in (0,1):
        group=[r for r in rows if r['stalls']==mode]
        if [r['job'] for r in group]!=list(range(28)):raise ValueError('missing/duplicate result job')
        for row,job in zip(group,jobs):
            if any(row[k]!=job[k] for k in ('mode','size','vectors')):raise ValueError('incorrect job identity')
            beats=job['vectors']*(1 if job['mode']==0 else 5);cycles=beats+(12 if job['mode']==0 else 15)
            if row['mac_beats']!=beats or row['cycles']<cycles or (not mode and row['cycles']!=cycles):raise ValueError('wrong schedule')
        complete=[r for r in passes if r['stalls']==mode]
        if len(complete)!=1:raise ValueError('missing completion')
        r=complete[0]
        if any(r[k]!=v for k,v in dict(jobs=28,vectors=meta['vectors'],mode_changes=27,reset_inflight=2,invalid_commands=6,cached_jobs=2).items()):
            raise ValueError('engine coverage absent')
        if r['busy_rejections']<20 or (mode and r['blocked']<20):raise ValueError('ownership/backpressure not exercised')
    compute=[fields(s) for s in lines if s.startswith('C1_R2_COMPUTE_PASS ')]
    if sorted((r['depth'],r['stalls']) for r in compute)!=[(2,0),(2,1),(8,0),(8,1)]:raise ValueError('missing compute variants')
    for r in compute:
        if r['inputs']!=cm['inputs'] or r['outputs']!=cm['outputs'] or r['reset_partial']!=1:raise ValueError('incomplete compute stream')
        if r['depth']==8 and r['max_params']<6:raise ValueError('normal FIFO occupancy untested')
        if r['depth']==8 and not r['stalls'] and r['accept_span']!=cm['inputs']:raise ValueError('normal compute II not one')
        if r['depth']==2 and (r['max_params']!=2 or r['full_pop_push']<1):raise ValueError('full FIFO replacement untested')
        if r['stalls'] and r['blocked']<20:raise ValueError('compute output backpressure missing')
    if 'C1_R2_SHARED_CLEAN temporary_vectors_and_simulator_removed=1' not in lines or any('FATAL' in s or 'ERROR' in s for s in lines):
        raise ValueError('error or missing cleanup marker')
    return dict(engine_configs=2,jobs_per_config=28,scalars_per_config=sum(j['scalars'] for j in jobs),
                trained_engine_scalars_per_config=sum(j['scalars'] for j in jobs if j['label'].startswith('qat_')),
                compute_configs=4,trained_compute_scalars_per_config=cm['trained_scalars'],
                pw640_cycles=866,rgb640_cycles=1615,scope='PW/RGB SRAM integration; DW arithmetic only, no full graph/DMA')


def physical(run):
    def read(name):return (run/name).read_text(encoding='utf-8-sig')
    status=json.loads(read('status.json'));s=json.loads(read('summary.json'))
    if status['state']!='complete' or status['exit_code']!=0 or s['flow']!='map+pnr' or s['pnr_exit_code']!=0:raise ValueError('physical run incomplete')
    if s['family']!='Titanium' or s['device']!='Ti60F225' or '--timing_model I3 ' not in read('efinity.pnr.stdout.tail.log'):raise ValueError('wrong target')
    metrics=s['metrics'];r=s['pnr_resources'];t=s['timing'];rows=metrics['module_rows']
    if metrics['primitive_counts'].get('EFX_DSP24')!=96 or metrics['primitive_counts'].get('EFX_DSP48')!=12:raise ValueError('duplicated/pruned compute lanes')
    if (r['dsp_blocks_used'],r['dsp_blocks_total'])!=(108,160) or (r['memory_blocks_used'],r['memory_blocks_total'])!=(40,256):
        raise ValueError('unexpected physical resource footprint')
    def counts(fragment):
        selected=[line for line in rows if fragment in line]
        if len(selected)!=1:raise ValueError('missing/duplicate hierarchy '+fragment)
        c=re.findall(r'(\d+)\((\d+)\)',selected[0])
        if len(c)!=7:raise ValueError('bad hierarchy metric columns')
        return [int(a) for a,_ in c]
    if counts('+u_compute:')[-2:]!=[0,108] or counts('+u_mac:')[-1]!=96 or counts('+u_quant:')[-1]!=12:
        raise ValueError('not exactly one shared compute hierarchy')
    if counts('+u_pw:')[-2:]!=[16,0] or counts('+u_rgb:')[-2:]!=[24,0]:raise ValueError('feeder contains extra compute or missing SRAM')
    if r['xlr_cells_total']!=60800 or not 0<r['xlr_cells_used']<=60800:raise ValueError('invalid XLR footprint')
    if t['final_slack_ns']<0 or t['final_hold_slack_ns']<0 or abs(t['final_period_ns']+t['final_slack_ns']-6.666)>0.002:
        raise ValueError('150 MHz internal setup/hold gate failed')
    return dict(run=run.name,dsp=108,ram=40,xlr=r['xlr_cells_used'],ff=metrics['module']['ff'],
                setup_ns=t['final_slack_ns'],hold_ns=t['final_hold_slack_ns'],estimated_internal_fmax_MHz=t['final_frequency_mhz'],
                scope='shared PW/RGB engine, not CPU/DDR/video/board timing')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--log',default='logs/r2_c2_restored_probe_20260913_a.log')
    p.add_argument('--pnr-run',default='c2_shared_restore_i3_20260913_a');a=p.parse_args()
    log=(ROOT/a.log).read_text(encoding='utf-8-sig')
    print('C1_R2_SHARED_SIM_GATE_PASS '+json.dumps(simulation(log)))
    wrong_logs=(log.replace('cycles=866','cycles=867',1),log.replace('mode_changes=27','mode_changes=26',1),
                log.replace('cached_jobs=2','cached_jobs=0',1),log.replace('nonfirst_affine_poisoned": true','nonfirst_affine_poisoned": false',1),
                log.replace('full_pop_push=11619','full_pop_push=0',1),log.replace('C1_R2_SHARED_CLEAN','MISSING_CLEAN'),log+'\nFATAL: injected bad evidence\n')
    for wrong in wrong_logs:
        try:simulation(wrong)
        except ValueError:pass
        else:raise AssertionError('corrupt evidence accepted')
    print(f'C1_R2_SHARED_CHECKER_NEGATIVE_PASS rejected={len(wrong_logs)}')
    print('C1_R2_SHARED_PHYSICAL_GATE_PASS '+json.dumps(physical(ROOT/'logs/efinity_resource_runs'/a.pnr_run)))
