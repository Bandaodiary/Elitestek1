"""C35 full-DAG row-transfer simulation, original weights and integer oracle.

Run only from the isolated/budgeted detached worker. This is NOT AXI,
native-frame FPS, Efinity implementation or trained-model quality evidence.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from r2_row_fused_graph_vectors import vectors,ROOT
from r2_row_fused_plan import selftest as plan_selftest
from check_r2_shadow_engine_evidence import run_gate

TOP='tb_c1_r2_row_fused_graph'
PREFIX='C35_ROW_FUSED_GRAPH_'


def sources():
    todo=['c1_r2_row_fused_graph'];seen=set();paths=[]
    while todo:
        name=todo.pop()
        if name in seen or name in ('c1_r2_microstyle_plan','c1_r2_row_fusion_plan'):continue
        seen.add(name)
        candidates=[ROOT/'rtl'/d/(name+'.sv') for d in ('r2','common','cnn')]
        candidates=[p for p in candidates if p.is_file()]
        if len(candidates)!=1:raise ValueError('missing/ambiguous production module '+name)
        path=candidates[0];paths.append(path)
        text=path.read_text(encoding='utf-8-sig')
        text=re.sub(r'/\*.*?\*/|//[^\n]*','',text,flags=re.S)
        todo+=re.findall(r'^\s*(c1_\w+)\s*(?:#\s*\(|\w+\s*\()',text,flags=re.M)
    return paths


def fields(line):return {k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}


def run_case(parent,profile,w,h,stalls,enabled,negative=0):
    folder=parent/f'{profile}_{w}x{h}_s{stalls}_f{enabled}_n{negative}';folder.mkdir()
    m=vectors(folder,w,h,profile,bool(enabled))
    opts=dict(STALLS=stalls,FUSION_ENABLE=enabled,FUSED_DW_STAGE=m['dw_stage'],
        FUSED_PW_STAGE=m['pw_stage'],STAGE_COUNT=m['stage_count'],RGB_STAGE=m['rgb_stage'],
        MEMORY_DIV=2,COMMAND_LATENCY=20,SHADOW_NEGATIVE=negative)
    exe=folder/'simulation.vvp'
    cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,
         *[f'-P{TOP}.{k}={v}' for k,v in opts.items()],'-o',str(exe),
         *map(str,sources()),str(folder/'package/execution_plan.sv'),
         str(folder/'fusion_plan.sv'),str(ROOT/f'sim/{TOP}.sv')]
    c=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
    if c.returncode:raise RuntimeError('compile failed\n'+c.stderr[:1800]+'\n'+c.stderr[-1800:])
    cmd=['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}',f'+W={w}',f'+H={h}',
         f'+P={m["parameter_words"]}',f'+I={m["input_words"]}',f'+E={m["expected_words"]}',f'+DW={m["dw_packets"]}']
    r=subprocess.run(cmd,capture_output=True,text=True,timeout=900)
    if negative:
        if r.returncode==0 or 'graph tensor write not golden' not in r.stdout:
            raise RuntimeError('actual shadow corruption did not fail numerically\n'+r.stdout[-3500:]+r.stderr[-1000:])
        print(PREFIX+'NEGATIVE_PASS actual_shadow_RAM_corruption=1',flush=True)
        return None
    if r.returncode or r.stderr.strip() or re.search('FATAL|ERROR:',r.stdout):
        raise RuntimeError(f'failed {folder.name}\n'+r.stdout[-4000:]+r.stderr[-1000:])
    lines=r.stdout.splitlines()
    frame=[fields(x) for x in lines if x.startswith(PREFIX+'FRAME ')]
    shadow=[fields(x) for x in lines if x.startswith(PREFIX+'SHADOW ')]
    passed=[x for x in lines if x.startswith(PREFIX+'PASS ')]
    if len(frame)!=2 or len(shadow)!=2 or len(passed)!=1:raise ValueError('missing complete frame evidence')
    for fid,(f,s) in enumerate(zip(frame,shadow)):
        if f['frame']!=fid or f['commits']!=m['stage_count'] or f['write_beats']!=m['expected_words']//2:raise ValueError('incomplete writes/commits')
        if s['packets']!=m['dw_packets']//2 or s['DW_rows']!=(h if enabled else 0) or s['PW_rows']!=s['DW_rows']:raise ValueError('missing real fused operators')
    result=dict(profile=profile,width=w,height=h,stalls=stalls,fused=bool(enabled),
        frames=frame,shadow=shadow,removed_DDR_write_words_per_frame=m['removed_DDR_write_words_per_frame'],
        extra_parameter_beats_per_frame=m['extra_parameter_beats_per_frame'],
        actual_AXI=False,native_fps_claim=False,physical_RAM_measured=False)
    print(PREFIX+'CASE '+json.dumps(result,separators=(',',':')),flush=True)
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--preflight',action='store_true')
    p.add_argument('--engine-run');p.add_argument('--temporary-parent',type=Path)
    a=p.parse_args();plan_selftest();paths=sources()
    print(PREFIX+f'PREFLIGHT sources={len(paths)} generated_plans=2 RTL_compiled=0',flush=True)
    if a.preflight:return
    if not a.engine_run or not a.temporary_parent:raise ValueError('detached predecessor/private directory required')
    run_gate(a.engine_run)
    parent=a.temporary_parent.resolve()
    if parent.parent!=ROOT/'sim' or not parent.name.startswith('c1_r2_row_fused_graph_') or not parent.is_dir():raise ValueError('invalid private parent')
    with tempfile.TemporaryDirectory(prefix='matrix_',dir=parent) as private:
        cases=[]
        for profile,w,h,stalls,enabled in [('microstyle24',4,4,0,1),('microstyle24',12,12,0,1),
            ('microstyle24',12,12,1,1),('drop_res1',12,12,1,1),('microstyle24',12,12,1,0)]:
            cases.append(run_case(Path(private),profile,w,h,stalls,enabled))
        # Same graph/weights/service/stalls; real measured read/write counts
        # must match exactly the eliminated DW transfer and row reload cost.
        fused,plain=cases[2],cases[4]
        for f,b in zip(fused['frames'],plain['frames']):
            removed=fused['removed_DDR_write_words_per_frame']
            if b['write_beats']-f['write_beats']!=removed:raise ValueError('DW spill was not eliminated')
            if b['producer_reads']-f['producer_reads']!=removed:raise ValueError('PW still reads DW from DDR / lost source cache')
            if f['read_beats']-b['read_beats']!=fused['extra_parameter_beats_per_frame']-removed:raise ValueError('unexpected parameter/source traffic')
        print(PREFIX+'PAIRED '+json.dumps(dict(fused_cycles=[f['cycles'] for f in fused['frames']],
            unfused_cycles=[f['cycles'] for f in plain['frames']],actual_AXI=False,native_fps_claim=False)),flush=True)
        run_case(Path(private),'microstyle24',12,12,1,1,negative=1)
        print(PREFIX+'SUMMARY configurations=5 correct_frames=10 actual_negative_controls=1 full_DAG=1 actual_AXI=0 native_fps_claim=0',flush=True)
    print(PREFIX+'CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
