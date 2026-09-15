"""C9 same-ID AXI DMA + C8 compute integration, disposable simulation files."""
from __future__ import annotations
import argparse, json, subprocess, tempfile, threading
from collections import deque
from pathlib import Path
from run_r2_graph_probe import vectors
from run_r2_pingpong_probe import SOURCES as C8_SOURCES
from run_r2_array_probe import ROOT

DMA_SOURCES=['rtl/r2/c1_r2_axi_row_read.sv','rtl/r2/c1_r2_axi_row_write.sv']
SOURCES=C8_SOURCES+DMA_SOURCES+['rtl/r2/c1_r2_microstyle_axi_graph.sv']
BFM='sim/c1_r2_axi_memory_bfm.sv'


def simulate(folder, top, sources, params, plusargs, timeout, marker, failure=None):
    exe=folder/'test.vvp'
    cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,
         *[f'-P{top}.{k}={v}' for k,v in params.items()],'-o',str(exe),
         *[str(ROOT/s) for s in sources],str(ROOT/BFM),str(ROOT/f'sim/{top}.sv')]
    c=subprocess.run(cmd,capture_output=True,text=True,timeout=90)
    if c.returncode:raise RuntimeError(c.stderr[-3500:])
    tail=deque(maxlen=18);count=0;bad=False;found=False
    with subprocess.Popen(['D:/iverilog/bin/vvp.exe',str(exe),*plusargs],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True) as child:
        timer=threading.Timer(timeout,child.kill);timer.daemon=True;timer.start()
        try:
            for raw in child.stdout:
                s=raw.rstrip();tail.append(s)
                if s.startswith('C1_R2_AXI_'):print(s,flush=True)
                count+=s.startswith(marker);bad|='FATAL' in s or 'ERROR' in s
                found|=failure is not None and failure in s
            code=child.wait()
        finally:timer.cancel()
    if failure:
        if code==0 or not found:raise RuntimeError('negative not detected: '+'\n'.join(tail))
    elif code or bad or count!=1:raise RuntimeError('\n'.join(tail))


def main():
    p=argparse.ArgumentParser();p.add_argument('--unit',action='store_true')
    p.add_argument('--configs',default='16:1,16:3,16:4,1:4,256:4')
    p.add_argument('--shapes',default='4x4,12x12,32x32,640x12');p.add_argument('--stalls',default='0,1')
    p.add_argument('--memory-div',type=int,default=2);p.add_argument('--latency',type=int,default=20)
    p.add_argument('--slots',type=int,default=4);p.add_argument('--burst',type=int,default=16)
    p.add_argument('--aw-wait-w',type=int,choices=(0,1,2),default=0)
    p.add_argument('--negative-only',action='store_true');p.add_argument('--timeout-seconds',type=int,default=900)
    args=p.parse_args()
    if args.timeout_seconds<1 or args.memory_div<0 or args.latency<0 or not 1<=args.slots<=16 or not 1<=args.burst<=256:p.error('invalid profile')
    with tempfile.TemporaryDirectory(prefix='c1_r2_axi_',dir=ROOT/'sim') as tmp:
        root=Path(tmp)
        if args.unit:
            for config in args.configs.split(','):
                burst,slots=map(int,config.split(':'))
                for stalls in map(int,args.stalls.split(',')):
                    simulate(root,'tb_c1_r2_axi_row_dma',DMA_SOURCES,
                             dict(BURST_BEATS=burst,OUTSTANDING=slots,STALLS=stalls,AW_WAIT_W=args.aw_wait_w),[],args.timeout_seconds,'C1_R2_AXI_DMA_PASS ')
        else:
            for shape in args.shapes.split(','):
                w,h=map(int,shape.split('x'));folder=root/shape;folder.mkdir();m=vectors(folder,w,h)
                print('C1_R2_AXI_VECTORS '+json.dumps(m),flush=True)
                plusargs=[f'+DIR={folder.as_posix()}',f'+W={w}',f'+H={h}',f'+P={m["parameter_words"]}',f'+I={m["input_words"]}',f'+E={m["expected_words"]}']
                for stalls in map(int,args.stalls.split(',')):
                    params=dict(STALLS=stalls,BURST_BEATS=args.burst,OUTSTANDING=args.slots,MEMORY_DIV=args.memory_div,COMMAND_LATENCY=args.latency,AW_WAIT_W=args.aw_wait_w)
                    if args.negative_only:
                        for fault,marker in ((1,'AXI_MISMATCH stage=1'),(2,'unwritten/wrong producer stage=1')):
                            simulate(folder,'tb_c1_r2_microstyle_axi_graph',SOURCES,dict(params,CORRUPT_HANDOFF=fault),plusargs,args.timeout_seconds,'C1_R2_AXI_PASS ',failure=marker)
                            print(f'C1_R2_AXI_HANDOFF_NEGATIVE_PASS corruption={fault} detected_at_stage=1',flush=True)
                    else:simulate(folder,'tb_c1_r2_microstyle_axi_graph',SOURCES,params,plusargs,args.timeout_seconds,'C1_R2_AXI_PASS ')
    print('C1_R2_AXI_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
