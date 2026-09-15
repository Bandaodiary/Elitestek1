"""C25 whole-frame skip/disable/re-sync through actual Resize/Capture."""
import subprocess
import tempfile
from pathlib import Path
from run_r2_camera_capture_probe import ROOT,SOURCES,EXTRA,vectors


def main():
    top='tb_c1_r2_camera_capture_lifecycle'
    with tempfile.TemporaryDirectory(prefix='c1_r2_camera_lifecycle_',dir=ROOT/'sim') as td:
        folder=Path(td);plus=vectors(folder,20,20,2,2,16,16,8,8);exe=folder/'test.vvp'
        for stalls in (0,1):
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.STALLS={stalls}',
                '-o',str(exe),*[str(ROOT/s) for s in SOURCES+EXTRA+['sim/c1_r2_axi_memory_bfm.sv',f'sim/{top}.sv']]],capture_output=True,text=True,timeout=90)
            if c.returncode:raise RuntimeError(c.stderr[-3000:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}',
                *[f'+{k}={v}' for k,v in plus.items()]],capture_output=True,text=True,timeout=180)
            for line in r.stdout.splitlines():
                if line.startswith('C1_'):print(line,flush=True)
            if r.returncode or r.stdout.count('C1_R2_CAMERA_LIFECYCLE_PASS ')!=1:raise RuntimeError((r.stdout+r.stderr)[-3000:])
    print('C1_R2_CAMERA_LIFECYCLE_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
