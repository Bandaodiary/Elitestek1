"""Compile/link a read-only current-host probe against actual generated S2 BSP."""
import argparse
import ctypes
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from c39_sapphire_platform_contract import audit, ROOT

TOOL = Path('D:/ELS/efinity-riscv-ide-2026.1/toolchain/bin')


def run(command, directory):
    result = subprocess.run(list(map(str, command)), cwd=directory,
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError((result.stdout + result.stderr)[-3000:])
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id):
        raise ValueError('invalid run identifier')
    log = ROOT / 'logs/c39_s2_software_runs' / args.run_id
    if log.exists():
        raise ValueError('refuse existing run')
    api = ctypes.WinDLL('kernel32', use_last_error=True)
    api.GetCurrentProcess.restype = ctypes.c_void_p
    api.SetProcessAffinityMask.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    api.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    handle = api.GetCurrentProcess()
    if not api.SetProcessAffinityMask(handle, 3) or not api.SetPriorityClass(handle, 0x4000):
        raise ctypes.WinError(ctypes.get_last_error())
    cpu = ROOT / 'efinity/c39_cpu_s2_generate_20260915a'
    contract = audit(cpu)
    bsp = cpu / 'ip/c39_soc_s2/Ti60F225_devkit/embedded_sw/c39_soc_s2/bsp/efinix/EfxSapphireSoc/include'
    source = ROOT / 'software/c39_s2_probe'
    flags = ['-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-mno-relax', '-msmall-data-limit=0',
             '-Os', '-std=c11', '-Wall', '-Wextra', '-Werror', '-ffreestanding', '-fno-builtin',
             '-ffunction-sections', '-fdata-sections', '-nostdlib', '-I' + str(bsp),
             '-I' + str(ROOT / 'software/include')]
    gcc = TOOL / 'riscv-none-elf-gcc.exe'
    version = run([gcc, '--version'], ROOT).splitlines()[0]
    with tempfile.TemporaryDirectory(prefix='c39_s2_sw_', dir=ROOT / 'tmp') as private:
        folder = Path(private)
        elf = folder / 'c39_s2_probe.elf'
        inputs = [source / 'startup.S', source / 'main.c', ROOT / 'software/src/c1_r2_host_video.c',
                  ROOT / 'software/src/c1_r2_rgbx_video.c']
        command = [gcc, *flags, *inputs, '-Wl,-T,' + str(source / 'linker.ld'),
                   '-Wl,--gc-sections,--no-relax', '-o', elf]
        run(command, folder)
        attrs = run([TOOL / 'riscv-none-elf-readelf.exe', '-A', elf], folder)
        header = run([TOOL / 'riscv-none-elf-readelf.exe', '-h', elf], folder)
        assembly = run([TOOL / 'riscv-none-elf-objdump.exe', '-d', elf], folder)
        size = run([TOOL / 'riscv-none-elf-size.exe', elf], folder).splitlines()
        isa = re.search(r'Tag_RISCV_arch:\s*"([^"]+)"', attrs)
        if (not isa or not re.fullmatch(r'rv32i\d+p\d+', isa[1].split('_')[0]) or
                any(not re.fullmatch(r'(m|zicsr|zifencei|zmmul)\d+p\d+', ext)
                    for ext in isa[1].split('_')[1:])):
            raise ValueError('ELF ISA exceeds non-compressed/non-FPU S2 contract')
        if 'ELF32' not in header or not re.search(r'Entry point address:\s+0x1000\b', header):
            raise ValueError('wrong ELF class or application DDR entry')
        instructions = re.findall(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s', assembly, re.M | re.I)
        if not instructions or any(len(word) != 8 for word in instructions):
            raise ValueError('unexpected non-32-bit instruction in linked probe')
        if 'c1_r2h_status_read' not in assembly or 'fence' not in assembly or 'mtvec' not in assembly:
            raise ValueError('current host ABI/barrier/startup was not linked')
        log.mkdir(parents=True)
        shutil.copy2(elf, log / elf.name)
        text_bytes, data_bytes, bss_bytes = map(int, size[-1].split()[:3])
        report = dict(marker='C39_S2_SOFTWARE_BUILD_PASS', compiler=version, isa=isa[1],
                      flags=flags, actual_generated_bsp=str(bsp), inputs=list(map(str, inputs)),
                      elf_bytes=elf.stat().st_size, instructions_checked=len(instructions),
                      text_bytes=text_bytes, data_bytes=data_bytes, bss_bytes=bss_bytes,
                      stack_bytes=4096, entry='0x1000', application_region_bytes=124*1024,
                      bootloader_ram_bytes=contract['boot_ram_bytes'], host_mmio='0xf8100000',
                      actual_CPU_execution=False, MMIO_writes_in_probe=False,
                      board_programmed=False, private_build_removed=False)
    report['private_build_removed'] = not folder.exists()
    (log / 'summary.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, separators=(',', ':')), flush=True)


if __name__ == '__main__':
    main()
