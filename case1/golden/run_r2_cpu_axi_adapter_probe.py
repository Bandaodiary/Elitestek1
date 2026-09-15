"""C13 CPU AXI seam: real byte RAM, full ID restoration and bounded faults."""
import argparse,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--stalls',default='0,1');p.add_argument('--aw-modes',default='0,2');p.add_argument('--id-bits',default='4,8,12');a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='c1_r2_cpu_axi_',dir=ROOT/'sim') as td:
        exe=Path(td)/'cpu.vvp';top='tb_c1_r2_cpu_axi_adapter'
        for s in map(int,a.stalls.split(',')):
            for w in map(int,a.aw_modes.split(',')):
                for i in map(int,a.id_bits.split(',')):
                    c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.STALLS={s}',f'-P{top}.AW_MODE={w}',f'-P{top}.ID_BITS={i}',
                        '-o',str(exe),str(ROOT/'rtl/r2/c1_r2_cpu_axi_adapter.sv'),str(ROOT/'sim/tb_c1_r2_cpu_axi_adapter.sv')],capture_output=True,text=True,timeout=60)
                    if c.returncode:raise RuntimeError(c.stderr[-3000:])
                    r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=60)
                    if r.returncode or r.stdout.count('C1_R2_CPU_AXI_ADAPTER_PASS ')!=1 or 'FATAL' in r.stdout or 'ERROR' in r.stdout:raise RuntimeError(f'profile={s}/{w}/{i} '+(r.stdout+r.stderr)[-3000:])
                    print(r.stdout.strip(),flush=True)
    print('C1_R2_CPU_AXI_ADAPTER_CLEAN temporary_simulator_removed=1')
if __name__=='__main__':main()
