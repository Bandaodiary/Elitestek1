"""RV32 compile-only check; does not claim execution on Sapphire hardware."""
import subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
TOOL=Path('D:/ELS/efinity-riscv-ide-2026.1/toolchain/bin')
with tempfile.TemporaryDirectory(prefix='c1_r2_video_driver_',dir=ROOT/'sim') as td:
    obj=Path(td)/'video.o'
    c=subprocess.run([str(TOOL/'riscv-none-elf-gcc.exe'),'-march=rv32imac','-mabi=ilp32','-std=c11','-O2','-Wall','-Wextra','-Werror','-ffreestanding',
                      '-I',str(ROOT/'software/include'),'-c',str(ROOT/'software/src/c1_r2_video.c'),'-o',str(obj)],capture_output=True,text=True,timeout=30)
    if c.returncode:raise RuntimeError(c.stderr[-2000:])
    d=subprocess.run([str(TOOL/'riscv-none-elf-objdump.exe'),'-d',str(obj)],capture_output=True,text=True,timeout=30)
    if d.returncode:raise RuntimeError(d.stderr[-2000:])
    for symbol in ('c1_r2v_control','c1_r2v_result_read','c1_r2v_interrupts'):
        if '<'+symbol+'>:' not in d.stdout:raise RuntimeError('missing function '+symbol)
    fences=sum('fence' in line for line in d.stdout.splitlines())
    if fences<5:raise RuntimeError('missing RISC-V IO ordering fences')
    print(f'C1_R2_VIDEO_DRIVER_COMPILE_PASS rv32imac=1 ilp32=1 functions=3 fences={fences} hardware_execution=0')
print('C1_R2_VIDEO_DRIVER_CLEAN temporary_object_removed=1')
