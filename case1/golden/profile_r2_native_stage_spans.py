"""Bounded read-only stage-span diagnosis, not a native-FPS acceptance gate.

An in-flight run contributes only completed CNN frame records. Spans include
memory waits and write drain, not just MAC computation; no causal A/B claim.
"""
import argparse
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
VERSIONS={
    'c31':('r2_rgb2_host_xsim_runs','c1_r2_rgb2_host_xsim_','C1_R2_RGB2_HOST_SYSTEM_'),
    'c33':('r2_credit_rgb2_host_xsim_runs','c1_r2_credit_rgb2_host_xsim_','C1_R2_CREDIT_RGB2_HOST_SYSTEM_'),
}


def fields(line,prefix):
    assert line.startswith(prefix)
    result={}
    for token in line[len(prefix):].split():
        assert re.fullmatch(r'[A-Za-z_]+=[0-9]+',token),'malformed stage/frame event'
        key,value=token.split('=');assert key not in result;result[key]=int(value)
    return result


def frames_from_text(text,prefix,stage_count):
    assert not re.search(r'FATAL|ERROR:|Traceback',text),'failure in sampled log'
    active={};complete=[];closed=set()
    # A live writer can be in the middle of its last output line.
    lines=text.splitlines()
    if text and not text.endswith(('\n','\r')):lines=lines[:-1]
    for line in lines:
        if line.startswith(prefix+'STAGE '):
            event=fields(line,prefix+'STAGE ');tag=event['tag']
            assert tag not in closed,'events after frame completion'
            sequence=active.setdefault(tag,[])
            assert event['stage']==len(sequence)<stage_count,'missing/duplicate/out-of-order stage'
            assert event['cycles']>(sequence[-1]['cycles'] if sequence else 0),'non-increasing completion time'
            if sequence:assert event['words']>=sequence[-1]['words'],'decreasing written word count'
            sequence.append(event)
        elif line.startswith(prefix+'FRAME '):
            frame=fields(line,prefix+'FRAME ');tag=frame['tag']
            assert tag not in closed and tag in active,'frame lacks independent stage records'
            sequence=active.pop(tag)
            assert len(sequence)==frame['commits']==stage_count
            assert (frame['width'],frame['height'],frame['stalls'])==(640,480,0)
            assert sequence[-1]['cycles']==frame['cycles'],'stage spans do not cover frame interval'
            assert sequence[-1]['words']==frame['write_beats'],'stage/frame write accounting differs'
            previous=0;spans=[]
            for event in sequence:spans.append(event['cycles']-previous);previous=event['cycles']
            assert sum(spans)==frame['cycles']
            complete.append(dict(tag=tag,cycles=frame['cycles'],stage_spans=spans,
                                 read_beats=frame['read_beats'],write_beats=frame['write_beats']))
            closed.add(tag)
    return complete,{tag:len(events) for tag,events in active.items()}


def profile(version,name):
    assert version in VERSIONS and re.fullmatch(r'[A-Za-z0-9_-]+',name)
    directory,private_prefix,prefix=VERSIONS[version];folder=ROOT/'logs'/directory/name
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    assert status['run_id']==name and status['state'] in ('running','complete') and status['profile']=='microstyle24'
    assert (status['width'],status['height'],status['stalls'],status['aw_wait_w'],status['memory_div'],
            status['command_latency'],status['frame_divisor'])==(640,480,0,2,2,20,2)
    if status['state']=='running':
        private=(ROOT/'sim'/(private_prefix+name)).resolve()
        assert Path(status['run_directory']).resolve()==private
        path=private/'xsim.stdout.log'
    else:path=folder/'result.log'
    assert path.stat().st_size<=1024*1024,'refusing unbounded simulator-log read'
    # Windows xsim stdout may start with an OEM-codepage command banner.
    # Numerical event records are ASCII. Latin-1 preserves every byte without
    # dropping a possible error marker; reject UTF-16 rather than misparse it.
    payload=path.read_bytes();assert len(payload)<=1024*1024 and b'\x00' not in payload
    text=payload.decode('latin-1')
    manifest=json.loads((ROOT/'model/r2_microstyle24_bound_plan/manifest.json').read_text(encoding='utf-8-sig'))
    steps=manifest['steps'];assert len(steps)==22 and [s['index'] for s in steps]==list(range(22))
    frames,pending=frames_from_text(text,prefix,len(steps))
    assert frames,'no completed CNN to profile yet'
    steady=frames[1:]  # Do not mix the first job, before regular scanout, into later observations.
    rows=[]
    if steady:
        mean=sum(f['cycles'] for f in steady)/len(steady)
        for i,step in enumerate(steps):
            spans=[f['stage_spans'][i] for f in steady]
            rows.append(dict(index=i,name=step['name'],mean_cycles=sum(spans)/len(spans),
                min_cycles=min(spans),max_cycles=max(spans),span_share_percent=100*sum(spans)/len(spans)/mean))
    return dict(version=version,run=name,observed_state=status['state'],bytes_read=len(payload),
        completed_CNNs=len(frames),incomplete_frame_stages=pending,steady_samples=len(steady),
        first_frame_cycles=frames[0]['cycles'],later_frame_cycles=[f['cycles'] for f in steady],
        stages=rows,top_stages=sorted(rows,key=lambda r:r['mean_cycles'],reverse=True)[:6],
        native_fps_acceptance=False,MAC_utilization_measurement=False,causal_AB_comparison=False,
        process_liveness_not_inferred=True,board_claim=False)


def selftest():
    prefix=VERSIONS['c33'][2]
    lines=[prefix+f'STAGE tag=0 stage={i} cycles={i+1} words={i+1}' for i in range(22)]
    lines.append(prefix+'FRAME width=640 height=480 stalls=0 tag=0 cycles=22 read_beats=30 write_beats=22 commits=22')
    original='\n'.join(lines)+'\n'
    frames,pending=frames_from_text(original,prefix,22)
    assert len(frames)==1 and frames[0]['stage_spans']==[1]*22 and not pending
    partial=original+prefix+'STAGE tag=2 stage=0 cycles=3 words=2\n'+prefix+'STAGE tag=2 stage='
    assert frames_from_text(partial,prefix,22)[1]=={2:1}
    corruptions=[original.replace(lines[3]+'\n',''),original.replace('stage=3 ','stage=2 '),
        original.replace('stage=3 cycles=4','stage=3 cycles=2'),original.replace('commits=22','commits=21'),
        original.replace('write_beats=22','write_beats=23'),original.replace('tag=0 cycles=22 read','tag=0 cycles=23 read'),
        original+lines[-1]+'\n',original+'FATAL: synthetic\n']
    for bad in corruptions:
        assert bad!=original
        try:frames_from_text(bad,prefix,22)
        except (AssertionError,ValueError,KeyError):pass
        else:raise AssertionError('bad stage profile accepted')
    print('R2_STAGE_PROFILE_SELFTEST_PASS '+json.dumps(dict(rejected=len(corruptions),partial_line_ignored=True,
        synthetic_only=True,RTL_executed=False),separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--c31');p.add_argument('--c33');p.add_argument('--selftest',action='store_true')
    a=p.parse_args()
    if a.selftest:selftest()
    for version in ('c31','c33'):
        if getattr(a,version):print('R2_NATIVE_STAGE_PROFILE '+json.dumps(profile(version,getattr(a,version)),separators=(',',':')))
