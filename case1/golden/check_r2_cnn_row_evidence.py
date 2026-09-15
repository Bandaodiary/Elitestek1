"""Fail-closed evidence checks for C3; not a whole-network or board signoff."""
from __future__ import annotations
import argparse, json, re
from pathlib import Path
from check_r2_pw_tile_evidence import fields
from r2_cnn_schedule_budget import row_cycles, budget

ROOT = Path(__file__).resolve().parents[1]


def simulation(text):
    lines = text.splitlines()
    metadata = [s for s in lines if s.startswith('C1_R2_CNN_VECTORS ')]
    if len(metadata) != 1: raise ValueError('missing/duplicate metadata')
    meta = json.loads(metadata[0].split(' ', 1)[1]); jobs = meta['jobs']
    if len(jobs) != 65 or meta['commands'] != sum(j['loads']+1 for j in jobs): raise ValueError('wrong job plan')
    if [sum(j['mode'] == mode for j in jobs) for mode in range(4)] != [13, 13, 25, 14]: raise ValueError('missing operator coverage')
    if meta['vectors'] != 46362 or sum(j['vectors'] for j in jobs) != meta['vectors']: raise ValueError('wrong vector total')
    if meta['scalars'] != 255937 or sum(j['scalars'] for j in jobs) != meta['scalars']: raise ValueError('wrong scalar total')
    if meta['trained_scalars'] != 119040 or sum(j['scalars'] for j in jobs if j['trained']) != meta['trained_scalars']: raise ValueError('missing trained coverage')
    native = {j['label'] for j in jobs if j['trained']}
    wanted = {f'qat_stage{s}_row{y}' for s, height in ((3,1),(7,1),(11,1),(15,2),(18,4),(19,4),(20,4)) for y in range(height)}
    wanted |= {f'qat_stage{s}' for s in (5,9,13)}
    if native != wanted: raise ValueError('wrong trained stages')
    rows = [fields(s) for s in lines if s.startswith('C1_R2_CNN_JOB ')]
    passes = [fields(s) for s in lines if s.startswith('C1_R2_CNN_PASS ')]
    if len(rows) != 130 or len(passes) != 2: raise ValueError('incomplete simulation variants')
    for stalls in (0,1):
        records = [r for r in rows if r['stalls'] == stalls]
        if [r['job'] for r in records] != list(range(65)): raise ValueError('missing/duplicate job result')
        total_windows = total_zero_masks = 0
        for r, j in zip(records, jobs):
            if any(r[k] != j[k] for k in ('mode','size','vectors')): raise ValueError('wrong job identity')
            groups = j['channels']//8; windows = ((j['size']+1)//2)*groups if j['mode'] in (1,2) else 0
            total_windows += windows
            if j['mode'] == 2 and j['size']%2: total_zero_masks += groups
            cycles = row_cycles(j['mode'], j['size'], j['channels'])
            if r['groups'] != groups or r['windows'] != windows or r['ram_reads'] != 2*windows: raise ValueError('wrong SRAM work')
            if r['mac_beats'] != j['vectors']*(5 if j['mode'] == 1 else 1): raise ValueError('wrong MAC work')
            if r['cycles'] < cycles or (not stalls and r['cycles'] != cycles): raise ValueError('wrong schedule')
        complete = [r for r in passes if r['stalls'] == stalls]
        if len(complete) != 1: raise ValueError('missing/duplicate pass')
        p = complete[0]
        changes = sum(a['mode'] != b['mode'] for a,b in zip(jobs,jobs[1:]))
        want = dict(jobs=65, vectors=46362, mode_changes=changes, windows=total_windows,
                    zero_masks=total_zero_masks, reset_inflight=3, invalid_commands=18)
        if any(p[k] != v for k,v in want.items()): raise ValueError('missing ownership/reset/tail coverage')
        if min(p['busy_rejections'], p['full_slots'], p['simultaneous_push_pop']) < 20 or (stalls and p['blocked'] < 20):
            raise ValueError('no pressure coverage')
    if lines.count('C1_R2_CNN_CLEAN temporary_vectors_and_simulator_removed=1') != 1 or any('FATAL' in s or 'ERROR' in s for s in lines):
        raise ValueError('error or absent cleanup marker')
    return dict(configs=2, jobs_per_config=65, vectors_per_config=46362, scalars_per_config=255937,
                trained_scalars_per_config=119040, dw640c16_cycles=1935, dw320c24_cycles=1455,
                dw160c48_cycles=1455, residual3840_cycles=653, scope='SRAM row jobs; no DMA/graph/frame proof')


def physical(run):
    def read(name): return (run/name).read_text(encoding='utf-8-sig')
    state = json.loads(read('status.json')); s = json.loads(read('summary.json'))
    if state['state'] != 'complete' or state['exit_code'] != 0 or s['flow'] != 'map+pnr' or s['pnr_exit_code'] != 0:
        raise ValueError('physical run incomplete')
    if s['family'] != 'Titanium' or s['device'] != 'Ti60F225' or '--timing_model I3 ' not in read('efinity.pnr.stdout.tail.log'):
        raise ValueError('wrong target')
    metrics = s['metrics']; resources = s['pnr_resources']; timing = s['timing']
    if metrics['primitive_counts'].get('EFX_DSP24') != 96 or metrics['primitive_counts'].get('EFX_DSP48') != 12:
        raise ValueError('duplicated/pruned compute')
    if (resources['dsp_blocks_used'], resources['dsp_blocks_total']) != (108,160) or (resources['memory_blocks_used'], resources['memory_blocks_total']) != (64,256):
        raise ValueError('unexpected DSP/RAM footprint')
    def counts(fragment):
        found = [row for row in metrics['module_rows'] if fragment in row]
        if len(found) != 1: raise ValueError('missing/duplicate hierarchy '+fragment)
        columns = re.findall(r'(\d+)\((\d+)\)', found[0])
        if len(columns) != 7: raise ValueError('bad hierarchy columns')
        return [int(a) for a,_ in columns]
    if counts('+u_compute:')[-2:] != [0,108] or counts('+u_mac:')[-1] != 96 or counts('+u_quant:')[-1] != 12:
        raise ValueError('not exactly one compute hierarchy')
    if counts('+u_linear:')[-2:] != [16,0] or counts('+u_spatial:')[-2:] != [48,0]: raise ValueError('bad feeder resource sharing')
    if resources['xlr_cells_total'] != 60800 or not 0 < resources['xlr_cells_used'] <= 60800: raise ValueError('invalid XLR footprint')
    if timing['final_slack_ns'] < 0 or timing['final_hold_slack_ns'] < 0 or abs(timing['final_period_ns']+timing['final_slack_ns']-6.666) > .002:
        raise ValueError('150 MHz core setup/hold failed')
    return dict(run=run.name, dsp=108, ram=64, xlr=resources['xlr_cells_used'], ff=metrics['module']['ff'],
                setup_ns=timing['final_slack_ns'], hold_ns=timing['final_hold_slack_ns'],
                estimated_internal_fmax_MHz=timing['final_frequency_mhz'], scope='core-only, not CPU/DDR/video/board')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim-only', action='store_true')
    parser.add_argument('--run-id', default='c1_ti60_r2_cnn96_i3_20260913_b')
    parser.add_argument('--sim-log', default='r2_cnn_row_probe_20260913_c.log')
    args = parser.parse_args()
    log = (ROOT/'logs'/args.sim_log).read_text(encoding='utf-8-sig')
    print('C1_R2_CNN_SIM_GATE_PASS '+json.dumps(simulation(log)))
    wrong_logs = (log.replace('cycles=1935','cycles=1936',1), log.replace('ram_reads=640','ram_reads=639',1),
                  log.replace('mode_changes=54','mode_changes=53',1), log.replace('zero_masks=44','zero_masks=0',1),
                  log.replace('reset_inflight=3','reset_inflight=2',1), log.replace('invalid_commands=18','invalid_commands=17',1),
                  log.replace('C1_R2_CNN_CLEAN','MISSING_CLEAN'), log+'\nFATAL: injected bad evidence\n')
    for wrong in wrong_logs:
        assert wrong != log
        try: simulation(wrong)
        except ValueError: pass
        else: raise AssertionError('corrupt evidence accepted')
    print(f'C1_R2_CNN_CHECKER_NEGATIVE_PASS rejected={len(wrong_logs)}')
    b = budget(); assert b['mixed_schedule_cycles'] == 6098030 and b['measured_frame_fps'] is None
    print('C1_R2_CNN_BUDGET_GATE_PASS mixed_cycles=6098030 measured_frame_fps=unknown')
    if not args.sim_only:
        current = physical(ROOT/'logs/efinity_resource_runs'/args.run_id)
        print('C1_R2_CNN_PHYSICAL_GATE_PASS '+json.dumps(current))
        if args.run_id == 'c1_ti60_r2_cnn96_i3_20260913_b':
            before = physical(ROOT/'logs/efinity_resource_runs/c1_ti60_r2_cnn96_i3_20260913_a')
            previous_log = (ROOT/'logs/r2_cnn_row_probe_20260913_b.log').read_text(encoding='utf-8-sig')
            simulation(previous_log)
            def schedules(value): return [s for s in value.splitlines() if s.startswith('C1_R2_CNN_JOB ')]
            if schedules(previous_log) != schedules(log) or current['xlr'] >= before['xlr']:
                raise ValueError('fixed DW map did not preserve schedule or save XLR')
            print('C1_R2_CNN_OPTIMIZATION_GATE_PASS '+json.dumps(dict(before_xlr=before['xlr'], after_xlr=current['xlr'],
                  saved_xlr=before['xlr']-current['xlr'], unchanged_job_schedules=130, unchanged_dsp=108, unchanged_ram=64)))


if __name__ == '__main__': main()
