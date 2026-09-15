"""C15 APB3/IRQ bridge with the actual retained CSR, no CPU IP execution."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_host_control_', dir=ROOT/'sim') as td:
        exe = Path(td)/'control.vvp'
        sources = ['rtl/vendor/c1_sapphire_apb_master_adapter.sv', 'rtl/r2/c1_r2_host_control_bridge.sv',
                   'rtl/r2/c1_r2_video_rgbx_csr.sv', 'sim/tb_c1_r2_host_control_bridge.sv']
        c = subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', 'tb_c1_r2_host_control_bridge',
                            '-o', str(exe), *[str(ROOT/s) for s in sources]], capture_output=True, text=True, timeout=60)
        if c.returncode:
            raise RuntimeError(c.stderr[-3000:])
        r = subprocess.run(['D:/iverilog/bin/vvp.exe', str(exe)], capture_output=True, text=True, timeout=60)
        if r.returncode or r.stdout.count('C1_R2_HOST_CONTROL_PASS ') != 1 or 'FATAL' in r.stdout:
            raise RuntimeError((r.stdout+r.stderr)[-3000:])
        print(r.stdout.strip(), flush=True)
    print('C1_R2_HOST_CONTROL_CLEAN temporary_simulator_removed=1')


if __name__ == '__main__':
    main()
