"""Check R2-C RGB row evidence; no whole-frame or whole-system claims."""
import json,re
from pathlib import Path
from check_r2_pw_tile_evidence import fields

ROOT=Path(__file__).resolve().parents[1]


def simulation(text):
    lines=text.splitlines();meta_lines=[s for s in lines if s.startswith('C1_R2_RGB_VECTORS ')]
    if len(meta_lines)!=1:raise ValueError('missing/duplicate metadata')
    meta=json.loads(meta_lines[0].split(' ',1)[1]);jobs=meta['jobs']
    if len(jobs)!=13 or sum(j['vectors'] for j in jobs)!=meta['vectors']:raise ValueError('invalid metadata')
    rows=[fields(s) for s in lines if s.startswith('C1_R2_RGB_JOB ')]
    passes=[fields(s) for s in lines if s.startswith('C1_R2_RGB_PASS ')]
    if len(rows)!=26 or len(passes)!=2:raise ValueError('incomplete configurations')
    for mode in (0,1):
        group=[r for r in rows if r['stalls']==mode]
        if [r['job'] for r in group]!=list(range(13)):raise ValueError('missing/duplicate jobs')
        for row,job in zip(group,jobs):
            if row['width']!=job['width'] or row['vectors']!=job['vectors']:raise ValueError('incorrect dimensions')
            if row['ram_windows']!=job['vectors'] or row['ram_read_cycles']!=job['vectors']*2 or row['mac_beats']!=job['vectors']*5:
                raise ValueError('wrong read/compute schedule')
            lower=row['mac_beats']+15
            if row['start_to_last']<lower or (not mode and (row['start_to_last']!=lower or row['blocked'] or row['mac_blocked'])):
                raise ValueError('invalid continuous throughput')
        complete=[r for r in passes if r['stalls']==mode]
        if len(complete)!=1:raise ValueError('missing completion')
        row=complete[0]
        if row['jobs']!=13 or row['vectors']!=meta['vectors'] or row['windows_checked']!=meta['vectors']:
            raise ValueError('incomplete pixel/window checking')
        if row['reset_inflight']!=2 or row['invalid_extents']!=2 or row['rejected_load_cycles']<20:
            raise ValueError('missing reset/ownership checks')
        if row['blocked']!=sum(r['blocked'] for r in group) or row['mac_blocked']!=sum(r['mac_blocked'] for r in group):
            raise ValueError('stall counters differ')
        if mode and (row['blocked']<20 or row['mac_blocked']<20):raise ValueError('backpressure not exercised')
    if 'C1_R2_RGB_CLEAN temporary_vectors_and_simulator_removed=1' not in lines or any('ERROR' in s or 'FATAL' in s for s in lines):
        raise ValueError('errors or missing cleanup')
    return dict(configs=2,jobs_per_config=13,vectors_per_config=meta['vectors'],
                scalars_per_config=sum(j['scalars'] for j in jobs),
                trained_scalars_per_config=sum(j['scalars'] for j in jobs if j['label'].startswith('qat_')),
                native_width_row_cycles=1615,scope='preloaded RGB3 row compute, not full native frame')


def physical(run,ram,slices):
    def read(name):return (run/name).read_text(encoding='utf-8-sig')
    status=json.loads(read('status.json'));summary=json.loads(read('summary.json'))
    if status['state']!='complete' or status['exit_code']!=0 or summary['flow']!='map+pnr' or summary['pnr_exit_code']!=0:
        raise ValueError('physical run incomplete')
    if summary['device']!='Ti60F225' or summary['family']!='Titanium' or '--timing_model I3 ' not in read('efinity.pnr.stdout.tail.log'):
        raise ValueError('wrong device/grade')
    metrics=summary['metrics'];resources=summary['pnr_resources'];timing=summary['timing']
    if metrics['primitive_counts'].get('EFX_DSP24')!=96 or metrics['primitive_counts'].get('EFX_DSP48')!=12:
        raise ValueError('missing MAC/quantizer lanes')
    if resources['dsp_blocks_used']!=108 or resources['dsp_blocks_total']!=160:raise ValueError('DSP mismatch')
    if resources['memory_blocks_used']!=ram or resources['memory_blocks_total']!=256 or metrics['module']['rams']!=ram:
        raise ValueError('RAM inference mismatch')
    memories=[r for r in metrics['module_rows'] if '+g_ram[' in r]
    window_rows=[r for r in metrics['module_rows'] if '+u_window:' in r]
    if not memories or len(memories)>slices or len(window_rows)!=1:
        raise ValueError('missing feature RAM slices')
    def memory_counts(row):
        counts=re.findall(r'(\d+)\((\d+)\)',row)
        if len(counts)!=7:raise ValueError('invalid module metric columns')
        return tuple(map(int,counts[5]))
    # Synthesis can hoist a slice into u_window, removing its empty child row.
    # Audit exclusive counts + parent hoists; summing inclusive counts would
    # double count. Do not equate a missing hierarchy name with missing RAM.
    per_slice=ram//slices
    window_total,hoisted=memory_counts(window_rows[0])
    children=[memory_counts(r) for r in memories]
    if window_total!=ram or any(a!=b or b not in (0,per_slice) for a,b in children):
        raise ValueError('physical slice shape differs')
    positive=sum(b>0 for _,b in children)
    if hoisted!=(slices-positive)*per_slice or hoisted+sum(b for _,b in children)!=ram:
        raise ValueError('missing/duplicated RAM after hierarchy hoists')
    if not 0<resources['xlr_cells_used']<=60800 or resources['xlr_cells_total']!=60800:raise ValueError('XLR mismatch')
    if timing['final_slack_ns']<0 or timing['final_hold_slack_ns']<0 or abs(timing['final_period_ns']+timing['final_slack_ns']-6.666)>0.002:
        raise ValueError('150 MHz timing gate failed')
    return dict(run=run.name,dsp=108,ram=ram,xlr=resources['xlr_cells_used'],ff=metrics['module']['ff'],
                setup_ns=timing['final_slack_ns'],hold_ns=timing['final_hold_slack_ns'],
                estimated_internal_fmax_MHz=timing['final_frequency_mhz'],scope='I3 row core only; no DDR, CPU, video or I/O constraints')


if __name__=='__main__':
    log=(ROOT/'logs/r2_rgb_row_probe_20260913_e.log').read_text(encoding='utf-8-sig')
    print('C1_R2_RGB_SIM_GATE_PASS '+json.dumps(simulation(log)))
    rejected=0
    for bad in (log.replace('start_to_last=1615','start_to_last=1616',1),
                log.replace('ram_windows=320','ram_windows=321',1),
                log.replace('windows_checked=2459','windows_checked=2458',1),
                log.replace('reset_inflight=2','reset_inflight=1',1),
                log.replace('C1_R2_RGB_CLEAN','MISSING_CLEAN'),log+'\nFATAL: injected evidence corruption\n'):
        try:simulation(bad)
        except ValueError:rejected+=1
        else:raise AssertionError('corrupt evidence accepted')
    print(f'C1_R2_RGB_CHECKER_NEGATIVE_PASS rejected={rejected}')
    for variant,ram,slices in (('a',48,24),('b',48,12),('c',24,12)):
        run=ROOT/f'logs/efinity_resource_runs/c1_ti60_r2_rgb96_i3_20260913_{variant}'
        print('C1_R2_RGB_PHYSICAL_GATE_PASS '+json.dumps(physical(run,ram,slices)))
