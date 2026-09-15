"""C22 physical-view alias/latency/owner regression, no persistent simulator."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    top = 'tb_c1_r2_feature_overlay_ram'
    sources = ['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_feature_overlay_ram.sv',f'sim/{top}.sv']
    reasons = {1:'ownership collision',2:'ownership collision',3:'read/refill overlap',4:'read/refill overlap',
               5:'spatial view needs refill',6:'linear view needs refill',7:'ownership collision',8:'ownership collision'}
    with tempfile.TemporaryDirectory(prefix='c1_r2_overlay_ram_', dir=ROOT/'sim') as td:
        exe = Path(td)/'ram.vvp'
        for negative in range(9):
            c = subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.NEGATIVE={negative}',
                                '-o',str(exe),*[str(ROOT/s) for s in sources]],capture_output=True,text=True,timeout=60)
            if c.returncode:
                raise RuntimeError(c.stderr[-2500:])
            r = subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=60)
            if negative:
                if not r.returncode or reasons[negative] not in r.stdout or 'C1_R2_OVERLAY_RAM_PASS ' in r.stdout:
                    raise RuntimeError('wrong negative result: '+r.stdout[-2000:])
                print(f'C1_R2_OVERLAY_RAM_NEGATIVE_PASS case={negative}',flush=True)
            else:
                if r.returncode or r.stdout.count('C1_R2_OVERLAY_RAM_PASS ')!=1 or 'FATAL' in r.stdout:
                    raise RuntimeError((r.stdout+r.stderr)[-2500:])
                print(next(x for x in r.stdout.splitlines() if x.startswith('C1_R2_OVERLAY_RAM_PASS ')),flush=True)
    print('C1_R2_OVERLAY_RAM_CLEAN temporary_simulator_removed=1',flush=True)


if __name__ == '__main__':
    main()
