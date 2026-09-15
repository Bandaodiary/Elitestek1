"""C10 shared SYSTEM, distinct from C2 shared arithmetic-engine regression."""
from __future__ import annotations
import argparse,json,subprocess,tempfile,threading
from collections import deque
from pathlib import Path
from run_r2_axi_probe import SOURCES as C9_SOURCES
from run_r2_graph_probe import vectors
from run_r2_array_probe import ROOT

SOURCES=C9_SOURCES+['rtl/dma/c1_axi_n_read_burst_arbiter_128.sv','rtl/dma/c1_axi_n_write_burst_arbiter_128.sv',
    'rtl/r2/c1_r2_apb_job_control.sv','rtl/r2/c1_r2_axi_fabric.sv','rtl/r2/c1_r2_shared_subsystem.sv']
SIM_SOURCES=['sim/c1_r2_axi_memory_bfm.sv','sim/c1_r2_axi_traffic_agent.sv']


def run(folder,top,sources,params,plusargs,timeout,marker,expected_failure=None):
    exe=folder/'test.vvp'
    c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,*[f'-P{top}.{k}={v}' for k,v in params.items()],
        '-o',str(exe),*[str(ROOT/s) for s in sources],str(ROOT/f'sim/{top}.sv')],capture_output=True,text=True,timeout=90)
    if c.returncode:raise RuntimeError(c.stderr[-4000:])
    tail=deque(maxlen=15);good=0;bad=False
    with subprocess.Popen(['D:/iverilog/bin/vvp.exe',str(exe),*plusargs],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True) as child:
        timer=threading.Timer(timeout,child.kill);timer.daemon=True;timer.start()
        try:
            for raw in child.stdout:
                s=raw.rstrip();tail.append(s)
                if s.startswith(('C1_R2_SHARED_','C1_R2_COMPUTE_')):print(s,flush=True)
                good+=s.startswith(marker);bad|='FATAL' in s or 'ERROR' in s
            code=child.wait()
        finally:timer.cancel()
    if expected_failure is not None:
        if not code or not bad or good or expected_failure not in '\n'.join(tail):raise RuntimeError('negative not detected: '+'\n'.join(tail))
        return
    if code or bad or good!=1:raise RuntimeError('\n'.join(tail))


def main():
    p=argparse.ArgumentParser();p.add_argument('--apb-only',action='store_true');p.add_argument('--shapes',default='4x4,12x12,32x32,640x12')
    p.add_argument('--stalls',default='0,1');p.add_argument('--background',type=int,choices=(0,1),default=1)
    p.add_argument('--aw-wait-w',type=int,choices=(0,1,2),default=0);p.add_argument('--handoff-negative',action='store_true')
    p.add_argument('--timeout-seconds',type=int,default=900);a=p.parse_args()
    if a.timeout_seconds<1:p.error('timeout must be positive')
    with tempfile.TemporaryDirectory(prefix='c1_r2_shared_',dir=ROOT/'sim') as tmp:
        root=Path(tmp)
        if a.apb_only:
            run(root,'tb_c1_r2_apb_job_control',['rtl/r2/c1_r2_apb_job_control.sv'],{},[],a.timeout_seconds,'C1_R2_SHARED_APB_PASS ')
        else:
            for shape in a.shapes.split(','):
                w,h=map(int,shape.split('x'));folder=root/shape;folder.mkdir();m=vectors(folder,w,h)
                print('C1_R2_SHARED_VECTORS '+json.dumps(m),flush=True)
                for stalls in map(int,a.stalls.split(',')):
                    args=[f'+DIR={folder.as_posix()}',f'+W={w}',f'+H={h}',f'+P={m["parameter_words"]}',f'+I={m["input_words"]}',f'+E={m["expected_words"]}']
                    for corruption in ((1,2) if a.handoff_negative else (0,)):
                        failure={0:None,1:'shared graph not golden',2:'shared wrong producer stage=0'}[corruption]
                        run(folder,'tb_c1_r2_shared_subsystem',SOURCES+SIM_SOURCES,
                            dict(STALLS=stalls,BACKGROUND=a.background,AW_WAIT_W=a.aw_wait_w,CAPTURE_CORRUPTION=corruption),
                            args,a.timeout_seconds,'C1_R2_SHARED_PASS ',failure)
                        if corruption:print(f'C1_R2_SHARED_HANDOFF_NEGATIVE_PASS mode={corruption} stalls={stalls} actual_capture=1',flush=True)
    print('C1_R2_SHARED_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
