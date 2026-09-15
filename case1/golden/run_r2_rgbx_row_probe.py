"""C12 packed RGB boundary tests. Actual W data supplies subsequent reads."""
import argparse,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCES=['rtl/r2/c1_r2_axi_row_read.sv','rtl/r2/c1_r2_axi_row_write.sv',
         'rtl/r2/c1_r2_rgbx_row_read.sv','rtl/r2/c1_r2_rgbx_row_write.sv','sim/c1_r2_axi_memory_bfm.sv','sim/tb_c1_r2_rgbx_row_dma.sv']
p=argparse.ArgumentParser();p.add_argument('--stalls',default='0,1');p.add_argument('--aw-wait-w',default='0,2');p.add_argument('--outstanding',default='1,4');p.add_argument('--leases-only',action='store_true');p.add_argument('--csr-only',action='store_true');a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='c1_r2_rgbx_row_',dir=ROOT/'sim') as td:
    exe=Path(td)/'test.vvp';top='tb_c1_r2_video_rgbx_leases' if a.leases_only else 'tb_c1_r2_rgbx_row_dma'
    if a.leases_only:
        SOURCES=['rtl/r2/c1_r2_video_rgbx_leases.sv','sim/tb_c1_r2_video_rgbx_leases.sv'];a.outstanding='1';a.stalls='0';a.aw_wait_w='0'
    if a.csr_only:
        top='tb_c1_r2_video_rgbx_csr';SOURCES=['rtl/r2/c1_r2_video_rgbx_csr.sv','sim/tb_c1_r2_video_rgbx_csr.sv'];a.outstanding='1';a.stalls='0';a.aw_wait_w='0'
    for n in map(int,a.outstanding.split(',')):
        for s in map(int,a.stalls.split(',')):
            for aw in map(int,a.aw_wait_w.split(',')):
                overrides=[] if a.leases_only or a.csr_only else [f'-P{top}.OUTSTANDING={n}',f'-P{top}.STALLS={s}',f'-P{top}.AW_WAIT_W={aw}']
                c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,*overrides,
                                  '-o',str(exe),*[str(ROOT/x) for x in SOURCES]],capture_output=True,text=True,timeout=60)
                if c.returncode:raise RuntimeError(c.stderr[-4000:])
                r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=120)
                marker='C1_R2_RGBX_CSR_PASS ' if a.csr_only else 'C1_R2_RGBX_LEASE_PASS ' if a.leases_only else 'C1_R2_RGBX_ROW_PASS '
                if r.returncode or r.stdout.count(marker)!=1 or 'FATAL' in r.stdout or 'ERROR' in r.stdout:raise RuntimeError(r.stdout[-4000:]+r.stderr[-1000:])
                for line in r.stdout.splitlines():
                    if line.startswith('C1_R2_RGBX_'):print(line,flush=True)
print('C1_R2_RGBX_ROW_CLEAN temporary_simulator_removed=1')
