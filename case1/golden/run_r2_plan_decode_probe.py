"""C16 generated decode vs actual retained decoder; no graph-execution claim."""
import subprocess
import tempfile
from pathlib import Path
from run_r2_pingpong_probe import SOURCES, ROOT


def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_plan_decode_', dir=ROOT/'sim') as td:
        exe = Path(td)/'decode.vvp'
        c = subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', 'tb_c1_r2_plan_decode', '-o', str(exe),
                            *[str(ROOT/s) for s in SOURCES], str(ROOT/'rtl/r2/c1_r2_microstyle_plan.sv'),
                            str(ROOT/'sim/tb_c1_r2_plan_decode.sv')], capture_output=True, text=True, timeout=60)
        if c.returncode:
            raise RuntimeError(c.stderr[-3000:])
        r = subprocess.run(['D:/iverilog/bin/vvp.exe', str(exe)], capture_output=True, text=True, timeout=60)
        if r.returncode or r.stdout.count('C1_R2_PLAN_DECODE_PASS ') != 1 or 'FATAL' in r.stdout:
            raise RuntimeError((r.stdout+r.stderr)[-3000:])
        for line in r.stdout.splitlines():
            if line.startswith('C1_R2_PLAN_DECODE_PASS '):
                print(line)
    print('C1_R2_PLAN_DECODE_CLEAN temporary_simulator_removed=1')


if __name__ == '__main__':
    main()
