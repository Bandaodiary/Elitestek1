"""Read-only layer-cycle diagnosis; deliberately NOT a paired FPS benchmark."""
import json
from pathlib import Path
import check_r2_rgb2_host_evidence as c31


def main():
    old=c31.ROOT/'logs/r2_camera_host_xsim_runs/c26_camera_host_xsim_native_sixframe_20260913_a'
    new=c31.ROOT/'logs/r2_rgb2_host_xsim_runs/c31_rgb2_native_sixframe_20260914_c'
    a=json.loads(c31.read(old/'status.json'));b=json.loads(c31.read(new/'status.json'))
    c31.need(a['state']=='complete' and b['state']=='failed','diagnostic evidence scope changed')
    steps=json.loads(c31.read(new/'plan_manifest.json'))['steps']
    old_steps=json.loads(c31.read(old/'plan_manifest.json'))['steps']
    c31.need(steps==old_steps,'different generated execution plans')
    values=[]
    for folder,file,prefix,tag in ((old,'result.log','C1_R2_CAMERA_HOST_SYSTEM_',9),(new,'xsim.tail.log',c31.P,20)):
        text=c31.read(folder/file)
        rows=[r for r in c31.rows(text,'STAGE',prefix) if r['tag']==tag]
        frame=[r for r in c31.rows(text,'FRAME',prefix) if r['tag']==tag]
        c31.need(len(frame)==1 and [r['stage'] for r in rows]==list(range(22)),'complete observed per-job trace missing')
        c31.need(rows[-1]['cycles']==frame[0]['cycles'],'stage/frame timing inconsistent')
        previous=0;deltas=[]
        for r in rows:
            c31.need(r['cycles']>previous,'nonmonotonic stage cycle')
            deltas.append(r['cycles']-previous);previous=r['cycles']
        values.append((deltas,frame[0]))
    for key in ('read_beats','write_beats','producers','commits'):
        c31.need(values[0][1][key]==values[1][1][key],'different CNN job traffic')
    layers=[dict(index=i,name=s['name'],c26_cycles=values[0][0][i],c31_cycles=values[1][0][i],
                 delta=values[1][0][i]-values[0][0][i]) for i,s in enumerate(steps)]
    settings=('memory_div','command_latency','stalls','aw_wait_w')
    print('C31_NATIVE_DIAGNOSTIC '+json.dumps(dict(
        c26_settings={k:a[k] for k in settings},c31_settings={k:b[k] for k in settings},
        same_plan=True,same_CNN_traffic=True,paired_comparison=False,c31_cpu_coverage_passed=False,
        c26_last_job_cycles=values[0][1]['cycles'],c31_last_job_cycles=values[1][1]['cycles'],
        job_cycle_delta=values[1][1]['cycles']-values[0][1]['cycles'],
        largest_positive_deltas=sorted(layers,key=lambda r:r['delta'],reverse=True)[:5],
        full_native_signoff=False,fps_claim=False),separators=(',',':')))
    print('C31_NATIVE_DIAGNOSTIC_PASS layers=22 matched_plan=1 matched_CNN_traffic=1 different_AW_policy=1 causal_RTL_regression_claim=0')


if __name__=='__main__':main()
