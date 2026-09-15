"""C25 dual-clock synchronous-RAM FIFO regression; no retained simulator files."""
import subprocess
import tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]


def main():
    top='tb_c1_r2_async_pixel_fifo'
    with tempfile.TemporaryDirectory(prefix='c1_r2_camera_fifo_',dir=ROOT/'sim') as td:
        exe=Path(td)/'test.vvp'
        for depth in (2,4,32,1024):
            for wh,rh in ((7,5),(5,11)):
                c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,
                    *[f'-P{top}.{k}={v}' for k,v in dict(DEPTH=depth,WH=wh,RH=rh).items()],'-o',str(exe),
                    str(ROOT/'rtl/r2/c1_r2_async_pixel_fifo.sv'),str(ROOT/f'sim/{top}.sv')],capture_output=True,text=True,timeout=60)
                if c.returncode:raise RuntimeError(c.stderr[-3000:])
                r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=120)
                if r.returncode or r.stdout.count('C1_R2_ASYNC_PIXEL_FIFO_PASS ')!=1:raise RuntimeError((r.stdout+r.stderr)[-3000:])
                print(r.stdout.strip(),flush=True)
    print('C1_R2_ASYNC_PIXEL_FIFO_CLEAN temporary_simulator_removed=1',flush=True)


if __name__=='__main__':main()
