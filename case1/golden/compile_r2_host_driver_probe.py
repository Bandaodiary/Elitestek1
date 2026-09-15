"""C15 + retained R2V2 RV32 relocatable link; not firmware/CPU execution."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path('D:/ELS/efinity-riscv-ide-2026.1/toolchain/bin')


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError((result.stdout+result.stderr)[-2000:])
    return result.stdout


def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_host_driver_', dir=ROOT/'sim') as td:
        root = Path(td)
        objects = []
        for source in ('c1_r2_rgbx_video', 'c1_r2_host_video'):
            obj = root/(source+'.o')
            command([str(TOOL/'riscv-none-elf-gcc.exe'), '-march=rv32imac', '-mabi=ilp32', '-std=c11',
                     '-O2', '-Wall', '-Wextra', '-Werror', '-ffreestanding', '-I', str(ROOT/'software/include'),
                     '-c', str(ROOT/f'software/src/{source}.c'), '-o', str(obj)])
            objects.append(str(obj))
        linked = root/'host.o'
        command([str(TOOL/'riscv-none-elf-gcc.exe'), '-march=rv32imac', '-mabi=ilp32', '-nostdlib', '-r',
                 *objects, '-o', str(linked)])
        symbols = command([str(TOOL/'riscv-none-elf-nm.exe'), '-u', str(linked)])
        if symbols.strip():
            raise RuntimeError('unresolved host-driver symbols: '+symbols)
        disassembly = command([str(TOOL/'riscv-none-elf-objdump.exe'), '-d', str(linked)])
        for symbol in ('c1_r2x_control', 'c1_r2x_result_read', 'c1_r2x_interrupts', 'c1_r2h_control', 'c1_r2h_status_read'):
            if '<'+symbol+'>:' not in disassembly:
                raise RuntimeError('missing function '+symbol)
        fences = sum('fence' in line for line in disassembly.splitlines())
        if fences < 7:
            raise RuntimeError('missing IO ordering fences')
        print(f'C1_R2_HOST_DRIVER_LINK_PASS rv32imac=1 ilp32=1 functions=5 fences={fences} undefined_symbols=0 hardware_execution=0')
    print('C1_R2_HOST_DRIVER_CLEAN temporary_objects_removed=1')


if __name__ == '__main__':
    main()
