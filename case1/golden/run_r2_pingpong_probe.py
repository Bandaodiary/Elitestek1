"""C8 full graph: two writer pages permit compute/write overlap."""
from __future__ import annotations
import argparse,json,subprocess,tempfile,threading
from collections import deque
from pathlib import Path
from run_r2_graph_probe import vectors,GRAPH_SOURCES
from run_r2_array_probe import ROOT

RENAMES={'c1_r2_mapped_window_store':'c1_r2_bulk_window_store','c1_r2_pw_banked_feeder':'c1_r2_pw_bulk_feeder',
         'c1_r2_spatial_operator_feeder':'c1_r2_spatial_bulk_feeder','c1_r2_cnn_operator_engine':'c1_r2_cnn_bulk_engine',
         'c1_r2_tensor_row_loader':'c1_r2_tensor_stream_loader','c1_r2_microstyle_graph':'c1_r2_microstyle_pingpong_graph',
         'c1_r2_tensor_row_writer':'c1_r2_tensor_pingpong_writer'}
SOURCES=[next((s.replace(a,b) for a,b in RENAMES.items() if a in s),s) for s in GRAPH_SOURCES]


def main():
    p=argparse.ArgumentParser();p.add_argument('--shapes',default='4x4,12x12,32x32,640x12');p.add_argument('--stalls',default='0,1')
    p.add_argument('--cache',type=int,choices=(0,1),default=1);p.add_argument('--overlap',type=int,choices=(0,1),default=1)
    p.add_argument('--memory-div',type=int,default=0);p.add_argument('--latency',type=int,default=0)
    p.add_argument('--compute-overlap',type=int,choices=(0,1),default=1)
    p.add_argument('--refill-priority',type=int,choices=(0,1),default=1)
    p.add_argument('--write-throttle',type=int,choices=(0,1),default=0)
    p.add_argument('--reset-only',action='store_true')
    p.add_argument('--negative-only',action='store_true');p.add_argument('--timeout-seconds',type=int,default=900);args=p.parse_args()
    if args.timeout_seconds<1 or args.memory_div<0 or args.latency<0:p.error('timeout must be positive; memory profile values must be nonnegative')
    if args.negative_only and args.reset_only:p.error('select either reset-only or negative-only')
    top='tb_c1_r2_microstyle_pingpong_graph'
    with tempfile.TemporaryDirectory(prefix='c1_r2_pingpong_',dir=ROOT/'sim') as tmp:
        for shape in args.shapes.split(','):
            w,h=map(int,shape.split('x'));folder=Path(tmp)/shape;folder.mkdir();m=vectors(folder,w,h)
            print('C1_R2_PINGPONG_VECTORS '+json.dumps(dict(m,cache=args.cache,overlap=args.overlap,compute_overlap=args.compute_overlap,refill_priority=args.refill_priority,memdiv=args.memory_div,latency=args.latency)),flush=True)
            for stalls in map(int,args.stalls.split(',')):
                exe=folder/f'stream{stalls}.vvp'
                compile_cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.STALLS={stalls}',
                             f'-P{top}.USE_ROW_CACHE={args.cache}',f'-P{top}.OVERLAP_WRITE={args.overlap}',
                             f'-P{top}.MEMORY_DIV={args.memory_div}',f'-P{top}.COMMAND_LATENCY={args.latency}',
                             f'-P{top}.OVERLAP_COMPUTE={args.compute_overlap}',
                             f'-P{top}.PRIORITIZE_REFILL={args.refill_priority}',
                             f'-P{top}.WRITE_THROTTLE={args.write_throttle}',
                             f'-P{top}.RESET_PROBE={int(args.reset_only)}',
                             '-o',str(exe),*[str(ROOT/s) for s in SOURCES],str(ROOT/f'sim/{top}.sv')]
                run_cmd=['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}',f'+W={w}',f'+H={h}',
                         f'+P={m["parameter_words"]}',f'+I={m["input_words"]}',f'+E={m["expected_words"]}']
                if args.negative_only:
                    for fault,marker in ((1,'PINGPONG_MISMATCH stage=1'),(2,'unwritten/wrong producer stage=1')):
                        c=subprocess.run(compile_cmd[:4]+[f'-P{top}.CORRUPT_HANDOFF={fault}']+compile_cmd[4:],capture_output=True,text=True,timeout=60)
                        if c.returncode:raise RuntimeError(c.stderr[-3000:])
                        r=subprocess.run(run_cmd,capture_output=True,text=True,timeout=90)
                        if r.returncode==0 or marker not in r.stdout:raise RuntimeError('missing handoff detection '+r.stdout[-2000:])
                        print(f'C1_R2_PINGPONG_HANDOFF_NEGATIVE_PASS corruption={fault} detected_at_stage=1',flush=True)
                    continue
                c=subprocess.run(compile_cmd,capture_output=True,text=True,timeout=60)
                if c.returncode:raise RuntimeError(c.stderr[-3000:])
                pass_marker='C1_R2_PINGPONG_RESET_SUITE_PASS ' if args.reset_only else 'C1_R2_PINGPONG_PASS '
                tail=deque(maxlen=25);pass_count=0;bad=False
                with subprocess.Popen(run_cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True) as child:
                    timer=threading.Timer(args.timeout_seconds,child.kill);timer.daemon=True;timer.start()
                    try:
                        for raw in child.stdout:
                            s=raw.rstrip();tail.append(s)
                            if s.startswith('C1_R2_PINGPONG_'):print(s,flush=True)
                            pass_count+=s.startswith(pass_marker);bad|='FATAL' in s or 'ERROR' in s
                        code=child.wait()
                    finally:timer.cancel()
                if code or bad or pass_count!=1:raise RuntimeError('\n'.join(tail))
    print('C1_R2_PINGPONG_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
