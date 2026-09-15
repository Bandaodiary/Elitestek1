"""C20 paired-bank unit: original RTL and independent logical reference."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['rtl/common/c1_ram_sdp_read_first.sv', 'rtl/r2/c1_r2_weight_store8.sv',
           'rtl/r2/c1_r2_weight_pair_ram.sv', 'rtl/r2/c1_r2_weight_store8_tdp.sv']


def main():
    top = 'tb_c1_r2_weight_store8_tdp'
    reasons = {1: ('owner collision', 'cannot load and read concurrently'), 2: ('invalid weight channel group',),
               3: ('invalid affine channel',), 4: ('invalid affine fields',),
               5: ('invalid parameter read group',), 6: ('invalid affine fields',)}
    with tempfile.TemporaryDirectory(prefix='c1_r2_weight_tdp_', dir=ROOT/'sim') as td:
        exe = Path(td)/'weights.vvp'
        for negative in range(7):
            c = subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', top,
                                f'-P{top}.NEGATIVE={negative}', '-o', str(exe),
                                *[str(ROOT/s) for s in SOURCES], str(ROOT/f'sim/{top}.sv')],
                               capture_output=True, text=True, timeout=60)
            if c.returncode:
                raise RuntimeError(c.stderr[-3000:])
            r = subprocess.run(['D:/iverilog/bin/vvp.exe', str(exe)], capture_output=True, text=True, timeout=60)
            if negative:
                if r.returncode == 0 or not any(x in r.stdout for x in reasons[negative]) or 'C1_R2_WEIGHT_TDP_PASS ' in r.stdout:
                    raise RuntimeError('invalid control accepted/wrong failure: '+r.stdout[-2500:])
                print(f'C1_R2_WEIGHT_TDP_NEGATIVE_PASS case={negative}', flush=True)
            else:
                if r.returncode or r.stdout.count('C1_R2_WEIGHT_TDP_PASS ') != 1 or 'FATAL' in r.stdout:
                    raise RuntimeError((r.stdout+r.stderr)[-3000:])
                print(next(x for x in r.stdout.splitlines() if x.startswith('C1_R2_WEIGHT_TDP_PASS ')), flush=True)
    print('C1_R2_WEIGHT_TDP_CLEAN temporary_simulator_removed=1')


if __name__ == '__main__':
    main()
