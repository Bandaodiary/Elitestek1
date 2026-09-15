"""C23 parity-bank RAM full-address and ownership-contract tests."""
from __future__ import annotations
import subprocess
import tempfile
from pathlib import Path
from run_r2_resize_probe import ROOT

def main():
    top='tb_c1_r2_resize_pair_ram'
    with tempfile.TemporaryDirectory(prefix='c1_r2_resize_ram_',dir=ROOT/'sim') as td:
        folder=Path(td)
        for width,negative in [(w,0) for w in (1,1025,2047,2048)]+[(2048,n) for n in range(1,5)]:
            exe=folder/'test.vvp'
            sources=['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_resize_pair_ram.sv',f'sim/{top}.sv']
            r=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,
                              f'-P{top}.WIDTH={width}',f'-P{top}.NEGATIVE={negative}',
                              '-o',str(exe),*[str(ROOT/s) for s in sources]],capture_output=True,text=True,timeout=60)
            if r.returncode:raise RuntimeError(r.stderr[-2500:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=60)
            if negative:
                expected='resize RAM write out of range' if negative==4 else 'resize RAM requires adjacent/clamped bounded taps'
                if r.returncode==0 or expected not in r.stdout:raise RuntimeError('negative control failed: '+r.stdout[-2000:])
                print(f'C1_R2_RESIZE_RAM_NEGATIVE_PASS case={negative}',flush=True)
            else:
                if r.returncode or r.stdout.count('C1_R2_RESIZE_RAM_PASS ')!=1:raise RuntimeError(r.stdout[-2500:])
                print(r.stdout.strip(),flush=True)
        seam='tb_c1_r2_resize_sampler_reject'
        r=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',seam,'-o',str(folder/'seam.vvp'),
                          *[str(ROOT/s) for s in ['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_resize_pair_ram.sv',
                            'rtl/r2/c1_r2_resize_line_sampler.sv',f'sim/{seam}.sv']]],capture_output=True,text=True,timeout=60)
        if r.returncode:raise RuntimeError(r.stderr[-2500:])
        r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(folder/'seam.vvp')],capture_output=True,text=True,timeout=60)
        if r.returncode or r.stdout.count('C1_R2_RESIZE_SAMPLER_REJECT_PASS ')!=1:raise RuntimeError(r.stdout[-2500:])
        for line in r.stdout.splitlines():
            if line.startswith('C1_'):print(line,flush=True)
    print('C1_R2_RESIZE_RAM_CLEAN temporary_simulator_removed=1',flush=True)

if __name__=='__main__':main()
