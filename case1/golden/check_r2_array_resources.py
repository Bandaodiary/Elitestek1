"""Audit retained R2 primitive evidence, not board-level timing or capacity."""
import json,re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def xlr_record(text):
    matches=re.findall(r'^\s*XLR(?: Cells|s):\s*([\d,]+)\s*/\s*([\d,]+)\s*\(([\d.]+)%',text,re.M)
    if len(matches)!=1:raise ValueError('missing/duplicate physical XLR total')
    used,total,pct=matches[0];used=int(used.replace(',',''));total=int(total.replace(',',''))
    if total!=60800 or not 0<used<=total or abs(used/total*100-float(pct))>0.01:
        raise ValueError('inconsistent physical XLR count')
    return used

def check(run,rows):
    def read(name):return (run/name).read_text(encoding='utf-8-sig')
    status=json.loads(read('status.json'));s=json.loads(read('summary.json'))
    if status['state']!='complete' or status['exit_code']!=0 or s['flow']!='map+pnr' or s['pnr_exit_code']!=0:
        raise ValueError('not a completed physical probe')
    if s['family']!='Titanium' or s['device']!='Ti60F225' or '--timing_model I3 ' not in read('efinity.pnr.stdout.tail.log'):
        raise ValueError('incorrect target or speed/temperature grade')
    products=rows*16
    if s['metrics']['primitive_counts'].get('EFX_DSP24')!=products or s['pnr_resources']['dsp_blocks_total']!=160:
        raise ValueError('missing complete multiplication array/device budget')
    physical=s['pnr_resources']['dsp_blocks_used']
    if not 0<physical<=160:raise ValueError('physical DSP budget failed')
    t=s['timing']
    if t['final_slack_ns'] is None or t['final_slack_ns']<0 or t['final_hold_slack_ns'] is None or t['final_hold_slack_ns']<0:
        raise ValueError('primitive setup/hold gate failed')
    xlr=xlr_record(read('resource_lines.sample.log'))
    return dict(run=run.name,rows=rows,logical_products=products,physical_dsp=physical,
                xlr=xlr,wrapper_ff=s['metrics']['module']['ff'],ram=s['pnr_resources']['memory_blocks_used'],
                timing_model='I3',constraint_MHz=100,internal_estimated_fmax_MHz=t['final_frequency_mhz'],
                setup_slack_ns=t['final_slack_ns'],hold_slack_ns=t['final_hold_slack_ns'],
                scope='host-loaded MAC only; no tile ports, requant, DDR, CPU, peripheral or board signoff')

if __name__=='__main__':
    for products,rows in ((96,6),(128,8)):
        run=ROOT/f'logs/efinity_resource_runs/c1_ti60_r2_array{products}_i3_20260913_b'
        print('C1_R2_PHYSICAL_GATE_PASS '+json.dumps(check(run,rows),separators=(',',':')))
