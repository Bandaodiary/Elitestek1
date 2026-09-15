"""C7 full graph: true 128-bit SRAM refill, row reuse, write/refill overlap."""
from __future__ import annotations
import argparse,json,subprocess,tempfile
from pathlib import Path
from run_r2_graph_probe import vectors,GRAPH_SOURCES
from run_r2_array_probe import ROOT

RENAMES={'c1_r2_mapped_window_store':'c1_r2_bulk_window_store','c1_r2_pw_banked_feeder':'c1_r2_pw_bulk_feeder',
         'c1_r2_spatial_operator_feeder':'c1_r2_spatial_bulk_feeder','c1_r2_cnn_operator_engine':'c1_r2_cnn_bulk_engine',
         'c1_r2_tensor_row_loader':'c1_r2_tensor_stream_loader','c1_r2_microstyle_graph':'c1_r2_microstyle_stream_graph'}
SOURCES=[next((s.replace(a,b) for a,b in RENAMES.items() if a in s),s) for s in GRAPH_SOURCES]


def main():
    p=argparse.ArgumentParser();p.add_argument('--shapes',default='4x4,12x12,32x32,640x12');p.add_argument('--stalls',default='0,1')
    p.add_argument('--cache',type=int,choices=(0,1),default=1);p.add_argument('--overlap',type=int,choices=(0,1),default=1)
    p.add_argument('--memory-div',type=int,default=0);p.add_argument('--latency',type=int,default=0)
    p.add_argument('--negative-only',action='store_true');p.add_argument('--timeout-seconds',type=int,default=900);args=p.parse_args()
    top='tb_c1_r2_microstyle_stream_graph'
    with tempfile.TemporaryDirectory(prefix='c1_r2_stream_',dir=ROOT/'sim') as tmp:
        for shape in args.shapes.split(','):
            w,h=map(int,shape.split('x'));folder=Path(tmp)/shape;folder.mkdir();m=vectors(folder,w,h)
            print('C1_R2_STREAM_VECTORS '+json.dumps(dict(m,cache=args.cache,overlap=args.overlap,memdiv=args.memory_div,latency=args.latency)),flush=True)
            for stalls in map(int,args.stalls.split(',')):
                exe=folder/f'stream{stalls}.vvp'
                compile_cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.STALLS={stalls}',
                             f'-P{top}.USE_ROW_CACHE={args.cache}',f'-P{top}.OVERLAP_WRITE={args.overlap}',
                             f'-P{top}.MEMORY_DIV={args.memory_div}',f'-P{top}.COMMAND_LATENCY={args.latency}',
                             '-o',str(exe),*[str(ROOT/s) for s in SOURCES],str(ROOT/f'sim/{top}.sv')]
                run_cmd=['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}',f'+W={w}',f'+H={h}',
                         f'+P={m["parameter_words"]}',f'+I={m["input_words"]}',f'+E={m["expected_words"]}']
                if args.negative_only:
                    for fault,marker in ((1,'STREAM_MISMATCH stage=1'),(2,'unwritten/wrong producer stage=1')):
                        c=subprocess.run(compile_cmd[:4]+[f'-P{top}.CORRUPT_HANDOFF={fault}']+compile_cmd[4:],capture_output=True,text=True,timeout=60)
                        if c.returncode:raise RuntimeError(c.stderr[-3000:])
                        r=subprocess.run(run_cmd,capture_output=True,text=True,timeout=90)
                        if r.returncode==0 or marker not in r.stdout:raise RuntimeError('missing handoff detection '+r.stdout[-2000:])
                        print(f'C1_R2_STREAM_HANDOFF_NEGATIVE_PASS corruption={fault} detected_at_stage=1',flush=True)
                    continue
                for cmd in (compile_cmd,run_cmd):
                    r=subprocess.run(cmd,capture_output=True,text=True,timeout=args.timeout_seconds)
                    if r.returncode:raise RuntimeError('\n'.join((r.stdout+r.stderr).splitlines()[-25:]))
                lines=r.stdout.splitlines()
                if sum(s.startswith('C1_R2_STREAM_PASS ') for s in lines)!=1 or any('FATAL' in s or 'ERROR' in s for s in lines):raise RuntimeError(r.stdout[-3000:])
                for s in lines:
                    if s.startswith('C1_R2_STREAM_'):print(s,flush=True)
    print('C1_R2_STREAM_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
