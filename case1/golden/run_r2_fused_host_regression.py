"""Serial C35 full-host matrix; run only in the detached budgeted worker."""
import argparse
from contextlib import redirect_stdout
import io
import json
import sys

from check_r2_fused_fault_evidence import run_gate as fault_gate
from check_r2_fused_host_evidence import run_gate as smoke_gate
from check_r2_fused_pnr_evidence import physical_gate
from check_r2_fused_host_regression import CASES, check_case, check_text
import run_r2_fused_rgb2_host_probe as probe


def main():
    p=argparse.ArgumentParser();p.add_argument('--fault-run',required=True)
    p.add_argument('--temporary-parent',required=True);a=p.parse_args()
    fault_gate(a.fault_run)
    smoke_gate('c35_fused_host_smoke_20260914_a')
    physical_gate('c35_fused_rgb2_host96_pnr_20260915_a')
    transcript=[]
    for case in CASES:
        begin='C35_HOST_CASE_BEGIN '+json.dumps(case,separators=(',',':'))
        print(begin,flush=True);out=io.StringIO();previous=sys.argv
        try:
            sys.argv=['run_r2_fused_rgb2_host_probe.py','--profile',case['profile'],
                '--shapes',case['shape'],'--stalls',str(case['stalls']),
                '--nn-target','2','--aw-wait-w','2','--temporary-parent',a.temporary_parent]
            if case['negative']:sys.argv.append('--negative-only')
            try:
                with redirect_stdout(out):probe.main()
            finally:print(out.getvalue(),end='',flush=True)
        finally:sys.argv=previous
        check_case(case,out.getvalue())
        end='C35_HOST_CASE_END '+case['id'];print(end,flush=True)
        transcript.append(begin+'\n'+out.getvalue()+end+'\n')
    result=check_text(''.join(transcript))
    print('C35_FUSED_HOST_REGRESSION_PASS '+json.dumps(result,separators=(',',':')),flush=True)


if __name__=='__main__':main()
