"""C18 real host shell/fabric byte lanes; video disabled, not CPU IP execution."""
import subprocess
import tempfile
from pathlib import Path
from run_r2_planned_host_probe import SOURCES, ROOT


def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_planned_host_narrow_', dir=ROOT/'sim') as td:
        exe = Path(td)/'narrow.vvp'
        top = 'tb_c1_r2_planned_host_narrow_system'
        for stalls in (0, 1):
            for aw in (0, 2):
                c = subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', top,
                    f'-P{top}.STALLS={stalls}', f'-P{top}.AW_MODE={aw}', '-o', str(exe),
                    *[str(ROOT/s) for s in SOURCES], str(ROOT/f'sim/{top}.sv')], capture_output=True, text=True, timeout=60)
                if c.returncode:
                    raise RuntimeError(c.stderr[-3000:])
                r = subprocess.run(['D:/iverilog/bin/vvp.exe', str(exe)], capture_output=True, text=True, timeout=90)
                if r.returncode or r.stdout.count('C1_R2_PLANNED_HOST_NARROW_PASS ') != 1 or 'FATAL' in r.stdout:
                    raise RuntimeError((r.stdout+r.stderr)[-3000:])
                for line in r.stdout.splitlines():
                    if line.startswith('C1_R2_PLANNED_HOST_NARROW_PASS '):
                        print(line, flush=True)
    print('C1_R2_PLANNED_HOST_NARROW_CLEAN temporary_simulator_removed=1')


if __name__ == '__main__':
    main()
