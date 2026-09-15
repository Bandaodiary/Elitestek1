"""C14 latest-READY protection, plus the retained C12 as a negative control."""
import subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_fresh_lease_',dir=ROOT/'sim') as td:
        exe=Path(td)/'lease.vvp'
        for top,baseline in [('tb_c1_r2_video_fresh_legacy',0),('tb_c1_r2_video_fresh_leases',0),('tb_c1_r2_video_fresh_leases',1)]:
            flags=[f'-P{top}.BASELINE=1'] if baseline else []
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,*flags,'-o',str(exe),
                str(ROOT/'rtl/r2/c1_r2_video_rgbx_leases.sv'),str(ROOT/'rtl/r2/c1_r2_video_fresh_leases.sv'),str(ROOT/f'sim/{top}.sv')],capture_output=True,text=True,timeout=60)
            if c.returncode:raise RuntimeError(c.stderr[-3000:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=60)
            if baseline:
                if r.returncode==0 or 'freshness: latest READY was reclaimed' not in r.stdout:raise RuntimeError('retained baseline negative did not trip: '+r.stdout[-2000:])
                print('C1_R2_FRESH_NEGATIVE_PASS original_c12=1 actual_selector=1 latest_reclaimed_detected=1',flush=True)
            else:
                marker='C1_R2_FRESH_LEGACY_PASS ' if 'legacy' in top else 'C1_R2_FRESH_LEASE_PASS '
                if r.returncode or r.stdout.count(marker)!=1 or 'FATAL' in r.stdout:raise RuntimeError(r.stdout[-3000:])
                for line in r.stdout.splitlines():
                    if line.startswith('C1_R2_FRESH_'):print(line,flush=True)
    print('C1_R2_FRESH_LEASE_CLEAN temporary_simulator_removed=1')
if __name__=='__main__':main()
