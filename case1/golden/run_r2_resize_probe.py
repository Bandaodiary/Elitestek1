"""C23 banked Resize regression against retained R1 arithmetic and lifecycle."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
from generate_r1_resize_line_sampler_vectors import generate

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['rtl/common/c1_ram_sdp_read_first.sv', 'rtl/video/r1_resize_request_q16.sv',
           'rtl/video/r1_bilinear_interp_rgb888.sv', 'rtl/video/c1_r1_resize_system.sv',
           'rtl/r2/c1_r2_resize_pair_ram.sv', 'rtl/r2/c1_r2_resize_line_sampler.sv',
           'rtl/r2/c1_r2_resize_pipeline.sv']
OLD = ['rtl/video/c1_r1_resize_line_sampler.sv','rtl/video/c1_r1_resize_pipeline.sv']

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--vectors-only', type=Path)
    a = p.parse_args()
    if a.vectors_only:
        m = generate(a.vectors_only, 20260913)
        print('C1_R2_RESIZE_FIXTURE '+json.dumps({k:v for k,v in m.items() if k!='cases'}),flush=True)
        return
    with tempfile.TemporaryDirectory(prefix='c1_r2_resize_',dir=ROOT/'sim') as td:
        folder=Path(td)
        m=generate(folder,20260913)
        print('C1_R2_RESIZE_FIXTURE '+json.dumps({k:v for k,v in m.items() if k!='cases'}),flush=True)
        top='tb_c1_r2_resize_pipeline'
        for reset in (0,1):
            exe=folder/'test.vvp'
            cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,'-o',str(exe)]
            if reset: cmd += ['-DC1_REGISTER_ABORT_RESET']
            r=subprocess.run(cmd+[str(ROOT/s) for s in SOURCES]+[str(ROOT/f'sim/{top}.sv')],capture_output=True,text=True,timeout=90)
            if r.returncode: raise RuntimeError(r.stderr[-4000:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],cwd=folder,capture_output=True,text=True,timeout=180)
            for line in r.stdout.splitlines():
                if line.startswith('C1_'): print(line+f' registered_abort_reset={reset}',flush=True)
            if r.returncode or r.stdout.count('C1_R2_RESIZE_PIPELINE_PASS ')!=1 or 'FATAL' in r.stdout:
                raise RuntimeError((r.stdout+r.stderr)[-4000:])
    print('C1_R2_RESIZE_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)

if __name__=='__main__': main()
