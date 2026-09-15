"""C24 Resize/Capture/scanout actual AXI drain and cancellation regression."""
from __future__ import annotations
import subprocess
import tempfile
from pathlib import Path
from run_r2_resize_probe import ROOT,SOURCES

def main():
    top='tb_c1_r2_resize_video_dma'
    sources=SOURCES+['rtl/r2/c1_r2_resize_capture_rgbx32.sv','rtl/r2/c1_r2_video_capture_rgbx32.sv',
        'rtl/r2/c1_r2_video_scanout_rgbx32.sv','rtl/r2/c1_r2_video_bram_fifo.sv',
        'rtl/r2/c1_r2_axi_row_read.sv','rtl/r2/c1_r2_axi_row_write.sv','sim/c1_r2_axi_memory_bfm.sv',f'sim/{top}.sv']
    with tempfile.TemporaryDirectory(prefix='c1_r2_resize_capture_',dir=ROOT/'sim') as td:
        folder=Path(td)
        for stalls,aw in [(s,a) for s in (0,1) for a in (0,2)]:
            exe=folder/'test.vvp'
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,
                f'-P{top}.STALLS={stalls}',f'-P{top}.AW_WAIT_W={aw}', '-o',str(exe),*[str(ROOT/s) for s in sources]],capture_output=True,text=True,timeout=90)
            if c.returncode:raise RuntimeError(c.stderr[-3000:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=180)
            for line in r.stdout.splitlines():
                if line.startswith('C1_'):print(line,flush=True)
            if r.returncode or r.stdout.count('C1_R2_RESIZE_VIDEO_DMA_PASS ')!=1:raise RuntimeError((r.stdout+r.stderr)[-3000:])
    print('C1_R2_RESIZE_CAPTURE_CLEAN temporary_simulator_removed=1',flush=True)

if __name__=='__main__':main()
