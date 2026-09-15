"""Fail-closed checks for R2-B retained simulation/physical evidence.

No files are modified. Physical checks consume the runner's extracted summary,
including the actual PNR command; this is not an independent rerun of PNR.
"""
import json,re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]


def fields(line):
    return {key:int(value) for key,value in re.findall(r'(\w+)=(\d+)',line)}


def simulation(text):
    lines=text.splitlines()
    meta_lines=[s for s in lines if s.startswith('C1_R2_PW_VECTORS ')]
    if len(meta_lines)!=1: raise ValueError('missing or duplicate vector metadata')
    meta=json.loads(meta_lines[0].split(' ',1)[1]);jobs=meta['jobs']
    if len(jobs)!=13 or sum(j['vectors'] for j in jobs)!=meta['vectors']: raise ValueError('invalid job metadata')
    job_rows=[fields(s) for s in lines if s.startswith('C1_R2_PW_JOB ')]
    passes=[fields(s) for s in lines if s.startswith('C1_R2_PW_PASS ')]
    if len(job_rows)!=26 or len(passes)!=2: raise ValueError('incomplete test configuration set')
    for mode in (0,1):
        selected=[r for r in job_rows if r['stalls']==mode]
        if [r['job'] for r in selected]!=list(range(13)): raise ValueError('missing/duplicated job')
        for row,job in zip(selected,jobs):
            if row['pixels']!=job['pixels'] or row['vectors']!=job['vectors']: raise ValueError('job dimensions differ')
            if row['start_to_last']!=row['vectors']+12+row['blocked']: raise ValueError('unaccounted throughput loss')
            if not mode and (row['blocked'] or row['output_span']!=row['vectors']): raise ValueError('noncontinuous output')
        passed=[r for r in passes if r['stalls']==mode]
        if len(passed)!=1: raise ValueError('missing completion mode')
        row=passed[0]
        if row['jobs']!=13 or row['vectors']!=meta['vectors'] or row['reset_inflight']!=2 or row['invalid_extents']!=2:
            raise ValueError('incomplete functional coverage')
        if row['blocked']!=sum(r['blocked'] for r in selected) or (mode and row['blocked']<20) or row['rejected_load_cycles']<20:
            raise ValueError('backpressure/ownership coverage missing')
    if 'C1_R2_PW_CLEAN temporary_vectors_and_simulator_removed=1' not in lines or any('FATAL' in s or 'ERROR' in s for s in lines):
        raise ValueError('error or missing cleanup marker')
    return dict(configs=2,jobs_per_config=13,scalars_per_config=sum(j['scalars'] for j in jobs),
                trained_scalars_per_config=sum(j['scalars'] for j in jobs if j['label'].startswith('qat_')),
                vectors_per_config=meta['vectors'],native_row_cycles=866,scope='pointwise tile compute only, no host load or DMA')


def physical(run,expected_ram):
    def read(name):return (run/name).read_text(encoding='utf-8-sig')
    status=json.loads(read('status.json'));summary=json.loads(read('summary.json'))
    if status['state']!='complete' or status['exit_code']!=0 or summary['flow']!='map+pnr' or summary['pnr_exit_code']!=0:
        raise ValueError('physical run not complete')
    if summary['family']!='Titanium' or summary['device']!='Ti60F225' or '--timing_model I3 ' not in read('efinity.pnr.stdout.tail.log'):
        raise ValueError('wrong device or grade')
    metrics=summary['metrics']; resources=summary['pnr_resources'];timing=summary['timing']
    if metrics['primitive_counts'].get('EFX_DSP24')!=96 or metrics['primitive_counts'].get('EFX_DSP48')!=12:
        raise ValueError('array/quantizer DSP evidence differs')
    if resources['dsp_blocks_used']!=108 or resources['dsp_blocks_total']!=160:
        raise ValueError('DSP capacity differs')
    if resources['memory_blocks_used']!=expected_ram or resources['memory_blocks_total']!=256 or metrics['module']['rams']!=expected_ram:
        raise ValueError('unexpected RAM inference')
    ram_rows=[r for r in metrics['module_rows'] if '+g_ram[' in r]
    if len(ram_rows)!=8 or any(not re.search(r'2\(2\)\s+0\(0\)\s*$',r) for r in ram_rows):
        raise ValueError('eight physical feature RAM slices not retained')
    if not 0<resources['xlr_cells_used']<=60800 or resources['xlr_cells_total']!=60800:
        raise ValueError('XLR budget differs')
    if timing['final_slack_ns']<0 or timing['final_hold_slack_ns']<0 or abs(timing['final_period_ns']+timing['final_slack_ns']-6.666)>0.002:
        raise ValueError('150 MHz setup/hold gate failed')
    return dict(run=run.name,dsp=108,ram=expected_ram,xlr=resources['xlr_cells_used'],ff=metrics['module']['ff'],
                setup_ns=timing['final_slack_ns'],hold_ns=timing['final_hold_slack_ns'],
                estimated_internal_fmax_MHz=timing['final_frequency_mhz'],scope='Ti60F225 I3 tile only, no peripheral or I/O timing signoff')


if __name__=='__main__':
    log=(ROOT/'logs/r2_pw_tile_probe_20260913_f.log').read_text(encoding='utf-8-sig')
    print('C1_R2_PW_SIM_GATE_PASS '+json.dumps(simulation(log)))
    # Corrupt retained evidence in memory to ensure failures cannot be hidden
    # by merely retaining a PASS line. These are checker tests, not RTL faults.
    rejected=0
    for wrong in (log.replace('start_to_last=866','start_to_last=867',1),
                  log.replace('reset_inflight=2','reset_inflight=1',1),
                  log.replace('stalls=1 jobs=13','stalls=0 jobs=13',1),
                  log.replace('C1_R2_PW_CLEAN','MISSING_CLEAN'),
                  log+'\nFATAL: injected evidence corruption\n'):
        try: simulation(wrong)
        except ValueError: rejected+=1
        else: raise AssertionError('corrupt evidence accepted')
    print(f'C1_R2_PW_CHECKER_NEGATIVE_PASS rejected={rejected}')
    for variant,ram in (('a',28),('b',28),('c',16)):
        run=ROOT/f'logs/efinity_resource_runs/c1_ti60_r2_pw96_i3_20260913_{variant}'
        print('C1_R2_PW_PHYSICAL_GATE_PASS '+json.dumps(physical(run,ram)))
