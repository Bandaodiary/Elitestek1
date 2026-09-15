"""C11 disposable FIFO/video DMA tests; no waves or large log retention."""
from __future__ import annotations
import argparse,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCES=['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_video_bram_fifo.sv',
    'rtl/r2/c1_r2_axi_row_read.sv','rtl/r2/c1_r2_axi_row_write.sv',
    'rtl/r2/c1_r2_video_capture_p2c8.sv','rtl/r2/c1_r2_video_scanout_p2c8.sv','rtl/r2/c1_r2_video_frame_leases.sv','rtl/r2/c1_r2_video_csr.sv','sim/c1_r2_axi_memory_bfm.sv']
def run(d,top,params,timeout=120):
    exe=d/'test.vvp'
    c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,*[f'-P{top}.{k}={v}' for k,v in params.items()],
        '-o',str(exe),*[str(ROOT/s) for s in SOURCES],str(ROOT/f'sim/{top}.sv')],capture_output=True,text=True,timeout=90)
    if c.returncode:raise RuntimeError(c.stderr[-3500:])
    r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=timeout)
    for line in r.stdout.splitlines():
        if line.startswith('C1_R2_VIDEO_'):print(line,flush=True)
    marker='C1_R2_VIDEO_CSR_PASS ' if 'video_csr' in top else 'C1_R2_VIDEO_FIFO_PASS ' if 'bram_fifo' in top else 'C1_R2_VIDEO_LEASE_PASS ' if 'frame_leases' in top else 'C1_R2_VIDEO_DMA_PASS '
    if r.returncode or r.stdout.count(marker)!=1 or 'FATAL' in r.stdout or 'ERROR' in r.stdout:raise RuntimeError((r.stdout+r.stderr)[-3500:])
def main():
    p=argparse.ArgumentParser();p.add_argument('--fifo-only',action='store_true');p.add_argument('--leases-only',action='store_true');p.add_argument('--csr-only',action='store_true');p.add_argument('--shapes',default='8x12,32x12,640x4');p.add_argument('--stalls',default='0,1');p.add_argument('--aw-wait-w',type=int,default=0,choices=(0,1,2));a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='c1_r2_video_unit_',dir=ROOT/'sim') as td:
        d=Path(td)
        if a.csr_only:run(d,'tb_c1_r2_video_csr',{})
        elif a.leases_only:run(d,'tb_c1_r2_video_frame_leases',{})
        elif a.fifo_only:
            for depth in (4,7,16,512):run(d,'tb_c1_r2_video_bram_fifo',dict(DEPTH=depth))
        else:
            for shape in a.shapes.split(','):
                w,h=map(int,shape.split('x'))
                for stalls in map(int,a.stalls.split(',')):run(d,'tb_c1_r2_video_dma',dict(WIDTH=w,HEIGHT=h,STALLS=stalls,AW_WAIT_W=a.aw_wait_w),240)
    print('C1_R2_VIDEO_CLEAN temporary_simulator_removed=1',flush=True)
if __name__=='__main__':main()
