"""C29 independent boundary/golden and retained-cycle checks, temporary outputs only."""
import subprocess
import tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]


def main():
    cases=[('tb_c29_requant_compact','C29_REQUANT_COMPACT_PASS ',[
        'rtl/cnn/c1_requant_bank8.sv','rtl/cnn/c1_requant_bank8_compact.sv']),
        ('tb_c29_window_packed','C29_WINDOW_PACKED_PASS ',[
        'rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_feature_overlay_ram.sv',
        'rtl/r2/c1_r2_overlay_window_store.sv','rtl/r2/c1_r2_overlay_window_store_packed.sv'])]
    with tempfile.TemporaryDirectory(prefix='c29_capacity_leaf_',dir=ROOT/'sim') as td:
        for top,marker,sources in cases:
            exe=Path(td)/(top+'.vvp')
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,'-o',str(exe),
                *[str(ROOT/s) for s in sources],str(ROOT/f'sim/{top}.sv')],capture_output=True,text=True,timeout=90)
            if c.returncode:raise RuntimeError(c.stderr[-3500:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=120)
            if r.returncode or r.stdout.count(marker)!=1:raise RuntimeError((r.stdout+r.stderr)[-3500:])
            for line in r.stdout.splitlines():
                if line.startswith('C29_'):print(line,flush=True)
    print('C29_CAPACITY_LEAF_CLEAN temporary_simulator_removed=1',flush=True)


if __name__=='__main__':main()
