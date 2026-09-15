"""Bounded parameter/edge oracle for the source-domain raster formatter."""
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]


def main():
    top='tb_c30_rgb2_raster_edges'
    with tempfile.TemporaryDirectory(prefix='c30_raster_edges_',dir=ROOT/'sim') as td:
        exe=Path(td)/'test.vvp'
        for sw,sh in ((2,1),(2,3),(6,1),(6,3)):
            for polarity in (0,1):
                cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,'-o',str(exe),
                     f'-P{top}.SW={sw}',f'-P{top}.SH={sh}',f'-P{top}.POLARITY={polarity}',
                     str(ROOT/'rtl/r2/c1_r2_rgb2_raster_source.sv'),str(ROOT/f'sim/{top}.sv')]
                c=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
                if c.returncode:raise RuntimeError(c.stderr[-2000:])
                r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=30)
                if r.returncode or r.stdout.count('C30_RASTER_EDGES_PASS ')!=1:
                    raise RuntimeError((r.stdout+r.stderr)[-2000:])
                print(r.stdout.strip(),flush=True)
    print('C30_RASTER_EDGES_CLEAN configurations=8 temporary_simulator_removed=1',flush=True)


if __name__=='__main__':main()
