"""Cross-compile the C10 freestanding driver; no CPU execution is claimed."""
import subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BIN=Path('D:/ELS/efinity-riscv-ide-2026.1/toolchain/bin')
with tempfile.TemporaryDirectory(prefix='c1_r2_driver_',dir=ROOT/'sim') as td:
    obj=Path(td)/'control.o'
    subprocess.run([str(BIN/'riscv-none-elf-gcc.exe'),'-std=c11','-Wall','-Wextra','-Werror',
        '-O2','-march=rv32imac','-mabi=ilp32','-ffreestanding','-I',str(ROOT/'software/include'),
        '-c',str(ROOT/'software/src/c1_r2_control.c'),'-o',str(obj)],check=True,timeout=60)
    dis=subprocess.run([str(BIN/'riscv-none-elf-objdump.exe'),'-d',str(obj)],capture_output=True,text=True,check=True,timeout=30)
    assert all('<'+name+'>:' in dis.stdout for name in ('c1_r2_submit','c1_r2_poll','c1_r2_discard','c1_r2_ack_result','c1_r2_irq_enable','c1_r2_irq_clear'))
    assert dis.stdout.count('fence')>=6
    print(f'C1_R2_CONTROL_COMPILE_PASS isa=rv32imac abi=ilp32 functions=6 ordering_fences={dis.stdout.count("fence")} object_bytes={obj.stat().st_size}')
print('C1_R2_CONTROL_CLEAN object_removed=1')
