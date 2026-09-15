"""C12 actual packed capture/scanout, full-row reservation and fault recovery."""
import argparse,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCES=['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_video_bram_fifo.sv','rtl/r2/c1_r2_axi_row_read.sv','rtl/r2/c1_r2_axi_row_write.sv',
         'rtl/r2/c1_r2_video_capture_rgbx32.sv','rtl/r2/c1_r2_video_scanout_rgbx32.sv','sim/c1_r2_axi_memory_bfm.sv','sim/tb_c1_r2_video_rgbx_dma.sv']
p=argparse.ArgumentParser();p.add_argument('--shapes',default='8x12,32x12,640x4');p.add_argument('--stalls',default='0,1');p.add_argument('--aw-wait-w',type=int,choices=(0,1,2),default=0);a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='c1_r2_rgbx_video_dma_',dir=ROOT/'sim') as td:
    exe=Path(td)/'test.vvp';top='tb_c1_r2_video_rgbx_dma'
    for shape in a.shapes.split(','):
        w,h=map(int,shape.split('x'))
        for st in map(int,a.stalls.split(',')):
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.WIDTH={w}',f'-P{top}.HEIGHT={h}',f'-P{top}.STALLS={st}',f'-P{top}.AW_WAIT_W={a.aw_wait_w}',
                              '-o',str(exe),*[str(ROOT/x) for x in SOURCES]],capture_output=True,text=True,timeout=60)
            if c.returncode:raise RuntimeError(c.stderr[-3000:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=240)
            if r.returncode or r.stdout.count('C1_R2_RGBX_VIDEO_DMA_PASS ')!=1 or 'FATAL' in r.stdout or 'ERROR' in r.stdout:raise RuntimeError(r.stdout[-4000:]+r.stderr[-1000:])
            for line in r.stdout.splitlines():
                if line.startswith('C1_R2_RGBX_'):print(line,flush=True)
print('C1_R2_RGBX_VIDEO_DMA_CLEAN temporary_simulator_removed=1')
