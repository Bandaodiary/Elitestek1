"""Serial host smoke after verified fused-stage recovery. Detached worker only."""
import argparse
import io
from contextlib import redirect_stdout
import sys

from check_r2_fused_fault_evidence import run_gate
from check_r2_fused_host_evidence import check_text
import run_r2_fused_rgb2_host_probe as probe


def main():
    p=argparse.ArgumentParser();p.add_argument('--fault-run',required=True)
    p.add_argument('--temporary-parent',required=True);a=p.parse_args()
    run_gate(a.fault_run)
    previous=sys.argv;out=io.StringIO()
    try:
        sys.argv=['run_r2_fused_rgb2_host_probe.py','--shapes','8x8','--stalls','1',
            '--nn-target','2','--aw-wait-w','2','--temporary-parent',a.temporary_parent]
        try:
            with redirect_stdout(out):probe.main()
        finally:print(out.getvalue(),end='',flush=True)
    finally:sys.argv=previous
    check_text(out.getvalue())
    print('C35_FUSED_HOST_SMOKE_PASS correct_CNN_frames=2 actual_AXI=1 actual_CPU_IP=0 native_fps_claim=0',flush=True)


if __name__=='__main__':main()
